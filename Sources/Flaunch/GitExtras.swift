import Foundation

// MARK: - Extra git plumbing

extension Git {
    /// Author date of the most recent commit — one half of "when was this folder last worked on".
    static func lastCommitDate(at folder: URL) -> Date? {
        guard let output = run(["log", "-1", "--format=%ct"], at: folder),
              let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Fetches without merging, so ahead/behind counts reflect the remote as it is now.
    /// Returns true when the fetch actually ran.
    @discardableResult
    static func fetch(at folder: URL) -> Bool {
        guard run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], at: folder) != nil
        else { return false }   // no upstream: nothing to compare against, so don't pay for a fetch
        return run(["fetch", "--quiet"], at: folder, timeout: 20) != nil
    }

    /// Browsable web URL for the `origin` remote, translating scp-style git addresses
    /// (`git@github.com:org/repo.git`) into `https://github.com/org/repo`.
    static func remoteWebURL(at folder: URL) -> URL? {
        guard let raw = run(["remote", "get-url", "origin"], at: folder)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }

        var text = raw
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }

        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text)
        }
        // ssh://git@host/org/repo
        if text.hasPrefix("ssh://") {
            guard let url = URL(string: text), let host = url.host else { return nil }
            return URL(string: "https://\(host)\(url.path)")
        }
        // git@host:org/repo
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon {
            let host = String(text[text.index(after: at)..<colon])
            let path = String(text[text.index(after: colon)...])
            return URL(string: "https://\(host)/\(path)")
        }
        return nil
    }

    /// Display name for the remote host, so the menu can say "Open on GitHub" rather than
    /// a generic label when it knows better.
    static func remoteHostName(_ url: URL) -> String {
        switch url.host?.lowercased() {
        case "github.com":     return "GitHub"
        case "bitbucket.org":  return "Bitbucket"
        case "gitlab.com":     return "GitLab"
        case let host?:        return host
        case nil:              return "Remote"
        }
    }

    struct Worktree: Hashable {
        let url: URL
        let branch: String?
        /// The main checkout, as opposed to a linked worktree.
        let isPrimary: Bool
    }

    /// Every worktree attached to this repo, primary first (the order git reports).
    static func worktrees(at folder: URL) -> [Worktree] {
        guard let output = run(["worktree", "list", "--porcelain"], at: folder) else { return [] }
        var result: [Worktree] = []
        var path: String?
        var branch: String?

        // `git worktree list --porcelain` emits a `worktree <path>` line per entry, with the
        // branch (when not detached) on a following line, so each entry is flushed when the
        // next one starts.
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let path {
                    result.append(Worktree(url: URL(fileURLWithPath: path),
                                           branch: branch, isPrimary: result.isEmpty))
                }
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        if let path {
            result.append(Worktree(url: URL(fileURLWithPath: path), branch: branch, isPrimary: result.isEmpty))
        }
        return result
    }

    /// Creates a worktree for `branch` beside the repo, as `<repo>-<branch>`. Reuses the branch
    /// if it already exists, creates it otherwise. Returns the new worktree's URL or an error.
    static func addWorktree(repo: URL, branch: String) -> Result<URL, WorktreeError> {
        let slug = branch
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let target = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-\(slug)")

        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(.exists(target))
        }
        let branchExists = run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], at: repo) != nil
        let args = branchExists
            ? ["worktree", "add", target.path, branch]
            : ["worktree", "add", "-b", branch, target.path]
        guard run(args, at: repo, timeout: 60) != nil else {
            return .failure(.failed(branch))
        }
        return .success(target)
    }

    enum WorktreeError: Error {
        case exists(URL)
        case failed(String)

        var message: String {
            switch self {
            case .exists(let url):  return "“\(url.lastPathComponent)” already exists next to the repo."
            case .failed(let name): return "git couldn't create a worktree for “\(name)”."
            }
        }
    }
}

// MARK: - Git status cache

/// One place that knows every repo's status, so rows don't each shell out on every redraw,
/// a background fetch can refresh them all at once, and the menu bar can count dirty repos.
@MainActor
final class GitStatusStore: ObservableObject {
    @Published private(set) var statuses: [String: Git.Status] = [:]

    private var inFlight: Set<String> = []
    private var refreshedAt: [String: Date] = [:]
    private var fetchedAt: [String: Date] = [:]
    private let fetchedKey = "CFL.lastFetchedByPath"

    init() {
        let stored = (UserDefaults.standard.dictionary(forKey: fetchedKey) as? [String: Double]) ?? [:]
        fetchedAt = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func status(for url: URL) -> Git.Status? { statuses[url.path] }

    /// Ensures a reasonably fresh local status for `url` (no network). Coalesces concurrent
    /// requests for the same repo and skips ones refreshed within `maxAge`.
    func request(_ url: URL, maxAge: TimeInterval = 20) {
        let path = url.path
        guard !inFlight.contains(path) else { return }
        if let last = refreshedAt[path], Date().timeIntervalSince(last) < maxAge { return }
        inFlight.insert(path)
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { Git.status(at: url) }.value
            guard let self else { return }
            self.inFlight.remove(path)
            self.refreshedAt[path] = Date()
            if self.statuses[path] != status { self.statuses[path] = status }
        }
    }

    /// Force-refreshes local status for several repos (after a pull, say).
    func refresh(_ urls: [URL]) {
        for url in urls { refreshedAt[url.path] = nil }
        for url in urls { request(url, maxAge: 0) }
    }

    /// Repos due a fetch: git repos not fetched within `interval` seconds.
    func repositoriesNeedingFetch(_ urls: [URL], interval: TimeInterval) -> [URL] {
        let now = Date()
        return urls.filter { url in
            guard url.gitBranch != nil else { return false }
            guard let last = fetchedAt[url.path] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    /// Fetches the given repos a few at a time, then refreshes their statuses so the ahead/behind
    /// counters mean something. Silent: failures (offline, no upstream) just leave the counts as
    /// they were.
    func fetchSweep(_ urls: [URL], concurrency: Int = 3) async {
        guard !urls.isEmpty else { return }
        for chunk in stride(from: 0, to: urls.count, by: concurrency).map({ start in
            Array(urls[start..<min(start + concurrency, urls.count)])
        }) {
            await withTaskGroup(of: Void.self) { group in
                for url in chunk {
                    group.addTask(priority: .utility) { _ = Git.fetch(at: url) }
                }
            }
            for url in chunk { fetchedAt[url.path] = Date() }
            refresh(chunk)
        }
        persistFetchTimes()
    }

    private func persistFetchTimes() {
        // Keep the store from growing forever: only remember repos fetched in the last month.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        fetchedAt = fetchedAt.filter { $0.value > cutoff }
        UserDefaults.standard.set(fetchedAt.mapValues { $0.timeIntervalSince1970 }, forKey: fetchedKey)
    }

    struct PullSummary {
        var pulled: [String] = []
        var skippedDirty: [String] = []
        var failed: [String] = []
    }

    /// Pulls every repo that is behind its upstream and has a clean working tree. Repos with
    /// uncommitted changes are reported rather than touched — a pull there is the user's call.
    /// `fetchFirst` is for pulling a single repo on demand: without it, "behind" is only as
    /// fresh as the last fetch, so an explicit Pull could report nothing to do while the remote
    /// had moved on.
    func pullAll(_ urls: [URL], fetchFirst: Bool = false,
                 onProgress: @Sendable @escaping (String) -> Void) async -> PullSummary {
        var summary = PullSummary()
        let repos = urls.filter { $0.gitBranch != nil }
        for url in repos {
            let name = url.lastPathComponent
            onProgress("Checking \(name)…")
            if fetchFirst {
                _ = await Task.detached(priority: .userInitiated) { Git.fetch(at: url) }.value
            }
            let status = await Task.detached(priority: .userInitiated) { Git.status(at: url) }.value
            statuses[url.path] = status
            guard status.hasUpstream else { continue }
            guard status.behind > 0 else { continue }
            guard !status.dirty else { summary.skippedDirty.append(name); continue }

            onProgress("Pulling \(name)…")
            let failure = await Task.detached(priority: .userInitiated) { Git.pull(at: url) }.value
            if failure == nil { summary.pulled.append(name) } else { summary.failed.append(name) }
        }
        refresh(repos)
        return summary
    }
}

// MARK: - Folder insights (activity + Claude history)

/// What the launcher knows about a folder beyond its name: when it was last worked on, and how
/// much Claude history it has. Drives the row subtitles and the "sort by activity" order.
struct FolderInsight: Equatable {
    var sessions: ClaudeSessions.Summary?
    var lastCommit: Date?
    var modified: Date?

    /// The most recent signal of any kind — a commit, a Claude session, or a file change.
    var activity: Date {
        [sessions?.last, lastCommit, modified].compactMap { $0 }.max() ?? .distantPast
    }
}

@MainActor
final class InsightIndex: ObservableObject {
    @Published private(set) var byPath: [String: FolderInsight] = [:]
    private var loading: Set<String> = []
    private var loadedAt: [String: Date] = [:]

    func insight(for url: URL) -> FolderInsight? { byPath[url.path] }

    func activity(for url: URL) -> Date { byPath[url.path]?.activity ?? .distantPast }

    /// Loads insights for a batch of folders off the main actor. Cheap per folder (a directory
    /// listing plus at most one `git log`), and re-read at most every `maxAge` seconds.
    func request(_ urls: [URL], maxAge: TimeInterval = 60) {
        let now = Date()
        let pending = urls.filter { url in
            let path = url.path
            if loading.contains(path) { return false }
            if let last = loadedAt[path], now.timeIntervalSince(last) < maxAge { return false }
            return true
        }
        guard !pending.isEmpty else { return }
        pending.forEach { loading.insert($0.path) }

        Task { [weak self] in
            let results = await Task.detached(priority: .utility) { () -> [(String, FolderInsight)] in
                pending.map { url in
                    var insight = FolderInsight()
                    insight.sessions = ClaudeSessions.summary(for: url)
                    insight.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    if url.gitBranch != nil { insight.lastCommit = Git.lastCommitDate(at: url) }
                    return (url.path, insight)
                }
            }.value
            guard let self else { return }
            for (path, insight) in results {
                self.loading.remove(path)
                self.loadedAt[path] = Date()
                if self.byPath[path] != insight { self.byPath[path] = insight }
            }
        }
    }

    /// Drops cached values for these folders so the next request re-reads them.
    func invalidate(_ urls: [URL]) {
        for url in urls { loadedAt[url.path] = nil }
    }
}
