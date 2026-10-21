import Foundation

/// User-facing strings: English (base) and Spanish.
///
/// Tables: `Localization/<lang>.lproj/Localizable.strings`, excluded from the
/// SwiftPM target (no `Bundle.module`) and copied by build-app.sh into
/// `Contents/Resources`, where `Bundle.main` finds them. A DEBUG binary run from
/// `.build/` has no app bundle and reads the tables from the source tree instead.
///
/// Lookup: chosen language → English → the key itself. The language is
/// `force(_:)` (`--language`, self-tests) or the user's preferred languages
/// (which honours `-AppleLanguages (es)`), matched against `supported`.
/// Views render the returned `String` verbatim (`Text(String)`), so SwiftUI's own
/// lookup never runs.
enum L10n {
    static let supported = ["en", "es"]
    static let base = "en"

    private static let lock = NSLock()
    private static var forced: String?
    private static var tables: [String: [String: String]] = [:]

    /// Fixes the language for this process (nil = system choice). Call before
    /// anything is rendered.
    static func force(_ language: String?) {
        lock.lock()
        forced = language
        lock.unlock()
    }

    static var language: String {
        lock.lock()
        let f = forced
        lock.unlock()
        if let f { return f }
        return Bundle.preferredLocalizations(from: supported).first ?? base
    }

    /// Number formatting follows the UI language: the user's own locale when it
    /// speaks that language (es_CL, es_MX, en_GB…), the bare language otherwise.
    /// A forced language always uses the bare language, so snapshots and
    /// self-tests format the same on every machine.
    static var locale: Locale {
        lock.lock()
        let f = forced
        lock.unlock()
        if let f { return Locale(identifier: f) }
        let lang = language
        if Locale.current.language.languageCode?.identifier == lang { return .current }
        return Locale(identifier: lang)
    }

    static func tr(_ key: String) -> String {
        lookup(key, language: language)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: args)
    }

    static func lookup(_ key: String, language: String) -> String {
        table(language)[key] ?? table(base)[key] ?? key
    }

    /// "35 %" (es) · "35%" (en).
    static func percent(_ number: String) -> String { tr("percent", number) }

    /// The hook writes its known waiting reasons in Spanish; show them in the UI
    /// language. Anything else (a notification's own text) passes through verbatim.
    static func waitingReason(_ raw: String) -> String {
        switch raw {
        case "Pregunta": return tr("reason.question")
        case "Plan por aprobar": return tr("reason.plan")
        case "Permiso": return tr("reason.permission")
        default:
            let prefix = "Permiso: "
            if raw.hasPrefix(prefix), raw.count > prefix.count {
                return tr("reason.permissionTool", String(raw.dropFirst(prefix.count)))
            }
            return raw
        }
    }

    // MARK: - tables

    private static func table(_ lang: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let t = tables[lang] { return t }
        let t = tableURL(lang).flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        tables[lang] = t
        return t
    }

    static func tableURL(_ lang: String) -> URL? {
        if let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                     subdirectory: nil, localization: lang) {
            return url
        }
        #if DEBUG
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Localization/\(lang).lproj/Localizable.strings")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        #endif
        return nil
    }
}

#if DEBUG
/// `--l10n-selftest`: both tables load with the same keys and format specifiers,
/// every key the sources use exists, fallbacks, and the hook's waiting reasons.
enum L10nSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL") \(name)")
            if !cond { ok = false }
        }
        func load(_ lang: String) -> [String: String] {
            L10n.tableURL(lang).flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        }
        let en = load("en"), es = load("es")
        check("a en table loads (\(en.count) keys)", en.count > 50)
        check("b es table has the same keys as en (missing \(Set(en.keys).subtracting(es.keys).sorted()), extra \(Set(es.keys).subtracting(en.keys).sorted()))",
              Set(en.keys) == Set(es.keys))

        func specifiers(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #"%(\d+\$)?[@dfs%]"#)
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        let mismatched = en.keys.filter { key in es[key].map { specifiers($0) != specifiers(en[key]!) } ?? false }
        check("c same format specifiers in en and es \(mismatched.sorted())", mismatched.isEmpty)

        // Every literal key passed to L10n.tr in the sources exists in en.
        let srcDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: srcDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "L10n.swift" }   // this test's own probes
        let re = try! NSRegularExpression(pattern: #"L10n\.tr\("([A-Za-z0-9_.]+)""#)
        var used: Set<String> = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                used.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        let missing = used.subtracting(en.keys).sorted()
        check("d all \(used.count) keys used in the sources exist \(missing)", used.count > 40 && missing.isEmpty)

        L10n.force("en")
        check("e en: state.waiting → Waiting for you", L10n.tr("state.waiting") == "Waiting for you")
        check("f en: percent → 35%", L10n.percent("35") == "35%")
        check("g unknown key falls back to the key", L10n.tr("no.such.key") == "no.such.key")
        check("h en: hook reasons localized",
              L10n.waitingReason("Pregunta") == "Question"
              && L10n.waitingReason("Plan por aprobar") == "Plan to approve"
              && L10n.waitingReason("Permiso") == "Permission"
              && L10n.waitingReason("Permiso: Bash") == "Permission: Bash")
        check("i unknown reason passes through verbatim",
              L10n.waitingReason("Claude needs your attention") == "Claude needs your attention"
              && L10n.waitingReason("Permiso:") == "Permiso:")
        check("j en: plural format", L10n.tr("workdays.other", 4) == "4 workdays")

        L10n.force("es")
        check("k es: state.waiting → Te espera", L10n.tr("state.waiting") == "Te espera")
        check("l es: percent → 35 %", L10n.percent("35") == "35 %")
        check("m es: hook reasons keep their wording",
              L10n.waitingReason("Pregunta") == "Pregunta"
              && L10n.waitingReason("Plan por aprobar") == "Plan por aprobar"
              && L10n.waitingReason("Permiso: Bash") == "Permiso: Bash")
        check("n es: positional format", L10n.tr("ago.hoursMinutes", 2, 5) == "hace 2 h 5 min")
        check("o lookup falls back to English for a language without a table",
              L10n.lookup("state.working", language: "xx") == "Working")
        return ok
    }
}
#endif
