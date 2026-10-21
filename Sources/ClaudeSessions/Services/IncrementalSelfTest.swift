import Foundation

// Test-only: compiled into DEBUG builds, absent from release.
#if DEBUG

/// Deterministic RNG for reproducible split points.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `--incremental-selftest`: ParserState fed in pieces == one-shot parse, and
/// TranscriptCache on a temp file (append, partial line, shrink, new inode).
enum IncrementalSelfTest {
    /// Exercises every rule of the parser; multi-byte UTF-8 throughout.
    static let syntheticLines: [String] = [
        #"{"type":"summary","cwd":"/tmp/projé/α","timestamp":"2026-10-20T12:00:00.000Z"}"#,
        #"{"type":"user","cwd":"/tmp/second-cwd-loses","timestamp":"2026-10-20T12:00:01Z","message":{"role":"user","content":"hola ñandú 🚴‍♂️ 漢字"}}"#,
        #"{"type":"assistant","timestamp":"2026-10-20T12:00:02.100Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"content":[{"type":"text","text":"€ uno"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-10-20T12:00:02.200Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":7,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls ü"}}]}}"#,
        "",
        #"{"type":"assistant","isSidechain":true,"timestamp":"2026-10-20T12:00:03Z","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
        #"{"type":"assistant","timestamp":"2026-10-20T12:00:04Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":300,"cache_creation_input_tokens":4},"content":[{"type":"tool_use","id":"task1","name":"Task","input":{"subagent_type":"Explore","description":"buscar «algo» en el código — largo, muy largo, larguísimo, más de sesenta"}},{"type":"tool_use","name":"Agent","input":{"prompt":"sin id ✓"}},{"type":"tool_use","id":"task2","name":"Agent","input":{"subagent_type":"Explore","description":"segundo"}}]}}"#,
        #"{"type":"user","timestamp":"2026-10-20T12:00:05Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok ✅"}]}}"#,
        "not json at all — ¿qué?",
        #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"tool_result","tool_use_id":"task2","content":"x"},{"type":"tool_use","id":"t9","name":"Grep","input":{}}]}}"#,
        "{\"type\":\"ai-title\",\"aiTitle\":\"Título generado 🌋\"}\r",
        #"{"type":"custom-title","customTitle":"renombrada"}"#,
        #"{"type":"custom-title","customTitle":""}"#,
        #"{"type":"assistant","timestamp":"2026-10-20T12:00:06.5Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{}}],"usage":{"input_tokens":2,"output_tokens":3}}}"#,
        #"{"type":"user","timestamp":"bad-date","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]}}"#,
        // Unterminated last line: parse(data:) still reads it.
        #"{"type":"assistant","timestamp":"2026-10-20T12:00:07Z","message":{"id":"m3","usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t4","name":"Write","input":{"p":"ö"}}]}}"#,
    ]

    static func run() -> Bool {
        var allPass = true
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { allPass = false }
        }

        // MARK: (a) split feeding == one-shot parse
        let text = syntheticLines.joined(separator: "\n")
        let bytes = Data(text.utf8)
        let full = JSONLParser.parse(data: bytes)

        // Sanity: the fixture really exercises the rules.
        // used: m1 last-wins (10+7+20) + m2 (1+2+4) + m3 (5+5) + no-id sidechain (3+4) + no-id t3 (2+3)
        check("a0 fixture: used tokens dedup by message id (last wins) + id-less summed",
              full.usedTokens == 37 + 7 + 10 + 7 + 5)
        check("a0 fixture: context = last non-sidechain response with context > 0",
              full.contextTokens == 5 + 0 + 0)
        check("a0 fixture: first cwd wins, model/title/tool counts",
              full.cwd == "/tmp/projé/α" && full.model == "claude-opus-5-5"
              && full.aiTitle == "Título generado 🌋" && full.customTitle == nil
              && full.toolCallCount == 7 && full.lastToolName == "Write")  // blob replays (t1, t9) not counted
        check("a0 fixture: open calls (blob never registers, any tool_result closes)",
              full.openToolCalls.map(\.id) == ["task1", "t3", "t4"])
        check("a0 fixture: subagents (blob tool_result completes task2; id-less Agent stays)",
              full.subagents.map(\.id) == ["task1", "task-without-id-1"]
              && full.subagents.first?.description.count == 60)
        check("a0 parse is deterministic (two parses equal)", JSONLParser.parse(data: bytes) == full)

        func fed(_ cuts: [Int]) -> JSONLParser.ParsedTranscript {
            var state = JSONLParser.ParserState()
            var prev = 0
            for cut in cuts.sorted() + [bytes.count] where cut >= prev {
                state.feed(bytes.subdata(in: prev..<cut))
                prev = cut
            }
            return state.snapshot()
        }

        var singleFails = 0
        var midCodepoint = 0
        var midLine = 0
        for cut in 0...bytes.count {
            if cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { midCodepoint += 1 }
            if cut > 0, cut < bytes.count, bytes[cut - 1] != 0x0A { midLine += 1 }
            if fed([cut]) != full { singleFails += 1 }
        }
        check("a1 every single split point (\(bytes.count + 1), \(midLine) mid-line, \(midCodepoint) mid-UTF-8) == full parse",
              singleFails == 0 && midCodepoint > 20)

        var rng = SplitMix64(state: 42)
        var multiFails = 0
        for _ in 0..<500 {
            let n = Int.random(in: 2...12, using: &rng)
            let cuts = (0..<n).map { _ in Int.random(in: 0...bytes.count, using: &rng) }
            if fed(cuts) != full { multiFails += 1 }
        }
        check("a2 500 random multi-split feeds == full parse", multiFails == 0)

        var byteByByte = JSONLParser.ParserState()
        for i in 0..<bytes.count { byteByByte.feed(bytes.subdata(in: i..<(i + 1))) }
        check("a3 one byte at a time == full parse", byteByByte.snapshot() == full)

        var withTail = JSONLParser.ParserState()
        withTail.feed(bytes)
        let snap1 = withTail.snapshot()
        withTail.feed(Data("\n".utf8))
        check("a4 snapshot does not consume the pending tail; terminating it changes nothing",
              snap1 == full && withTail.snapshot() == full && withTail.pendingByteCount == 0)

        // MARK: (b) TranscriptCache on a temp file
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cs-incremental-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        let terminated = syntheticLines.map { $0 + "\n" }
        func write(_ s: String) { fm.createFile(atPath: path, contents: Data(s.utf8)) }
        func append(_ s: String) {
            let h = FileHandle(forWritingAtPath: path)!
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            h.closeFile()
        }
        func fileParse() -> JSONLParser.ParsedTranscript {
            JSONLParser.parse(data: fm.contents(atPath: path) ?? Data())
        }
        func inode() -> UInt64 {
            var st = stat()
            return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
        }

        TranscriptCache.retainOnly([])
        write(terminated.prefix(8).joined())
        var s0 = TranscriptCache.stats
        let r1 = TranscriptCache.parsed(path: path)
        check("b1 first read is a full parse and equals parse(file)",
              r1 == fileParse() && TranscriptCache.stats.fullParses == s0.fullParses + 1)

        s0 = TranscriptCache.stats
        check("b2 unchanged file → cached, no bytes read",
              TranscriptCache.parsed(path: path) == r1 && TranscriptCache.stats == s0)

        let line9 = terminated[8] + terminated[9]
        append(line9)
        s0 = TranscriptCache.stats
        let r2 = TranscriptCache.parsed(path: path)
        check("b3 append lines → incremental (reads only the \(line9.utf8.count) new bytes) == parse(file)",
              r2 == fileParse() && r2 != r1
              && TranscriptCache.stats.fullParses == s0.fullParses
              && TranscriptCache.stats.bytesRead == s0.bytesRead + Int64(line9.utf8.count))

        let partial = terminated[13]
        let cut = partial.utf8.count / 2 + 1   // mid-line; may land mid-codepoint
        let partialBytes = Array(partial.utf8)
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile()
        h.write(Data(partialBytes[..<cut]))
        h.closeFile()
        let r3 = TranscriptCache.parsed(path: path)
        let r3b = TranscriptCache.parsed(path: path)
        check("b4 partial line (no newline) → result unchanged", r3 == r2 && r3b == r2)

        s0 = TranscriptCache.stats
        let h2 = FileHandle(forWritingAtPath: path)!
        h2.seekToEndOfFile()
        h2.write(Data(partialBytes[cut...]))
        h2.closeFile()
        let r4 = TranscriptCache.parsed(path: path)
        check("b5 newline arrives → the line counts, == parse(file), still incremental",
              r4 == fileParse() && r4 != r2 && r4.openToolCalls.contains { $0.id == "t3" }
              && TranscriptCache.stats.fullParses == s0.fullParses)

        // Rewrite in place, smaller (same inode) → full re-parse.
        let inodeBefore = inode()
        let h3 = FileHandle(forWritingAtPath: path)!
        h3.truncateFile(atOffset: 0)
        h3.write(Data((terminated[0] + terminated[11]).utf8))
        h3.closeFile()
        s0 = TranscriptCache.stats
        let r5 = TranscriptCache.parsed(path: path)
        check("b6 truncate + rewrite (same inode, shrink) → full re-parse == parse(file)",
              inode() == inodeBefore && r5 == fileParse() && r5.customTitle == "renombrada"
              && TranscriptCache.stats.fullParses == s0.fullParses + 1)

        // Replace by rename with a LARGER file: only the inode tells it apart.
        let other = dir.appendingPathComponent("new.jsonl").path
        fm.createFile(atPath: other, contents: Data(terminated.suffix(from: 2).joined().utf8))
        _ = rename(other, path)
        s0 = TranscriptCache.stats
        let r6 = TranscriptCache.parsed(path: path)
        check("b7 replaced file (new inode, bigger) → full re-parse == parse(file)",
              inode() != inodeBefore && r6 == fileParse() && r6.cwd == nil
              && TranscriptCache.stats.fullParses == s0.fullParses + 1)

        // mtime moved backwards (with appended bytes) → full re-parse.
        append(terminated[0])
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: path)
        s0 = TranscriptCache.stats
        let r7 = TranscriptCache.parsed(path: path)
        check("b8 mtime backwards → full re-parse == parse(file)",
              r7 == fileParse() && TranscriptCache.stats.fullParses == s0.fullParses + 1)

        // Lines longer than one read chunk are carried across chunks.
        let big = String(repeating: "ä", count: TranscriptCache.chunkSize)   // 2 bytes each
        append(#"{"type":"assistant","message":{"id":"huge","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":""# + big + #""},{"type":"tool_use","id":"tb","name":"Big","input":{}}]}}"# + "\n")
        let r8 = TranscriptCache.parsed(path: path)
        check("b9 line bigger than a read chunk (\(2 * TranscriptCache.chunkSize / 1_048_576) MB) → == parse(file)",
              r8 == fileParse() && r8.lastToolName == "Big")

        TranscriptCache.retainOnly([])
        s0 = TranscriptCache.stats
        _ = TranscriptCache.parsed(path: path)
        check("b10 retainOnly drops the state → next read is a full parse",
              TranscriptCache.stats.fullParses == s0.fullParses + 1)
        TranscriptCache.retainOnly([])

        check("b11 missing file → empty",
              TranscriptCache.parsed(path: dir.appendingPathComponent("missing.jsonl").path) == .empty)
        return allPass
    }
}

/// `--incremental-realdata <dir>` (hidden, read-only): every *.jsonl under dir,
/// one-shot parse vs the same bytes fed split at 3 random line boundaries + 1
/// random mid-line point. Also reports whether dropping `api-request-blob`
/// lines before parsing would change the result.
enum IncrementalRealDataCheck {
    static func run(root: String) -> Bool {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else {
            print("realdata: cannot list \(root)")
            return false
        }
        var files: [String] = []
        for case let rel as String in walker where rel.hasSuffix(".jsonl") {
            files.append((root as NSString).appendingPathComponent(rel))
        }
        files.sort()
        let blobMarker = Data(#""type":"api-request-blob""#.utf8)
        var rng = SplitMix64(state: 7)
        var compared = 0, mismatches = 0, unreadable = 0, bytesTotal = 0
        var blobFilesChanged = 0, blobFiles = 0
        var blobFieldDiffs: [String: Int] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped) else {
                unreadable += 1
                continue
            }
            autoreleasepool {
                bytesTotal += data.count
                let full = JSONLParser.parse(data: data)
                var boundaries: [Int] = []
                var midLine: [Int] = []
                data.withUnsafeBytes { raw in
                    for (i, b) in raw.enumerated() where b == 0x0A { boundaries.append(i + 1) }
                }
                var cuts = (0..<3).compactMap { _ in boundaries.randomElement(using: &rng) }
                if data.count > 2 {
                    var p = Int.random(in: 1..<data.count, using: &rng)
                    var tries = 0
                    while data[p - 1] == 0x0A && tries < 20 {
                        p = Int.random(in: 1..<data.count, using: &rng)
                        tries += 1
                    }
                    midLine.append(p)
                }
                cuts = (cuts + midLine).sorted()
                var state = JSONLParser.ParserState()
                var prev = 0
                for cut in cuts + [data.count] where cut >= prev {
                    state.feed(data.subdata(in: prev..<cut))
                    prev = cut
                }
                compared += 1
                if state.snapshot() != full {
                    mismatches += 1
                    print("MISMATCH \(file) cuts=\(cuts)")
                }

                // Would a byte-level skip of api-request-blob lines change anything?
                guard data.range(of: blobMarker) != nil else { return }
                blobFiles += 1
                var kept = Data()
                kept.reserveCapacity(data.count)
                var start = 0
                for end in boundaries + (boundaries.last == data.count ? [] : [data.count]) {
                    let line = data[start..<end]
                    if line.range(of: blobMarker) == nil { kept.append(line) }
                    start = end
                }
                let skipped = JSONLParser.parse(data: kept)
                if skipped != full {
                    blobFilesChanged += 1
                    if skipped.toolCallCount != full.toolCallCount { blobFieldDiffs["toolCallCount", default: 0] += 1 }
                    if skipped.lastToolName != full.lastToolName { blobFieldDiffs["lastToolName", default: 0] += 1 }
                    if skipped.subagents != full.subagents { blobFieldDiffs["subagents", default: 0] += 1 }
                    if skipped.openToolCalls != full.openToolCalls { blobFieldDiffs["openToolCalls", default: 0] += 1 }
                    if skipped.usedTokens != full.usedTokens { blobFieldDiffs["usedTokens", default: 0] += 1 }
                }
            }
        }
        print("realdata: \(compared) files compared (\(bytesTotal / 1_000_000) MB), \(mismatches) mismatches, \(unreadable) unreadable")
        print("realdata: api-request-blob skip would change \(blobFilesChanged) of \(blobFiles) files with blobs; fields: \(blobFieldDiffs.sorted { $0.key < $1.key })")
        return mismatches == 0
    }
}

/// `--incremental-bench <transcript.jsonl>`: copies the transcript (minus its
/// last 60 lines) into a temp dir, primes TranscriptCache, then 12 rounds of
/// "append 5 lines → TranscriptCache.parsed". Never writes next to the source.
enum IncrementalBench {
    static func run(source: String) -> Bool {
        guard let all = FileManager.default.contents(atPath: source) else {
            print("bench: cannot read \(source)"); return false
        }
        var lines = all.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) + Data([0x0A]) }
        guard lines.count > 120 else { print("bench: source too short"); return false }
        let tail = Array(lines.suffix(60))
        lines.removeLast(60)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        FileManager.default.createFile(atPath: path, contents: lines.reduce(into: Data()) { $0.append($1) })

        func ms(_ f: () -> Void) -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            f()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        var r = JSONLParser.ParsedTranscript.empty
        let cold = ms { r = TranscriptCache.parsed(path: path) }
        var rounds: [Double] = []
        for i in 0..<12 {
            let h = FileHandle(forWritingAtPath: path)!
            h.seekToEndOfFile()
            h.write(tail[(i * 5)..<(i * 5 + 5)].reduce(into: Data()) { $0.append($1) })
            h.closeFile()
            rounds.append(ms { r = TranscriptCache.parsed(path: path) })
        }
        let full = ms { _ = try? JSONLParser.parse(url: URL(fileURLWithPath: path)) }
        let sorted = rounds.sorted()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print(String(format: "bench file=%.1f MB cold=%.1f ms append5: median=%.2f ms max=%.2f ms (n=%d) fullParse=%.1f ms used=%d tools=%d",
                     Double(size) / 1e6, cold, sorted[sorted.count / 2], sorted.last!, rounds.count, full,
                     r.usedTokens, r.toolCallCount))
        return true
    }
}
#endif
