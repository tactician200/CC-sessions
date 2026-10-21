import Foundation

/// Fetches `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token.
///
/// - Token safety: dedicated ephemeral URLSession (no cache/cookies) whose
///   delegate refuses **every** redirect, so the Authorization header can only
///   ever go to the fixed endpoint; scheme/host are asserted before the token
///   is attached. The token is never logged or put in an error.
/// - Coalescing: one in-flight request shared by all callers; `lastAttempt` is
///   tracked apart from the cache so failures also respect `minInterval`;
///   a 429 honors `Retry-After` (default 120 s, capped at 1 h).
/// - Result contract: `fetch` returns only data from a successful request —
///   fresh, or the cache while the **last attempt succeeded**. While the last
///   attempt's failure is unresolved (Retry-After window, `minInterval`
///   throttle, or a TTL-valid cache older than the failure) it rethrows that
///   failure, so a refresh during backoff never clears the visible error.
///   Callers keep showing their last snapshot alongside the error.
actor UsageFetcher {
    static let shared = UsageFetcher()

    typealias Request = @Sendable () async throws -> UsageSnapshot
    private let performRequest: Request
    private let clock: @Sendable () -> Date

    /// Injectable request/clock for `--budget-selftest` (case i); live defaults.
    init(request: @escaping Request = { try await UsageFetcher.request() },
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.performRequest = request
        self.clock = clock
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let allowedHost = "api.anthropic.com"

    private let cacheTTL: TimeInterval = 180
    private let minInterval: TimeInterval = 30
    static let defaultRetryAfter: TimeInterval = 120
    static let maxRetryAfter: TimeInterval = 3600

    private var lastFetch: Date?
    private var lastAttempt: Date?
    private var lastError: Error?
    private var retryNotBefore: Date?
    private var cached: UsageSnapshot?
    private var inFlight: Task<UsageSnapshot, Error>?

    private static let redirectBlocker = RedirectBlocker()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
    }()

    enum UsageError: LocalizedError {
        case noCredentials
        case rateLimited(retryAfter: TimeInterval)
        case httpError(Int)
        case decoding
        case insecureEndpoint
        case throttled

        var errorDescription: String? {
            switch self {
            case .noCredentials: return L10n.tr("error.noCredentials")
            case .rateLimited(let s): return L10n.tr("error.rateLimited", max(1, Int((s / 60).rounded(.up))))
            case .httpError(let code): return "HTTP \(code)"
            case .decoding: return L10n.tr("error.decoding")
            case .insecureEndpoint: return L10n.tr("error.insecureEndpoint")
            case .throttled: return L10n.tr("error.throttled")
            }
        }
    }

    /// `force` skips the cache TTL, never `minInterval`, `Retry-After`, an
    /// unresolved failure, or an in-flight request.
    func fetch(force: Bool = false) async throws -> UsageSnapshot {
        if let inFlight {
            return try await inFlight.value
        }
        let now = clock()
        if let until = retryNotBefore, now < until {
            throw UsageError.rateLimited(retryAfter: until.timeIntervalSince(now))
        }
        let throttled = lastAttempt.map { now.timeIntervalSince($0) < minInterval } ?? false
        if let lastError {
            if throttled { throw lastError }
            // Failure outside the throttle window → retry (even non-forced).
        } else if let cached {
            if !force, let last = lastFetch, now.timeIntervalSince(last) < cacheTTL { return cached }
            if throttled { return cached }
        }

        lastAttempt = now
        let request = performRequest
        let task = Task.detached(priority: .utility) { try await request() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let snapshot = try await task.value
            cached = snapshot
            lastFetch = clock()
            lastError = nil
            retryNotBefore = nil
            return snapshot
        } catch {
            if case UsageError.rateLimited(let after) = error {
                retryNotBefore = clock().addingTimeInterval(after)
            }
            lastError = error
            throw error
        }
    }

    static func request() async throws -> UsageSnapshot {
        guard let creds = CredentialsReader.read() else {
            throw UsageError.noCredentials
        }
        let url = endpoint
        guard url.scheme == "https", url.host == allowedHost else {
            throw UsageError.insecureEndpoint
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeSessionsMenuBar/0.1", forHTTPHeaderField: "User-Agent")

        // Session delegate + task delegate: the redirect is refused either way.
        let (data, response) = try await session.data(for: req, delegate: redirectBlocker)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.httpError(-1)
        }
        guard http.url?.scheme == "https", http.url?.host == allowedHost else {
            throw UsageError.insecureEndpoint
        }
        switch http.statusCode {
        case 200: break
        case 429: throw UsageError.rateLimited(retryAfter: retryAfter(http))
        default: throw UsageError.httpError(http.statusCode)
        }

        let decoded: UsageResponse
        do {
            decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decoding
        }
        return decoded.toSnapshot()
    }

    /// `Retry-After`: delta-seconds or HTTP-date; default 120 s, clamped 1 s…1 h.
    static func retryAfter(_ http: HTTPURLResponse, now: Date = Date()) -> TimeInterval {
        let fallback = defaultRetryAfter
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
        var seconds: TimeInterval?
        if let n = Double(raw) {
            seconds = n
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let d = f.date(from: raw) { seconds = d.timeIntervalSince(now) }
        }
        guard let seconds, seconds.isFinite else { return fallback }
        return min(max(seconds, 1), maxRetryAfter)
    }

    private struct UsageResponse: Decodable {
        let five_hour: Window
        let seven_day: Window
        let seven_day_sonnet: Window?
        let seven_day_opus: Window?
        let extra_usage: ExtraUsage?

        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
        }

        struct ExtraUsage: Decodable {
            let is_enabled: Bool
            let monthly_limit: Double?
            let used_credits: Double?
            let utilization: Double?
            let currency: String?
        }

        func toSnapshot() -> UsageSnapshot {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            func date(_ s: String?) -> Date? {
                guard let s else { return nil }
                return iso.date(from: s) ?? isoPlain.date(from: s)
            }

            func window(_ w: Window?) -> UsageSnapshot.Window? {
                guard let w else { return nil }
                return .init(utilization: w.utilization, resetsAt: date(w.resets_at))
            }

            let extra: UsageSnapshot.ExtraUsage? = extra_usage.map {
                .init(
                    isEnabled: $0.is_enabled,
                    monthlyLimit: $0.monthly_limit ?? 0,
                    usedCredits: $0.used_credits ?? 0,
                    utilization: $0.utilization ?? 0,
                    currency: $0.currency ?? "USD"
                )
            }

            return UsageSnapshot(
                fiveHour: .init(utilization: five_hour.utilization, resetsAt: date(five_hour.resets_at)),
                sevenDay: .init(utilization: seven_day.utilization, resetsAt: date(seven_day.resets_at)),
                sevenDaySonnet: window(seven_day_sonnet),
                sevenDayOpus: window(seven_day_opus),
                extraUsage: extra,
                fetchedAt: Date()
            )
        }
    }
}

/// Refuses every HTTP redirect: the usage endpoint is fixed, so a 3xx can only
/// mean something is wrong, and following it would re-send the Bearer token.
/// The 3xx response itself is returned to the caller (→ `httpError(3xx)`).
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

#if DEBUG
// MARK: - Self-test (part of `--budget-selftest`)

/// Fake request + fake clock: backoff/throttle must keep the failure visible,
/// success clears it, concurrent callers share one request.
enum UsageFetcherSelfTest {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var calls = 0
        var next: Result<UsageSnapshot, Error> = .failure(UsageFetcher.UsageError.decoding)
        var delay: UInt64 = 0
    }

    static func run() -> Bool {
        let box = Box()
        let start = box.now
        let fetcher = UsageFetcher(
            request: {
                let (result, delay): (Result<UsageSnapshot, Error>, UInt64) = box.lock.withLock {
                    box.calls += 1
                    return (box.next, box.delay)
                }
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                return try result.get()
            },
            clock: { box.lock.withLock { box.now } })
        func snap(_ u: Double) -> UsageSnapshot {
            UsageSnapshot(fiveHour: .init(utilization: u, resetsAt: nil),
                          sevenDay: .init(utilization: u, resetsAt: nil),
                          sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil, fetchedAt: start)
        }
        func at(_ t: TimeInterval) { box.lock.withLock { box.now = start.addingTimeInterval(t) } }
        func set(_ r: Result<UsageSnapshot, Error>) { box.lock.withLock { box.next = r } }
        var calls: Int { box.lock.withLock { box.calls } }

        /// "ok <u>" or "err <description>", synchronously (fetcher runs off-main).
        func fetch(force: Bool) -> String {
            let sem = DispatchSemaphore(value: 0)
            let out = OutBox()
            Task.detached {
                do { out.value = "ok \(Int(try await fetcher.fetch(force: force).fiveHour.utilization))" }
                catch { out.value = "err \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
                sem.signal()
            }
            sem.wait()
            return out.value
        }

        var trace: [String] = []
        func step(_ t: TimeInterval, force: Bool, _ expected: String, calls expectedCalls: Int) -> (String, Bool) {
            at(t)
            let got = fetch(force: force)
            let ok = got.hasPrefix(expected) && calls == expectedCalls
            trace.append("t=\(Int(t)) \(got) calls=\(calls)")
            return ("t=\(Int(t)) force=\(force) expected \(expected) calls=\(expectedCalls), got \(got) calls=\(calls)", ok)
        }

        var conditions: [(String, Bool)] = []
        set(.success(snap(10)))
        conditions.append(step(0, force: false, "ok 10", calls: 1))
        conditions.append(step(10, force: true, "ok 10", calls: 1))          // throttle, last ok → cache
        set(.failure(UsageFetcher.UsageError.rateLimited(retryAfter: 60)))
        conditions.append(step(40, force: true, "err Límite", calls: 2))      // 429 → error
        conditions.append(step(45, force: true, "err Límite", calls: 2))      // refresh in backoff: still error
        conditions.append(step(50, force: false, "err Límite", calls: 2))     // TTL-valid cache must not hide it
        set(.success(snap(20)))
        conditions.append(step(101, force: true, "ok 20", calls: 3))         // backoff over → real success
        conditions.append(step(110, force: false, "ok 20", calls: 3))        // cache
        set(.failure(UsageFetcher.UsageError.httpError(500)))
        conditions.append(step(300, force: true, "err HTTP 500", calls: 4))
        conditions.append(step(310, force: true, "err HTTP 500", calls: 4))   // throttle rethrows, no request
        conditions.append(step(320, force: false, "err HTTP 500", calls: 4))
        set(.success(snap(30)))
        conditions.append(step(331, force: false, "ok 30", calls: 5))        // retried after minInterval

        // Coalescing: 3 concurrent forced fetches during one slow request.
        at(1000)
        box.lock.withLock { box.delay = 200_000_000; box.next = .success(snap(40)) }
        let group = DispatchGroup()
        let results = OutList()
        for _ in 0..<3 {
            group.enter()
            Task.detached {
                let v = (try? await fetcher.fetch(force: true))?.fiveHour.utilization ?? -1
                results.append(v)
                group.leave()
            }
        }
        group.wait()
        conditions.append(("coalesced: 1 request for 3 callers (calls \(calls), results \(results.values))",
                           calls == 6 && results.values == [40, 40, 40]))

        let failed = conditions.filter { !$0.1 }.map(\.0)
        if failed.isEmpty {
            print("PASS i usage fetcher: backoff/throttle keep the error, success clears it, coalesced")
            return true
        }
        print("FAIL i usage fetcher: \(failed.joined(separator: "; ")) · trace \(trace)")
        return false
    }

    private final class OutBox: @unchecked Sendable { var value = "" }
    private final class OutList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Double] = []
        func append(_ v: Double) { lock.withLock { items.append(v) } }
        var values: [Double] { lock.withLock { items } }
    }
}
#endif
