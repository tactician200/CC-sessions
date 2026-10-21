import Foundation
import Darwin

/// In-memory, incremental parse cache keyed by transcript path. Transcripts are
/// append-only JSONL: when one grows (same inode, size not smaller, mtime not
/// earlier) only the new bytes are read and fed to the carried parser state.
/// Any other change (shrink, new inode, mtime backwards) drops the state and
/// parses the file from byte 0. A same-size same-mtime rewrite is not detected.
enum TranscriptCache {
    private struct Entry {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var mtime: Timestamp
        /// Bytes fed to `state`: always just past a "\n". An unterminated last
        /// line (being written) stays unread until its newline arrives.
        var offset: Int64
        var state: JSONLParser.ParserState
        var parsed: JSONLParser.ParsedTranscript
    }

    private struct Timestamp: Comparable {
        let sec: Int
        let nsec: Int
        static func < (l: Timestamp, r: Timestamp) -> Bool { (l.sec, l.nsec) < (r.sec, r.nsec) }
    }

    /// Test counters (`--incremental-selftest`).
    struct Stats: Equatable {
        var fullParses = 0
        var bytesRead: Int64 = 0
    }

    /// Big subagent transcripts (100+ MB) are read in chunks, never whole.
    static let chunkSize = 8 << 20

    private static var entries: [String: Entry] = [:]
    private static var counters = Stats()
    private static let lock = NSLock()

    static var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    static func parsed(path: String) -> JSONLParser.ParsedTranscript {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return .empty  // missing transcript
        }
        let size = Int64(st.st_size)
        let mtime = Timestamp(sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec)
        let device = st.st_dev
        let inode = UInt64(st.st_ino)

        lock.lock()
        let previous = entries[path]
        lock.unlock()

        var entry: Entry
        var full = false
        if let previous, previous.device == device, previous.inode == inode,
           size >= previous.size, mtime >= previous.mtime {
            if size == previous.size, mtime == previous.mtime {
                return previous.parsed
            }
            entry = previous
        } else {
            full = true
            entry = Entry(device: device, inode: inode, size: 0, mtime: mtime, offset: 0,
                          state: JSONLParser.ParserState(), parsed: .empty)
        }

        guard let read = advance(&entry, path: path, upTo: size) else {
            lock.lock()
            entries[path] = nil
            lock.unlock()
            return .empty  // unreadable: retried next scan
        }
        if read.consumed > 0 || full {
            entry.parsed = entry.state.snapshot()
        }
        entry.size = size
        entry.mtime = mtime

        lock.lock()
        entries[path] = entry
        if full { counters.fullParses += 1 }
        counters.bytesRead += read.bytes
        lock.unlock()
        return entry.parsed
    }

    /// Reads [entry.offset, size) and feeds it through the last "\n".
    /// Returns bytes read / consumed, nil if the file can't be read.
    private static func advance(_ entry: inout Entry, path: String,
                                upTo size: Int64) -> (bytes: Int64, consumed: Int64)? {
        guard entry.offset < size else { return (0, 0) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(entry.offset))
        } catch {
            return nil
        }
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var position = entry.offset   // file offset of buffer's end
        var bytes: Int64 = 0
        var consumed: Int64 = 0
        while position < size {
            let want = Int(min(Int64(chunkSize), size - position))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            position += Int64(chunk.count)
            bytes += Int64(chunk.count)
            buffer.append(chunk)
            guard let last = buffer.lastIndex(of: newline) else { continue }
            let lines = buffer[buffer.startIndex...last]
            entry.state.feed(lines)
            entry.offset += Int64(lines.count)
            consumed += Int64(lines.count)
            buffer = Data(buffer[buffer.index(after: last)...])
        }
        return (bytes, consumed)
    }

    /// Drop cache entries for transcripts no longer in the session list.
    static func retainOnly(_ paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }
}
