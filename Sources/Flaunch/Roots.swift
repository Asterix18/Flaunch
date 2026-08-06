import Foundation

/// Security-scoped bookmarks for every root the launcher has been pointed at — not just the
/// current one — so searching across all recent roots can still read them after a restart.
enum RootBookmarks {
    private static let key = "CFL.rootBookmarks"

    private static var stored: [String: Data] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        else { return }
        var all = stored
        all[url.standardizedFileURL.path] = data
        stored = all
    }

    /// Resolves the saved bookmark for `path` and starts accessing it. Access is intentionally
    /// left open for the process lifetime — the indexer re-reads these roots whenever the search
    /// settings change, and balancing every call would just reopen them moments later.
    /// Returns the resolved URL,
    /// or nil when there's no bookmark — callers fall back to the raw path, which works for
    /// folders macOS doesn't gate.
    @discardableResult
    static func resolveAndAccess(path: String) -> URL? {
        guard let data = stored[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { save(url) }
        return url
    }

}
