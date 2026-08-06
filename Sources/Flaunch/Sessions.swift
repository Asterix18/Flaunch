import AppKit
import Foundation

// MARK: - Claude Code transcripts

/// One recorded Claude Code session: a `<uuid>.jsonl` transcript inside the folder's
/// entry under `~/.claude/projects`.
struct ClaudeSession: Identifiable, Hashable {
    /// The session UUID — what `claude --resume <id>` wants.
    let id: String
    let file: URL
    let modified: Date
}

/// Reads Claude Code's on-disk session transcripts, so the launcher can offer to resume what you
/// were last doing in a folder — including sessions started from a plain terminal.
///
/// Everything here is cheap filesystem metadata (a directory listing plus modification dates);
/// only the session *labels* parse transcript contents, and those are read lazily with a byte cap
/// because a long session's jsonl can run to tens of megabytes.
enum ClaudeSessions {
    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)

    /// Claude Code names each project's transcript directory after the folder's absolute path
    /// with every character that isn't an ASCII letter or digit replaced by a hyphen — so
    /// `/Users/me/My Repo` becomes `-Users-me-My-Repo`. Lossy (a space, dot and underscore all
    /// collapse to `-`), so only ever used in this direction: folder → directory.
    static func directoryName(for folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path.unicodeScalars {
            let isAlnum = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9")
            out.append(isAlnum ? Character(ch) : "-")
        }
        return out
    }

    static func transcriptDirectory(for folder: URL) -> URL {
        projectsRoot.appendingPathComponent(directoryName(for: folder), isDirectory: true)
    }

    /// How much Claude history a folder has: how many sessions, and when the last one was
    /// touched. Nil when the folder has never been opened in Claude Code.
    struct Summary: Equatable {
        var count: Int
        var last: Date
    }

    static func summary(for folder: URL) -> Summary? {
        let files = transcriptFiles(for: folder)
        guard let latest = files.map(\.modified).max() else { return nil }
        return Summary(count: files.count, last: latest)
    }

    /// Sessions for `folder`, most recently active first.
    static func sessions(for folder: URL, limit: Int = 8) -> [ClaudeSession] {
        transcriptFiles(for: folder)
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { $0 }
    }

    private static func transcriptFiles(for folder: URL) -> [ClaudeSession] {
        let dir = transcriptDirectory(for: folder)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return ClaudeSession(id: url.deletingPathExtension().lastPathComponent,
                                 file: url, modified: modified)
        }
    }

    // MARK: Session labels

    private static let labelLock = NSLock()
    /// Keyed by "<path>|<mtime>" so an appended-to transcript re-reads but a stable one doesn't.
    nonisolated(unsafe) private static var labelCache: [String: String] = [:]

    /// A human label for a session: its opening prompt, trimmed to one short line.
    /// Falls back to the date when no usable prompt can be found.
    static func label(for session: ClaudeSession) -> String {
        let key = "\(session.file.path)|\(session.modified.timeIntervalSince1970)"
        labelLock.lock()
        let cached = labelCache[key]
        labelLock.unlock()
        if let cached { return cached }

        let label = firstPrompt(in: session.file) ?? Self.dateFormatter.string(from: session.modified)
        labelLock.lock()
        if labelCache.count > 400 { labelCache.removeAll() }   // crude cap; labels are cheap to redo
        labelCache[key] = label
        labelLock.unlock()
        return label
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Scans the transcript for the first real user turn and returns its text, condensed to a
    /// single line of at most `maxLength` characters.
    ///
    /// Stops after `byteCap` bytes: transcripts are append-only and the opening prompt is near
    /// the top, but a pasted image can make the very first line enormous, so oversized lines are
    /// skipped without being parsed.
    private static func firstPrompt(in file: URL, byteCap: Int = 1 << 20, maxLength: Int = 72) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var scanned = 0
        let newline = UInt8(ascii: "\n")

        while scanned < byteCap {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            scanned += chunk.count
            buffer.append(chunk)

            while let index = buffer.firstIndex(of: newline) {
                let line = buffer[buffer.startIndex..<index]
                buffer = buffer[buffer.index(after: index)...]
                // A line this long is an embedded attachment, not a prompt worth showing.
                guard line.count < 64 * 1024 else { continue }
                if let text = prompt(fromLine: Data(line), maxLength: maxLength) { return text }
            }
        }
        return nil
    }

    private static func prompt(fromLine line: Data, maxLength: Int) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "user",
              object["isSidechain"] as? Bool != true,
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }

        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard var candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty
        else { return nil }

        // Skip the machinery: slash-command wrappers, system reminders, tool output, resumed-session
        // caveats. None of them describe what the session was about.
        if candidate.hasPrefix("<") || candidate.hasPrefix("Caveat:") { return nil }

        candidate = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        while candidate.contains("  ") {
            candidate = candidate.replacingOccurrences(of: "  ", with: " ")
        }
        if candidate.count > maxLength {
            candidate = String(candidate.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return candidate
    }
}

// MARK: - Live session detection

/// Knows which folders have a Claude Code process running in them, so clicking a folder can bring
/// an existing session's window forward instead of starting a second Claude in the same repo.
///
/// Detection is a two-step shell-out: `ps` for processes whose executable is named exactly
/// `claude` (the CLI and the desktop app's embedded binary both are; `Claude`, `Claude Helper`
/// and friends are not), then one batched `lsof` to read each one's working directory. It runs
/// when the launcher opens — not on a timer — so nothing is scanning while it's closed.
@MainActor
final class ActiveSessions {
    private var paths: Set<String> = []
    private var refreshing = false

    func isActive(_ url: URL) -> Bool { paths.contains(url.standardizedFileURL.path) }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { ProcessScan.claudeSessions() }.value
            guard let self else { return }
            self.refreshing = false
            guard !scan.failed else { return }
            self.paths = Set(scan.cwdByPid.values)
        }
    }
}

/// The `ps` + `lsof` scan, off the main actor.
private enum ProcessScan {
    struct Result {
        var cwdByPid: [Int32: String] = [:]
        var failed = false
    }

    static func claudeSessions() -> Result {
        guard let listing = shell("/bin/ps", ["-Ao", "pid=,comm="]) else {
            return Result(failed: true)
        }
        var pids: [Int32] = []
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            // Exactly `claude` — matches the CLI and the desktop app's bundled binary, but not
            // `Claude`, `Claude Helper`, `claude-code` wrappers or the `disclaimer` shim.
            guard (command as NSString).lastPathComponent == "claude" else { continue }
            pids.append(pid)
        }
        guard !pids.isEmpty else { return Result() }

        let list = pids.map(String.init).joined(separator: ",")
        // -Fn gives machine-readable output: `p<pid>` then `fcwd` then `n<path>`.
        guard let cwds = shell("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fn"]) else {
            return Result(failed: true)
        }
        var result = Result()
        var current: Int32?
        for line in cwds.split(separator: "\n") {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p": current = Int32(value)
            case "n":
                if let pid = current, value.hasPrefix("/") {
                    result.cwdByPid[pid] = URL(fileURLWithPath: value).standardizedFileURL.path
                }
            default: break
            }
        }
        return result
    }

    private static func shell(_ executable: String, _ arguments: [String],
                              timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // The watchdog has to be armed before reading: `lsof` output can outgrow the pipe buffer,
        // so the read must come first, and a hung process would otherwise block it forever —
        // leaving the scan permanently "in flight" and session reuse silently dead.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        // `lsof` exits non-zero when it can't examine every pid, but whatever it did print is
        // still usable — only treat "no output and a bad exit" as a failed scan.
        if data.isEmpty && process.terminationStatus != 0 { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Relative time

enum RelativeTime {
    /// Compact "when did this last happen" text: `now`, `12m`, `3h`, `2d`, `5w`.
    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:            return "now"
        case ..<3_600:         return "\(Int(seconds / 60))m"
        case ..<86_400:        return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 7):  return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 7)))w"
        default:               return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
}
