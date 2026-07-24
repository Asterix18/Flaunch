import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox

// MARK: - Model

/// Neutral palette — a single light grey used for every folder tile, card, and highlight
/// so nothing competes with the folder names.
enum Palette {
    /// Grey gradient for the folder icon tiles (white glyphs sit on top).
    static let tile: [Color] = [Color(white: 0.64), Color(white: 0.52)]
    static let hover = Color.secondary.opacity(0.14)
    static let selection = Color.secondary.opacity(0.26)

    // Git status accents — the one place colour is meaningful.
    static let dirty = Color.orange
    static let ahead = Color.blue
    static let behind = Color(red: 0.60, green: 0.36, blue: 0.90)   // violet
    static let clean = Color.green
}

/// A folder discovered by the deep root search, with its path relative to the root.
struct SearchEntry: Hashable {
    let url: URL
    let relativePath: String   // e.g. "PROJECTS/RMS" — the parent chain, for display
}

@MainActor
final class FolderModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var currentURL: URL?
    @Published var subfolders: [URL] = []
    /// Non-directory files in the current folder (used by the Scripts view).
    @Published var files: [URL] = []
    /// When non-nil, the UI shows the first-run setup flow for this root (choose which
    /// folders to show). Set whenever the user actively picks/switches a root.
    @Published var pendingSetupRoot: URL?
    @Published var errorMessage: String?
    @Published var isCloning = false
    /// Flattened index of folders beneath the root, used by the top-level filter.
    @Published var searchIndex: [SearchEntry] = []
    let recents = RecentFolders()
    let favorites = Favorites()
    let history = LaunchHistory()
    let prefs: Preferences

    /// Ancestors of `currentURL` back up to `rootURL`, used by the back button.
    private var navigationStack: [URL] = []

    private let bookmarkKey = "ClaudeFolderLauncher.rootBookmark"

    var canGoBack: Bool { !navigationStack.isEmpty }

    init(prefs: Preferences) {
        self.prefs = prefs
        restoreBookmark()
    }

    func switchTo(_ url: URL) {
        setRoot(url, showSetup: true)
        saveBookmark(url)
    }

    /// Descends into `folder`, listing its subfolders. `folder` must be within
    /// the security-scoped root, so no separate bookmark is needed.
    func navigateInto(_ folder: URL) {
        guard let current = currentURL else { return }
        navigationStack.append(current)
        currentURL = folder
        loadSubfolders()
    }

    func navigateBack() {
        guard let previous = navigationStack.popLast() else { return }
        currentURL = previous
        loadSubfolders()
    }

    /// Jumps directly to `target` (a deep search result), rebuilding the back stack
    /// from the root down to the target's parent so the back button walks up naturally.
    func navigateTo(_ target: URL) {
        guard let root = rootURL else { return }
        let rootComps = root.pathComponents
        let targetComps = target.pathComponents
        guard targetComps.count > rootComps.count else { return }

        var stack: [URL] = [root]
        var url = root
        // Everything strictly between the root and the target's own name is an ancestor.
        for comp in targetComps[rootComps.count..<(targetComps.count - 1)] {
            url = url.appendingPathComponent(comp)
            stack.append(url)
        }
        navigationStack = stack
        currentURL = target
        loadSubfolders()
    }

    // MARK: - Favourites & history helpers

    func togglePin(_ url: URL) { favorites.toggle(url) }
    func isPinned(_ url: URL) -> Bool { favorites.contains(url) }

    /// Wraps a URL as a SearchEntry, computing its parent path relative to the root
    /// (or an abbreviated absolute path if it lives outside the current root).
    func entry(for url: URL) -> SearchEntry {
        if let root = rootURL, url.path.hasPrefix(root.path + "/") {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            return SearchEntry(url: url, relativePath: (rel as NSString).deletingLastPathComponent)
        }
        let parent = url.deletingLastPathComponent().path
        return SearchEntry(url: url, relativePath: (parent as NSString).abbreviatingWithTildeInPath)
    }

    var pinnedEntries: [SearchEntry] {
        favorites.urls().map { entry(for: $0) }
    }

    /// Recently/frequently launched folders, excluding ones already pinned.
    func recentEntries(limit: Int = 5) -> [SearchEntry] {
        history.ranked(limit: limit + favorites.paths.count)
            .filter { !favorites.contains($0) }
            .prefix(limit)
            .map { entry(for: $0) }
    }

    /// Creates the configured featured top-level folders inside the current root.
    func createSpecialFolders() {
        guard let root = rootURL else { return }
        for name in prefs.featuredFolderNames {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        loadSubfolders()
    }

    /// Prompts for a git URL and clones it into the folder currently being browsed.
    func promptCloneRepo() {
        guard let target = currentURL else { return }

        let alert = NSAlert()
        alert.messageText = "Clone Repository"
        alert.informativeText = "Enter a git URL to clone into \"\(target.lastPathComponent)\"."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "git@github.com:org/repo.git"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        cloneRepo(urlString, into: target)
    }

    /// Clones `urlString` into `folder`. `openWhenDone` opens the fresh repo in Claude (as when
    /// cloning from the header); the New-Project flow turns it off and uses `completion` to chain
    /// the next "add a repo" prompt.
    private func cloneRepo(_ urlString: String, into folder: URL,
                           openWhenDone: Bool = true, completion: (() -> Void)? = nil) {
        isCloning = true
        errorMessage = nil
        let before = folderNames(in: folder)
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                Git.clone(urlString, into: folder)
            }.value
            guard let self = self else { return }
            self.isCloning = false
            guard failure == nil else {
                self.errorMessage = failure
                completion?()
                return
            }
            self.loadSubfolders()
            // Open the newly cloned repo directly in Claude, same as clicking any folder row.
            if openWhenDone,
               let cloned = self.subfolders.first(where: { !before.contains($0.lastPathComponent) }) {
                self.openInTerminal(cloned)
            }
            completion?()
        }
    }

    // MARK: New project

    /// Prompts for a name and scaffolds a standardized project in the current folder, then walks
    /// the user through adding git repositories to it.
    func promptNewProject() {
        guard let parent = currentURL else { return }

        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = "Create a project in \"\(parent.lastPathComponent)\" with your standard folder structure."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "Project name"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        createProject(named: name, in: parent)
    }

    /// Creates `<parent>/<name>/` with the configured template folders and a seeded CLAUDE.md /
    /// README.md, shows it, then offers to add repositories.
    func createProject(named name: String, in parent: URL) {
        guard let project = scaffoldProject(named: name, in: parent) else { return }
        navigateInto(project)                    // show the new project's contents
        promptAddRepositories(to: project)
    }

    /// Pure filesystem scaffold (no UI): makes the project + template folders and seeds
    /// CLAUDE.md / README.md. Returns the project URL, or nil on failure (sets `errorMessage`).
    @discardableResult
    func scaffoldProject(named name: String, in parent: URL) -> URL? {
        let fm = FileManager.default
        let project = parent.appendingPathComponent(name)
        guard !fm.fileExists(atPath: project.path) else {
            errorMessage = "“\(name)” already exists here."
            return nil
        }
        let folders = prefs.projectFolders
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            for folder in folders {
                try fm.createDirectory(at: project.appendingPathComponent(folder),
                                       withIntermediateDirectories: true)
            }
            try FolderModel.seededClaudeMd(name: name, folders: folders)
                .write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
            try FolderModel.seededReadme(name: name, folders: folders)
                .write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't create project: \(error.localizedDescription)"
            return nil
        }
        return project
    }

    /// Loop-prompts the user to clone git repos into `<project>/Repositories`, then reopens the
    /// launcher on the finished project.
    func promptAddRepositories(to project: URL) {
        let repos = project.appendingPathComponent("Repositories")
        // If the template has no Repositories folder, drop the repo step entirely.
        guard FileManager.default.fileExists(atPath: repos.path) else {
            NotificationCenter.default.post(name: .cflShowLauncher, object: nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Add a Repository"
        alert.informativeText = "Clone a git repo into \(project.lastPathComponent)/Repositories. Leave blank when you're done."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Done")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "git@github.com:org/repo.git"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard response == .alertFirstButtonReturn, !urlString.isEmpty else {
            loadSubfolders()
            NotificationCenter.default.post(name: .cflShowLauncher, object: nil)
            return
        }
        cloneRepo(urlString, into: repos, openWhenDone: false) { [weak self] in
            DispatchQueue.main.async { self?.promptAddRepositories(to: project) }
        }
    }

    /// Starter CLAUDE.md for a new project, listing the template folders so it stays in sync.
    private static func seededClaudeMd(name: String, folders: [String]) -> String {
        let descriptions = folderDescriptions
        let list = folders.map { "- `\($0)/` — \(descriptions[$0] ?? "")".trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return """
        # \(name)

        Project instructions for Claude Code. Because this file sits at the project root, it's
        picked up automatically for every repository under `Repositories/`.

        ## Overview

        <what this project is, who it's for, current status>

        ## Structure

        \(list)

        ## Conventions

        <coding standards, environments, credentials, gotchas>
        """
    }

    /// Starter README.md for a new project.
    private static func seededReadme(name: String, folders: [String]) -> String {
        let descriptions = folderDescriptions
        let rows = folders.map { "| `\($0)/` | \(descriptions[$0] ?? "") |" }.joined(separator: "\n")
        return """
        # \(name)

        ## Structure

        | Folder | Contents |
        | --- | --- |
        \(rows)

        _Scaffolded by Flaunch._
        """
    }

    private static let folderDescriptions: [String: String] = [
        "Repositories": "Cloned git repos (the code)",
        "Data": "Datasets, exports, sample data",
        "Scripts": "Automation & one-off utilities",
        "Docs": "Specs, notes, decisions",
        "Reference": "External specs / client-supplied material",
    ]

    private func folderNames(in folder: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return Set(contents.map { $0.lastPathComponent })
    }

    func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Pick a folder whose subfolders you want to open with Claude."

        // Bring the app forward so the panel is focused.
        NSApp.activate(ignoringOtherApps: true)

        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url, showSetup: true)
            saveBookmark(url)
            // The transient popover closed when the open-panel took over; reopen it so the
            // user lands straight on the setup screen instead of re-clicking the menu icon.
            NotificationCenter.default.post(name: .cflShowLauncher, object: nil)
        }
    }

    /// Points the launcher at `url`. `showSetup` opens the choose-folders setup flow —
    /// true when the user actively picks/switches a root, false when silently restoring
    /// the saved root on launch.
    func setRoot(_ url: URL, showSetup: Bool = false) {
        rootURL = url
        currentURL = url
        navigationStack = []
        loadSubfolders()
        recents.add(url)
        if showSetup { pendingSetupRoot = url }
    }

    func loadSubfolders() {
        guard let current = currentURL else { return }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let byName: (URL, URL) -> Bool = {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            subfolders = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted(by: byName)
            files = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
                .sorted(by: byName)
            errorMessage = nil
        } catch {
            subfolders = []
            files = []
            errorMessage = "Could not read folder: \(error.localizedDescription)"
        }
        // Only the root drives the deep filter, so (re)build the index whenever the root loads.
        if current == rootURL {
            rebuildSearchIndex()
        }
    }

    private func rebuildSearchIndex() {
        guard let root = rootURL else { searchIndex = []; return }
        Task { [weak self] in
            let entries = await Task.detached(priority: .utility) {
                FolderModel.indexDescendants(of: root)
            }.value
            self?.searchIndex = entries
        }
    }

    /// Walks the folder tree beneath `root` and returns every directory found, with its
    /// relative parent path. Descends up to `maxDepth` levels and stops at git repos
    /// (so project internals like `node_modules` are never scanned), and skips a few
    /// well-known heavy/build directories.
    nonisolated private static func indexDescendants(of root: URL, maxDepth: Int = 4) -> [SearchEntry] {
        let skip: Set<String> = ["node_modules", ".build", "DerivedData", "Pods",
                                 "venv", ".venv", "__pycache__", ".git"]
        let fm = FileManager.default
        var result: [SearchEntry] = []

        func walk(_ dir: URL, depth: Int) {
            guard depth < maxDepth else { return }
            let contents = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in contents {
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !skip.contains(item.lastPathComponent)
                else { continue }

                let rel = String(item.path.dropFirst(root.path.count + 1))
                let parent = (rel as NSString).deletingLastPathComponent
                result.append(SearchEntry(url: item, relativePath: parent))

                // Stop at project boundaries: don't scan inside a git repo.
                if item.gitBranch == nil {
                    walk(item, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    func openInFinder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    /// Opens a file (e.g. CLAUDE.md / README.md) in its default app.
    func openFile(_ file: URL) {
        NSWorkspace.shared.open(file)
    }

    /// Reveals a file in Finder (selected).
    func revealInFinder(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Known script extensions we can run without an executable bit.
    static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "command", "py", "rb", "pl", "js", "mjs", "cjs", "ts",
    ]

    /// Whether `file` looks runnable: it's executable, or has a known script extension.
    func isScript(_ file: URL) -> Bool {
        if FileManager.default.isExecutableFile(atPath: file.path) { return true }
        return FolderModel.scriptExtensions.contains(file.pathExtension.lowercased())
    }

    /// Runs `file` in a terminal opened at its folder, so output is visible.
    func runScript(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        history.record(folder)
        let command = scriptRunCommand(for: file)
        if let error = TerminalLauncher.launch(
            folder: folder, command: command, terminalBundleId: prefs.terminalBundleId
        ) {
            errorMessage = error
        }
    }

    /// Builds the shell command to run `file` (already cd'd into its folder): `./name` when
    /// executable, otherwise the matching interpreter by extension.
    private func scriptRunCommand(for file: URL) -> String {
        let name = file.lastPathComponent
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if FileManager.default.isExecutableFile(atPath: file.path) {
            return "./\(quoted)"
        }
        switch file.pathExtension.lowercased() {
        case "py":                 return "python3 \(quoted)"
        case "js", "mjs", "cjs":   return "node \(quoted)"
        case "ts":                 return "node \(quoted)"
        case "rb":                 return "ruby \(quoted)"
        case "pl":                 return "perl \(quoted)"
        case "zsh":                return "zsh \(quoted)"
        default:                   return "bash \(quoted)"   // sh, bash, command, or unknown
        }
    }

    func copyPath(_ folder: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(folder.path, forType: .string)
    }

    func openInEditor(_ folder: URL, bundleId: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            errorMessage = "Editor not found"
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config) { _, error in
            if let error = error {
                NSLog("Failed to open in editor: \(error)")
            }
        }
    }

    func openInTerminal(_ folder: URL, runClaude: Bool = true) {
        // A plain terminal just cd's in — skip the git upstream check entirely.
        guard runClaude else {
            launchTerminal(folder, runPullFirst: false, runClaude: false)
            return
        }

        // If it's a git repo, fetch and check whether the upstream is ahead before launching.
        guard folder.gitBranch != nil else {
            launchTerminal(folder, runPullFirst: false)
            return
        }

        Task { [weak self] in
            let behind = await Task.detached(priority: .userInitiated) {
                Git.fetchAndCountBehindUpstream(at: folder)
            }.value
            await MainActor.run {
                guard let self = self else { return }
                if behind > 0 {
                    let pull = self.confirmPull(behind: behind, folder: folder)
                    switch pull {
                    case .pullAndOpen:
                        self.launchTerminal(folder, runPullFirst: true)
                    case .openAnyway:
                        self.launchTerminal(folder, runPullFirst: false)
                    case .cancel:
                        return
                    }
                } else {
                    self.launchTerminal(folder, runPullFirst: false)
                }
            }
        }
    }

    private enum PullChoice { case pullAndOpen, openAnyway, cancel }

    private func confirmPull(behind: Int, folder: URL) -> PullChoice {
        let alert = NSAlert()
        alert.messageText = "Updates available for \(folder.lastPathComponent)"
        let commits = behind == 1 ? "1 commit" : "\(behind) commits"
        alert.informativeText = "The remote branch is \(commits) ahead of your local branch. Pull the latest changes before launching Claude?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Pull and Open")
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .pullAndOpen
        case .alertSecondButtonReturn: return .openAnyway
        default:                       return .cancel
        }
    }

    private func launchTerminal(_ folder: URL, runPullFirst: Bool, runClaude: Bool = true) {
        history.record(folder)
        // A plain terminal just cd's in (command == nil); the Claude variants run the configured
        // launch command, optionally pulling first.
        let command: String?
        if !runClaude {
            command = nil
        } else if runPullFirst {
            command = "git pull && \(prefs.launchCommand)"
        } else {
            command = prefs.launchCommand
        }
        if let error = TerminalLauncher.launch(
            folder: folder, command: command, terminalBundleId: prefs.terminalBundleId
        ) {
            errorMessage = error
        }
    }

    // MARK: - Security-scoped bookmark persistence

    private func saveBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // Bookmark persistence is best-effort; ignore failures.
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            _ = url.startAccessingSecurityScopedResource()
            setRoot(url)
        } catch {
            // Stale or invalid bookmark; user will pick again.
        }
    }
}

// MARK: - Git branch detection

extension URL {
    /// Returns the current git branch name (or short SHA if detached) for this folder, if it's a git repo.
    /// Reads `.git/HEAD` directly — no shell-out, fast for tens of folders.
    var gitBranch: String? {
        let gitPath = self.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir) else {
            return nil
        }

        // Resolve the actual git directory (handles worktrees & submodules where .git is a file).
        let actualGitDir: URL
        if isDir.boolValue {
            actualGitDir = gitPath
        } else {
            guard let content = try? String(contentsOf: gitPath, encoding: .utf8),
                  content.hasPrefix("gitdir: ")
            else { return nil }
            let path = String(content.dropFirst("gitdir: ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            actualGitDir = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : self.appendingPathComponent(path).standardized
        }

        let headFile = actualGitDir.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headFile, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(7))   // detached HEAD
    }
}

// MARK: - Git helpers

enum Git {
    /// Clones `urlString` into `folder`. Returns nil on success, or the git error text on failure.
    static func clone(_ urlString: String, into folder: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--quiet", urlString]
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return "Failed to launch git: \(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            return "git clone timed out"
        }

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (message?.isEmpty == false) ? message! : "git clone failed with status \(process.terminationStatus)"
        }
        return nil
    }

    /// Returns true if the working tree has uncommitted changes (staged, unstaged, or untracked).
    static func isDirty(at folder: URL) -> Bool {
        guard let output = run(["status", "--porcelain"], at: folder) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A snapshot of a repo's local state — no network, so it reflects the last known
    /// upstream position rather than fetching.
    struct Status: Equatable {
        var dirty = false
        var hasUpstream = false
        var ahead = 0      // local commits not on the upstream
        var behind = 0     // upstream commits not merged (as of the last fetch)
    }

    static func status(at folder: URL) -> Status {
        var s = Status()
        if let output = run(["status", "--porcelain"], at: folder) {
            s.dirty = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Only ask about ahead/behind if an upstream is configured.
        guard run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], at: folder) != nil else {
            return s
        }
        s.hasUpstream = true
        if let counts = run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], at: folder) {
            let nums = counts.split { $0 == "\t" || $0 == " " || $0 == "\n" }.compactMap { Int($0) }
            if nums.count == 2 { s.ahead = nums[0]; s.behind = nums[1] }
        }
        return s
    }

    /// Runs `git fetch` then returns how many commits the upstream is ahead of HEAD.
    /// Returns 0 if there is no upstream, no remote, or anything goes wrong.
    static func fetchAndCountBehindUpstream(at folder: URL) -> Int {
        // Fail fast if there's no upstream configured — avoids a slow fetch on local-only repos.
        guard run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], at: folder) != nil else {
            return 0
        }
        _ = run(["fetch", "--quiet"], at: folder, timeout: 15)
        guard let output = run(["rev-list", "--count", "HEAD..@{u}"], at: folder),
              let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return count
    }

    @discardableResult
    private static func run(_ args: [String], at folder: URL, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = folder
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Editor detection

struct EditorOption {
    let name: String
    let bundleId: String
}

enum Editors {
    static let known: [EditorOption] = [
        EditorOption(name: "VS Code",  bundleId: "com.microsoft.VSCode"),
        EditorOption(name: "Cursor",   bundleId: "com.todesktop.230313mzl4w4u92"),
        EditorOption(name: "Xcode",    bundleId: "com.apple.dt.Xcode"),
        EditorOption(name: "Zed",      bundleId: "dev.zed.Zed"),
        EditorOption(name: "Sublime Text", bundleId: "com.sublimetext.4"),
    ]

    static var available: [EditorOption] {
        known.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil
        }
    }
}

// MARK: - Preferences

extension Notification.Name {
    /// Posted when the user changes the global hotkey, so the AppDelegate re-registers it.
    static let cflHotKeyChanged = Notification.Name("CFLHotKeyChanged")
    /// Posted from the footer menu to ask the AppDelegate to open the settings window.
    static let cflOpenSettings = Notification.Name("CFLOpenSettings")
    /// Posted after the folder picker returns, so the AppDelegate reopens the popover
    /// (the transient popover closes while the macOS open-panel is up).
    static let cflShowLauncher = Notification.Name("CFLShowLauncher")
}

/// User-configurable settings, persisted to UserDefaults. Injected into the model and views
/// and observed by the AppDelegate (for the hotkey).
@MainActor
final class Preferences: ObservableObject {
    /// Bundle id of the terminal app launches open in (defaults to Terminal.app).
    @Published var terminalBundleId: String { didSet { d.set(terminalBundleId, forKey: Keys.terminal) } }
    /// Command run after cd-ing into a folder (defaults to `claude`).
    @Published var launchCommand: String { didSet { d.set(launchCommand, forKey: Keys.command) } }
    /// Top-level folder names surfaced as quick shortcuts at the root.
    @Published var featuredFolderNames: [String] { didSet { d.set(featuredFolderNames, forKey: Keys.featured) } }
    /// Per-root allow-list of subfolder names to show at that root, keyed by the root's
    /// path. Absent = show everything (default). Chosen in the first-run setup flow;
    /// hidden folders stay reachable via search.
    @Published var shownFoldersByRoot: [String: [String]] { didSet { d.set(shownFoldersByRoot, forKey: Keys.shown) } }
    /// Folder names created inside each new project scaffold (plus a seeded CLAUDE.md and README.md).
    @Published var projectFolders: [String] { didSet { d.set(projectFolders, forKey: Keys.projectFolders) } }
    /// Global hotkey virtual key code + Carbon modifier mask, plus a display string.
    @Published private(set) var hotKeyCode: UInt32
    @Published private(set) var hotKeyModifiers: UInt32
    @Published private(set) var hotKeyDisplay: String

    static let defaultHotKeyCode = UInt32(kVK_ANSI_C)
    static let defaultHotKeyModifiers = UInt32(controlKey | optionKey)
    static let defaultHotKeyDisplay = "⌃⌥C"

    private let d = UserDefaults.standard
    private enum Keys {
        static let terminal = "CFL.terminalBundleId"
        static let command = "CFL.launchCommand"
        static let featured = "CFL.featuredFolders"
        static let shown = "CFL.shownFoldersByRoot"
        static let projectFolders = "CFL.projectFolders"
        static let hkCode = "CFL.hotKeyCode"
        static let hkMods = "CFL.hotKeyModifiers"
        static let hkDisplay = "CFL.hotKeyDisplay"
    }

    init() {
        let store = UserDefaults.standard
        terminalBundleId = store.string(forKey: Keys.terminal) ?? "com.apple.Terminal"
        launchCommand = store.string(forKey: Keys.command) ?? "claude"
        featuredFolderNames = store.stringArray(forKey: Keys.featured) ?? ["PROJECTS", "OTHER STUFF"]
        shownFoldersByRoot = (store.dictionary(forKey: Keys.shown) as? [String: [String]]) ?? [:]
        projectFolders = store.stringArray(forKey: Keys.projectFolders)
            ?? ["Repositories", "Data", "Scripts", "Docs", "Reference"]
        hotKeyCode = store.object(forKey: Keys.hkCode) != nil
            ? UInt32(store.integer(forKey: Keys.hkCode)) : Preferences.defaultHotKeyCode
        hotKeyModifiers = store.object(forKey: Keys.hkMods) != nil
            ? UInt32(store.integer(forKey: Keys.hkMods)) : Preferences.defaultHotKeyModifiers
        hotKeyDisplay = store.string(forKey: Keys.hkDisplay) ?? Preferences.defaultHotKeyDisplay
    }

    /// Updates the hotkey and notifies the AppDelegate to re-register it.
    func setHotKey(code: UInt32, modifiers: UInt32, display: String) {
        hotKeyCode = code
        hotKeyModifiers = modifiers
        hotKeyDisplay = display
        d.set(Int(code), forKey: Keys.hkCode)
        d.set(Int(modifiers), forKey: Keys.hkMods)
        d.set(display, forKey: Keys.hkDisplay)
        NotificationCenter.default.post(name: .cflHotKeyChanged, object: nil)
    }

    func resetHotKey() {
        setHotKey(code: Preferences.defaultHotKeyCode,
                  modifiers: Preferences.defaultHotKeyModifiers,
                  display: Preferences.defaultHotKeyDisplay)
    }

    /// The subfolder names chosen to show at `root`, or nil if it's never been set up
    /// (in which case every folder shows).
    func shownFolders(forRoot root: URL) -> [String]? { shownFoldersByRoot[root.path] }

    /// Saves the chosen visible-folder names for `root`. An empty selection means
    /// "show everything", so it clears the entry rather than hiding all folders.
    func setShownFolders(_ names: [String], forRoot root: URL) {
        shownFoldersByRoot[root.path] = names.isEmpty ? nil : names
    }
}

// MARK: - Terminal apps

/// A terminal the launcher can open folders in. `runsCommand` is false for terminals we can
/// only open at a directory (Warp), so the UI can warn that the launch command won't run.
struct TerminalOption: Identifiable {
    let bundleId: String
    let name: String
    let strategy: Strategy
    var runsCommand: Bool = true
    var id: String { bundleId }

    /// How to drive this terminal. AppleScript for the scriptable ones; `open --args` for the
    /// CLI-launchable ones (each with its own way of receiving the program to run); Warp is
    /// folder-only.
    enum Strategy {
        case terminalApp
        case iterm
        /// Builds the argv passed after `open -na -b <id> --args`, given the login shell path
        /// and the inner shell command string.
        case openArgs((_ shell: String, _ inner: String) -> [String])
        case warp
    }
}

enum Terminals {
    static let all: [TerminalOption] = [
        TerminalOption(bundleId: "com.apple.Terminal", name: "Terminal", strategy: .terminalApp),
        TerminalOption(bundleId: "com.googlecode.iterm2", name: "iTerm2", strategy: .iterm),
        TerminalOption(bundleId: "com.mitchellh.ghostty", name: "Ghostty",
                       strategy: .openArgs { shell, inner in ["-e", shell, "-lc", inner] }),
        TerminalOption(bundleId: "net.kovidgoyal.kitty", name: "kitty",
                       strategy: .openArgs { shell, inner in [shell, "-lc", inner] }),
        TerminalOption(bundleId: "com.github.wez.wezterm", name: "WezTerm",
                       strategy: .openArgs { shell, inner in ["start", "--", shell, "-lc", inner] }),
        TerminalOption(bundleId: "org.alacritty", name: "Alacritty",
                       strategy: .openArgs { shell, inner in ["-e", shell, "-lc", inner] }),
        TerminalOption(bundleId: "dev.warp.Warp-Stable", name: "Warp", strategy: .warp, runsCommand: false),
    ]

    static func byId(_ id: String) -> TerminalOption? { all.first { $0.bundleId == id } }

    /// Installed terminals, always including Terminal.app (present on every Mac).
    static var installed: [TerminalOption] {
        all.filter { $0.bundleId == "com.apple.Terminal"
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }
}

/// Opens a folder in the user's chosen terminal, optionally running a command after cd-ing in.
/// Returns nil on success or a human-readable error.
enum TerminalLauncher {
    static func launch(folder: URL, command: String?, terminalBundleId: String) -> String? {
        let terminal = Terminals.byId(terminalBundleId)
            ?? Terminals.byId("com.apple.Terminal")!
        switch terminal.strategy {
        case .terminalApp: return launchAppleScript(folder, command, flavor: .terminal)
        case .iterm:       return launchAppleScript(folder, command, flavor: .iterm)
        case .openArgs(let build): return launchViaOpen(terminal, folder, command, build)
        case .warp:        return launchWarp(folder)
        }
    }

    private enum Flavor { case terminal, iterm }

    private static func launchAppleScript(_ folder: URL, _ command: String?, flavor: Flavor) -> String? {
        let cd = "cd \(shellQuote(folder.path))"
        let full = command.map { "\(cd) && \($0)" } ?? cd
        let escaped = appleEscape(full)
        let script: String
        switch flavor {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        }
        return runAppleScript(script)
    }

    private static func launchViaOpen(_ term: TerminalOption, _ folder: URL, _ command: String?,
                                      _ build: (String, String) -> [String]) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cd = "cd \(shellQuote(folder.path))"
        // After the command exits, exec an interactive login shell so the window stays open,
        // matching how Terminal.app leaves you at a prompt.
        let stay = "exec \(shellQuote(shell)) -il"
        let inner = command.map { "\(cd) && \($0); \(stay)" } ?? "\(cd); \(stay)"
        // `-n` new instance, `-b` selects the app by bundle id, `--args` forwards the rest.
        var args = ["-n", "-b", term.bundleId, "--args"]
        args += build(shell, inner)
        return runOpen(args, appName: term.name)
    }

    private static func launchWarp(_ folder: URL) -> String? {
        // Warp has no reliable "run a command" CLI, so we just open it at the folder.
        return runOpen(["-a", "Warp", folder.path], appName: "Warp")
    }

    // MARK: helpers

    /// Single-quotes a string for safe interpolation into a shell command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for embedding in an AppleScript double-quoted literal.
    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return "Could not build the launch script." }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            return "Failed to launch terminal: \(message ?? "\(errorInfo)")"
        }
        return nil
    }

    private static func runOpen(_ args: [String], appName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        do {
            try process.run()
        } catch {
            return "Failed to launch \(appName): \(error.localizedDescription)"
        }
        return nil
    }
}

// MARK: - Fuzzy matching

/// Case-insensitive subsequence matcher used by the search/filter. Returns a relevance score
/// (higher is better) or nil when the query isn't a subsequence of the candidate. Rewards
/// consecutive runs, word-boundary hits (after `/ - _ space`), and shorter names.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard q.count <= t.count else { return nil }

        var qi = 0
        var total = 0
        var run = 0
        var prevMatch = -2
        for (ti, ch) in t.enumerated() {
            guard qi < q.count, ch == q[qi] else { continue }
            var bonus = 1
            if prevMatch == ti - 1 { run += 1; bonus += run * 2 } else { run = 0 }
            let boundary = ti == 0 || "-_/ .".contains(t[ti - 1])
            if boundary { bonus += 3 }
            total += bonus
            prevMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        total += max(0, 10 - t.count / 4)   // slight preference for shorter names
        return total
    }
}

// MARK: - Hotkey helpers

enum HotKeyUtil {
    /// Converts NSEvent modifier flags to the Carbon modifier mask RegisterEventHotKey wants.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// A readable name for the non-modifier key of an event, or "" if it's a bare modifier.
    static func keyName(_ event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, let c = chars.first,
           c.isLetter || c.isNumber || "`-=[]\\;',./".contains(c) {
            return String(c).uppercased()
        }
        return specialKeys[Int(event.keyCode)] ?? ""
    }

    private static let specialKeys: [Int: String] = [
        Int(kVK_Space): "Space", Int(kVK_Return): "↩", Int(kVK_Tab): "⇥", Int(kVK_Escape): "⎋",
        Int(kVK_LeftArrow): "←", Int(kVK_RightArrow): "→", Int(kVK_UpArrow): "↑", Int(kVK_DownArrow): "↓",
        Int(kVK_F1): "F1", Int(kVK_F2): "F2", Int(kVK_F3): "F3", Int(kVK_F4): "F4",
        Int(kVK_F5): "F5", Int(kVK_F6): "F6", Int(kVK_F7): "F7", Int(kVK_F8): "F8",
        Int(kVK_F9): "F9", Int(kVK_F10): "F10", Int(kVK_F11): "F11", Int(kVK_F12): "F12",
    ]
}

// MARK: - Recent folders

@MainActor
final class RecentFolders: ObservableObject {
    @Published private(set) var folders: [URL] = []
    private let key = "ClaudeFolderLauncher.recentRoots"
    private let maxCount = 8

    init() {
        load()
    }

    func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        folders = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        UserDefaults.standard.set(paths, forKey: key)
        load()
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        load()
    }
}

// MARK: - Favourites (pinned folders)

@MainActor
final class Favorites: ObservableObject {
    @Published private(set) var paths: [String] = []
    private let key = "ClaudeFolderLauncher.favorites"

    init() {
        paths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ url: URL) -> Bool { paths.contains(url.path) }

    func toggle(_ url: URL) {
        if let i = paths.firstIndex(of: url.path) {
            paths.remove(at: i)
        } else {
            paths.insert(url.path, at: 0)
        }
        UserDefaults.standard.set(paths, forKey: key)
    }

    /// Pinned folders that still exist on disk, in pin order (newest first).
    func urls() -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Launch history (frecency)

@MainActor
final class LaunchHistory: ObservableObject {
    /// Paths in most-recently-launched order (deduped).
    @Published private(set) var order: [String] = []
    private var counts: [String: Int] = [:]
    private let orderKey = "ClaudeFolderLauncher.launchOrder"
    private let countKey = "ClaudeFolderLauncher.launchCounts"
    private let maxEntries = 40

    init() {
        order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        counts = (UserDefaults.standard.dictionary(forKey: countKey) as? [String: Int]) ?? [:]
    }

    func record(_ url: URL) {
        let p = url.path
        order.removeAll { $0 == p }
        order.insert(p, at: 0)
        if order.count > maxEntries { order = Array(order.prefix(maxEntries)) }
        counts[p, default: 0] += 1
        UserDefaults.standard.set(order, forKey: orderKey)
        UserDefaults.standard.set(counts, forKey: countKey)
    }

    /// Frecency-ranked launched folders: recent ones first, boosted by how often
    /// they're opened. Only returns folders that still exist.
    func ranked(limit: Int) -> [URL] {
        let existing = order.enumerated().filter { FileManager.default.fileExists(atPath: $0.element) }
        let sorted = existing.sorted { score($0.element, rank: $0.offset) > score($1.element, rank: $1.offset) }
        return sorted.prefix(limit).map { URL(fileURLWithPath: $0.element) }
    }

    private func score(_ path: String, rank: Int) -> Double {
        let recency = 1.0 / Double(rank + 1)          // 1, 0.5, 0.33, …
        let frequency = log2(Double(counts[path] ?? 1) + 1)
        return recency * 2.0 + frequency
    }
}

// MARK: - Transient UI state (filter text + keyboard selection)

/// How the selected row responds to Return / →. `folder` = a normal row (open in terminal /
/// browse in). `featured` = a container shortcut (browse in on both). `jump` = a pinned, recent,
/// or search-result row that lives elsewhere in the tree (open / jump to it).
enum NavKind { case folder, featured, jump }

struct NavItem {
    let url: URL
    let kind: NavKind
}

@MainActor
final class UIState: ObservableObject {
    @Published var filterText = ""
    @Published var selection = 0
    /// The selection highlight only shows once the user starts arrow-key navigation —
    /// otherwise a row would look selected the moment the popover opens.
    @Published var selectionActive = false
    /// Everything reachable by keyboard, in display order (featured, pinned, recent, then the
    /// folder rows). Kept in sync by ContentView so the global key monitor can act on it.
    var navItems: [NavItem] = []
    /// Hidden side-scroller easter egg, shared so the key monitor can feed it jumps.
    let runner = RunnerGame()
}

// MARK: - Launch at login

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Launch at login update failed: \(error)")
        }
        refresh()
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var uiState: UIState
    @EnvironmentObject var favorites: Favorites
    @EnvironmentObject var history: LaunchHistory
    @EnvironmentObject var prefs: Preferences
    @StateObject private var launchAtLogin = LaunchAtLogin()

    private var filterText: String { uiState.filterText }

    /// Subfolders visible at the current level. At the root, honours the per-root
    /// "shown folders" chosen in setup — hidden folders stay reachable via search.
    /// Deeper levels always show everything. Falls back to showing all if the saved
    /// selection has gone stale (nothing matches).
    private var visibleSubfolders: [URL] {
        guard !model.canGoBack, let root = model.rootURL,
              let shown = prefs.shownFolders(forRoot: root), !shown.isEmpty
        else { return model.subfolders }
        let allow = Set(shown)
        let filtered = model.subfolders.filter { allow.contains($0.lastPathComponent) }
        return filtered.isEmpty ? model.subfolders : filtered
    }

    private var filteredSubfolders: [URL] {
        guard !filterText.isEmpty else { return visibleSubfolders }
        return visibleSubfolders
            .compactMap { url in Fuzzy.score(filterText, url.lastPathComponent).map { (url, $0) } }
            .sorted {
                $0.1 != $1.1
                    ? $0.1 > $1.1
                    : $0.0.lastPathComponent.localizedCaseInsensitiveCompare($1.0.lastPathComponent) == .orderedAscending
            }
            .map { $0.0 }
    }

    /// The configured featured folders, in order, that are visible at the current level.
    private var specialFolders: [URL] {
        prefs.featuredFolderNames.compactMap { name in
            visibleSubfolders.first { $0.lastPathComponent == name }
        }
    }

    /// Show the featured shortcut rows only at the root, when not filtering, and when at least
    /// one exists.
    private var showsHero: Bool {
        !model.canGoBack && filterText.isEmpty && !specialFolders.isEmpty
    }

    /// Folders shown in the normal list — the featured ones are pulled out into their own rows.
    private var listedSubfolders: [URL] {
        guard showsHero else { return filteredSubfolders }
        let special = Set(prefs.featuredFolderNames)
        return filteredSubfolders.filter { !special.contains($0.lastPathComponent) }
    }

    private var gitFolders: [URL] { listedSubfolders.filter { $0.gitBranch != nil } }
    private var plainFolders: [URL] { listedSubfolders.filter { $0.gitBranch == nil } }
    private var showsSectionHeaders: Bool { !gitFolders.isEmpty && !plainFolders.isEmpty }

    // MARK: Project view (a folder holding the standard template structure)

    /// True when the current folder holds the project template: it has a `Repositories`
    /// subfolder, or matches at least two of the configured template folders.
    private var currentFolderIsProject: Bool {
        let names = Set(model.subfolders.map { $0.lastPathComponent })
        if names.contains("Repositories") { return true }
        return prefs.projectFolders.filter { names.contains($0) }.count >= 2
    }

    /// Show the tailored project view once browsed into a project (and not filtering).
    private var isProjectView: Bool {
        model.canGoBack && filterText.isEmpty && currentFolderIsProject
    }

    /// The Scripts folder gets a runnable-file view (files, not just subfolders).
    private var isScriptsFolder: Bool {
        model.canGoBack && model.currentURL?.lastPathComponent == "Scripts"
    }

    private func matchesFilter(_ url: URL) -> Bool {
        filterText.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(filterText)
    }
    private var scriptSubfolders: [URL] { model.subfolders.filter { matchesFilter($0) } }
    private var scriptListFiles: [URL] { model.files.filter { matchesFilter($0) } }

    /// Project subfolders in a stable order: the template folders that exist (in the
    /// configured order) first, then any other subfolders alphabetically.
    private var orderedProjectFolders: [URL] {
        let order = prefs.projectFolders
        func rank(_ name: String) -> Int { order.firstIndex(of: name) ?? order.count }
        return model.subfolders.sorted {
            let ra = rank($0.lastPathComponent), rb = rank($1.lastPathComponent)
            if ra != rb { return ra < rb }
            return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func projectFolderIcon(for name: String) -> String {
        switch name {
        case "Repositories": return "shippingbox.fill"
        case "Data":         return "cylinder.fill"
        case "Scripts":      return "terminal.fill"
        case "Docs":         return "doc.text.fill"
        case "Reference":    return "book.closed.fill"
        default:             return featuredIcon(for: name)
        }
    }

    /// Number of repositories (subdirectories) inside the project's Repositories folder.
    private func repoCount(in project: URL) -> Int {
        let repos = project.appendingPathComponent("Repositories")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: repos, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
    }

    private func repoCountLabel(_ project: URL) -> String {
        let n = repoCount(in: project)
        return n == 1 ? "1 repo" : "\(n) repos"
    }

    /// Tailored view for a project folder: a header + quick actions, then the template
    /// folders as labeled rows (Repositories first, with its repo count).
    @ViewBuilder
    private var projectContent: some View {
        if let project = model.currentURL {
            VStack(spacing: 0) {
                projectHeader(project)
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(orderedProjectFolders.enumerated()), id: \.element) { i, folder in
                        FeaturedRow(
                            url: folder,
                            icon: projectFolderIcon(for: folder.lastPathComponent),
                            isSelected: isSelected(i),
                            subtitleOverride: folder.lastPathComponent == "Repositories" ? repoCountLabel(project) : nil
                        ) {
                            model.navigateInto(folder)
                            uiState.filterText = ""
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func projectHeader(_ project: URL) -> some View {
        let fm = FileManager.default
        let claude = project.appendingPathComponent("CLAUDE.md")
        let readme = project.appendingPathComponent("README.md")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(project.lastPathComponent.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                    .lineLimit(1)
                Text("· \(repoCountLabel(project))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                if fm.fileExists(atPath: claude.path) {
                    projectPill("CLAUDE.md") { model.openFile(claude) }
                }
                if fm.fileExists(atPath: readme.path) {
                    projectPill("README") { model.openFile(readme) }
                }
                projectPill("Terminal") { model.openInTerminal(project) }
                projectPill("Add repo") { model.promptAddRepositories(to: project) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The Scripts folder view: subfolders (browse in) plus runnable script files. Clicking a
    /// file opens a menu (Run / Open in Terminal / Edit / Reveal).
    @ViewBuilder
    private var scriptsContent: some View {
        let subs = scriptSubfolders
        let fs = scriptListFiles
        if subs.isEmpty && fs.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: filterText.isEmpty ? "terminal" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(filterText.isEmpty ? "No scripts here yet" : "No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(subs.enumerated()), id: \.element) { i, folder in
                        FolderRow(url: folder, isSelected: isSelected(i))
                    }
                    ForEach(fs, id: \.self) { file in
                        ScriptRow(
                            file: file,
                            isScript: model.isScript(file),
                            onRun:      { model.runScript(file) },
                            onTerminal: { model.openInTerminal(file.deletingLastPathComponent(), runClaude: false) },
                            onEdit:     { model.openFile(file) },
                            onReveal:   { model.revealInFinder(file) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .frame(height: min(max(CGFloat(subs.count + fs.count) * rowHeight + 8, rowHeight + 8), listMaxHeight))
        }
    }

    private func projectPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// At the root, the filter searches the whole tree instead of just the top level.
    private var isRootSearch: Bool { !model.canGoBack && !filterText.isEmpty }

    private var searchResults: [SearchEntry] {
        guard isRootSearch else { return [] }
        let query = filterText
        return model.searchIndex
            .compactMap { entry in Fuzzy.score(query, entry.url.lastPathComponent).map { (entry, $0) } }
            .sorted {
                // Best fuzzy score first, then shallower paths, then alphabetical.
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                let ad = $0.0.relativePath.count, bd = $1.0.relativePath.count
                if ad != bd { return ad < bd }
                return $0.0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.0.url.lastPathComponent) == .orderedAscending
            }
            .map { $0.0 }
    }

    // MARK: Pinned & recent (root only)

    private var showsShortcuts: Bool { !model.canGoBack && filterText.isEmpty }
    private var pinnedEntries: [SearchEntry] { showsShortcuts ? model.pinnedEntries : [] }
    private var recentEntries: [SearchEntry] { showsShortcuts ? model.recentEntries() : [] }

    // MARK: Keyboard navigation

    /// Everything the arrow keys walk through, in the exact order it's displayed:
    /// featured shortcuts, then Pinned, then Recent, then the git/plain folder rows.
    /// (At the root deep-search this is just the search results.)
    private var navItems: [NavItem] {
        if isRootSearch {
            return searchResults.map { NavItem(url: $0.url, kind: .jump) }
        }
        if isProjectView {
            // Labeled folder rows are containers — browse in (like featured rows).
            return orderedProjectFolders.map { NavItem(url: $0, kind: .featured) }
        }
        if isScriptsFolder {
            // Only subfolders are keyboard-navigable; script files use the click menu.
            return scriptSubfolders.map { NavItem(url: $0, kind: .folder) }
        }
        var items: [NavItem] = []
        if showsHero {
            items += specialFolders.map { NavItem(url: $0, kind: .featured) }
        }
        if showsShortcuts {
            items += pinnedEntries.map { NavItem(url: $0.url, kind: .jump) }
            items += recentEntries.map { NavItem(url: $0.url, kind: .jump) }
        }
        items += gitFolders.map { NavItem(url: $0, kind: .folder) }
        items += plainFolders.map { NavItem(url: $0, kind: .folder) }
        return items
    }

    // Where each section starts within navItems, so a row can tell if it's the selected one.
    private var featuredBase: Int { 0 }
    private var pinnedBase: Int { showsHero ? specialFolders.count : 0 }
    private var recentBase: Int { pinnedBase + (showsShortcuts ? pinnedEntries.count : 0) }
    private var gitBase: Int { recentBase + (showsShortcuts ? recentEntries.count : 0) }
    private var plainBase: Int { gitBase + gitFolders.count }

    private func isSelected(_ index: Int) -> Bool {
        uiState.selectionActive && uiState.selection == index
    }

    private func resetSelection() {
        uiState.selection = 0
        uiState.selectionActive = false
    }

    /// Publishes the current nav list to UIState so the global key monitor can act on it.
    private func syncNav() {
        uiState.navItems = navItems
        if uiState.selection >= navItems.count {
            uiState.selection = max(0, navItems.count - 1)
        }
    }

    /// A fitting SF Symbol for a featured folder, guessed from keywords in its name so any
    /// custom featured folder still gets a sensible glyph (falls back to a plain folder).
    /// The row's subtitle is computed live from the folder's contents, so nothing here is
    /// tied to specific folder names.
    private func featuredIcon(for name: String) -> String {
        let n = name.lowercased()
        switch true {
        case n.contains("project"):                                     return "shippingbox.fill"
        case n.contains("client"), n.contains("customer"):              return "person.2.fill"
        case n.contains("tool"), n.contains("infra"), n.contains("other"),
             n.contains("misc"), n.contains("util"):                    return "wrench.and.screwdriver.fill"
        case n.contains("archive"), n.contains("old"), n.contains("legacy"): return "archivebox.fill"
        case n.contains("doc"), n.contains("note"):                     return "doc.text.fill"
        case n.contains("lab"), n.contains("experiment"), n.contains("sandbox"),
             n.contains("r&d"), n.contains("rnd"):                      return "flask.fill"
        case n.contains("app"), n.contains("product"), n.contains("build"): return "square.grid.2x2.fill"
        default:                                                        return "folder.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(headerChrome)
            Divider()
            if let setupRoot = model.pendingSetupRoot {
                SetupView(root: setupRoot).id(setupRoot)
            } else {
                if model.currentURL != nil && !model.subfolders.isEmpty {
                    searchField
                }
                content
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear(perform: syncNav)
        .onChange(of: uiState.filterText) { _ in resetSelection(); syncNav() }
        .onChange(of: model.subfolders) { _ in syncNav() }
        .onChange(of: model.currentURL) { _ in resetSelection(); syncNav() }
        .onChange(of: model.searchIndex) { _ in syncNav() }
    }

    /// A faint grey gradient behind the header to tie the window to the card look.
    private var headerChrome: some View {
        LinearGradient(
            colors: [Color.secondary.opacity(0.12), Color.secondary.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // Approx row height (matches FolderRow padding) — used to size the list to its content.
    private let rowHeight: CGFloat = 38
    private let sectionHeaderHeight: CGFloat = 24
    private let listMaxHeight: CGFloat = 460

    // Featured rows and search-result-style rows (pinned/recent) are two lines, so a touch taller.
    private let featuredRowHeight: CGFloat = 46
    private let entryRowHeight: CGFloat = 44

    /// Sizes the root list to its content: featured rows + pinned/recent + folders, plus headers.
    private var rootListHeight: CGFloat {
        var headers = 0
        if !pinnedEntries.isEmpty { headers += 1 }
        if !recentEntries.isEmpty { headers += 1 }
        if showsSectionHeaders { headers += 2 }
        let hasFollowing = !pinnedEntries.isEmpty || !recentEntries.isEmpty || !listedSubfolders.isEmpty
        // The featured rows carry a divider (≈15pt) only when other content follows them.
        let featuredRows = showsHero
            ? CGFloat(specialFolders.count) * featuredRowHeight + (hasFollowing ? 15 : 0)
            : 0
        let entryRows = CGFloat(pinnedEntries.count + recentEntries.count) * entryRowHeight
        let folderRows = CGFloat(listedSubfolders.count) * rowHeight
        let computed = featuredRows + entryRows + folderRows + CGFloat(headers) * sectionHeaderHeight + 8
        return min(max(computed, rowHeight + 8), listMaxHeight)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.canGoBack {
                Button(action: model.navigateBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")
            }

            Menu {
                if !model.recents.folders.isEmpty {
                    Section("Recent") {
                        ForEach(model.recents.folders, id: \.self) { folder in
                            Button {
                                model.switchTo(folder)
                                uiState.filterText = ""
                            } label: {
                                Label(folder.lastPathComponent, systemImage: "folder")
                            }
                        }
                    }
                    Divider()
                    Button("Clear Recent Folders") {
                        model.recents.clear()
                    }
                    Divider()
                }
                Button("Choose Other Folder…") {
                    model.pickRoot()
                    uiState.filterText = ""
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(model.currentURL?.lastPathComponent ?? "Flaunch")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.currentURL?.path ?? "")

            Spacer(minLength: 4)

            Menu {
                Button("New Project…", action: model.promptNewProject)
                Button("Clone Repository…", action: model.promptCloneRepo)
            } label: {
                if model.isCloning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.currentURL == nil || model.isCloning)
            .help("New Project or Clone Repository…")

            Menu {
                Button("Open in Terminal with Claude") {
                    model.currentURL.map { model.openInTerminal($0) }
                }
                Button("Open in Terminal") {
                    model.currentURL.map { model.openInTerminal($0, runClaude: false) }
                }
            } label: {
                Image(systemName: "terminal")
            } primaryAction: {
                model.currentURL.map { model.openInTerminal($0) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.currentURL == nil)
            .help("Open Here (click for Claude, ▸ for a plain terminal)")

            Button(action: model.loadSubfolders) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentURL == nil)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .semibold))
            TextField(model.canGoBack ? "Filter" : "Search all folders…", text: $uiState.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !filterText.isEmpty {
                Button(action: { uiState.filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The magic word that summons the hidden side-scroller.
    private var showsGame: Bool {
        uiState.filterText.trimmingCharacters(in: .whitespaces).lowercased() == "xyzzy"
    }

    @ViewBuilder
    private var content: some View {
        if showsGame {
            GameView(game: uiState.runner)
        } else if model.currentURL == nil {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Pick a folder to get started")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Button("Choose Folder…", action: model.pickRoot)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        } else if let error = model.errorMessage {
            ScrollView {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        } else if isScriptsFolder {
            scriptsContent
        } else if model.subfolders.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("This folder is empty")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                if !model.canGoBack {
                    Button("Create PROJECTS & OTHER STUFF", action: model.createSpecialFolders)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
        } else if isRootSearch {
            rootSearch
        } else if isProjectView {
            projectContent
        } else if filteredSubfolders.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        } else {
            VStack(spacing: 0) {
                if hasScrollContent {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if showsHero {
                                ForEach(Array(specialFolders.enumerated()), id: \.element) { i, folder in
                                    FeaturedRow(url: folder,
                                                icon: featuredIcon(for: folder.lastPathComponent),
                                                isSelected: isSelected(featuredBase + i)) {
                                        model.navigateInto(folder)
                                        uiState.filterText = ""
                                    }
                                }
                                if !pinnedEntries.isEmpty || !recentEntries.isEmpty || !listedSubfolders.isEmpty {
                                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                                }
                            }
                            if !pinnedEntries.isEmpty {
                                sectionHeader("Pinned")
                                ForEach(Array(pinnedEntries.enumerated()), id: \.element) { i, entry in
                                    SearchResultRow(entry: entry, isSelected: isSelected(pinnedBase + i), showStatus: true) {}
                                }
                            }
                            if !recentEntries.isEmpty {
                                sectionHeader("Recent")
                                ForEach(Array(recentEntries.enumerated()), id: \.element) { i, entry in
                                    SearchResultRow(entry: entry, isSelected: isSelected(recentBase + i), showStatus: true) {}
                                }
                            }
                            if showsSectionHeaders {
                                sectionHeader("Git Repositories")
                            }
                            ForEach(Array(gitFolders.enumerated()), id: \.element) { i, folder in
                                FolderRow(url: folder, isSelected: isSelected(gitBase + i))
                            }
                            if showsSectionHeaders {
                                sectionHeader("Folders")
                            }
                            ForEach(Array(plainFolders.enumerated()), id: \.element) { i, folder in
                                FolderRow(url: folder, isSelected: isSelected(plainBase + i))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: rootListHeight)
                }
            }
        }
    }

    private var hasScrollContent: Bool {
        (showsHero && !specialFolders.isEmpty)
            || !pinnedEntries.isEmpty || !recentEntries.isEmpty || !listedSubfolders.isEmpty
    }

    @ViewBuilder
    private var rootSearch: some View {
        if searchResults.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element) { i, entry in
                        SearchResultRow(entry: entry, isSelected: isSelected(i)) {
                            uiState.filterText = ""
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(max(CGFloat(searchResults.count) * rowHeight + 8, rowHeight + 8), listMaxHeight))
        }
    }

    private var footer: some View {
        HStack {
            Text(footerCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Choose Folders to Show…") {
                    // Return to the root first so setup lists the root's folders (not the
                    // subfolder currently browsed into) and saves the selection under the root.
                    if let root = model.rootURL { model.setRoot(root, showSetup: true) }
                }
                .disabled(model.rootURL == nil)
                Button("Settings…") {
                    NotificationCenter.default.post(name: .cflOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Divider()
                Button("Quit Flaunch") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { launchAtLogin.refresh() }
    }

    private var footerCountText: String {
        if showsGame || model.pendingSetupRoot != nil { return "" }
        if model.subfolders.isEmpty { return "" }
        if isRootSearch {
            let n = searchResults.count
            return n == 1 ? "1 match" : "\(n) matches"
        }
        if filterText.isEmpty {
            return "\(visibleSubfolders.count) folders"
        }
        return "\(filteredSubfolders.count) of \(visibleSubfolders.count)"
    }
}

/// First-run setup shown when the user picks or switches a root. Suggests creating the
/// featured "starter" folders, then lets them tick exactly which subfolders appear at this
/// root. Un-ticked folders are hidden from the root but stay reachable via search.
struct SetupView: View {
    let root: URL
    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var prefs: Preferences
    @State private var selected: Set<String> = []
    @State private var initialized = false

    private var allNames: [String] { model.subfolders.map { $0.lastPathComponent } }

    /// Featured names that don't yet exist here, so we can offer to create them.
    private var missingFeatured: [String] {
        let have = Set(allNames)
        return prefs.featuredFolderNames.filter { !$0.isEmpty && !have.contains($0) }
    }

    private var listHeight: CGFloat {
        min(max(CGFloat(model.subfolders.count) * 30 + 8, 60), 244)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("Set up “\(root.lastPathComponent)”")
                    .font(.system(size: 14, weight: .semibold))
                Text("Pick which folders show up here. Hidden ones stay searchable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if !missingFeatured.isEmpty {
                Button(action: createFeatured) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Create \(missingFeatured.joined(separator: " & "))")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Recommended starter folders")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()

            if model.subfolders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No folders here yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                HStack {
                    Text(selectionSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(selected.count == allNames.count ? "Clear" : "All") {
                        selected = selected.count == allNames.count ? [] : Set(allNames)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.subfolders, id: \.self) { url in
                            let name = url.lastPathComponent
                            Toggle(isOn: Binding(
                                get: { selected.contains(name) },
                                set: { on in
                                    if on { selected.insert(name) } else { selected.remove(name) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 12))
                                    Text(name)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .frame(height: listHeight)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Show All") {
                    // Clear the entry (not a snapshot) so folders added here later stay visible.
                    prefs.setShownFolders([], forRoot: root)
                    model.pendingSetupRoot = nil
                }
                .controlSize(.small)
                Spacer()
                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Reflect a previous selection for this root; otherwise start with everything
            // shown so nothing is hidden by accident — the user unticks what they don't want.
            selected = Set(prefs.shownFolders(forRoot: root) ?? allNames)
        }
    }

    private var selectionSummary: String {
        let n = selected.count
        return n == 1 ? "1 folder selected" : "\(n) folders selected"
    }

    private func createFeatured() {
        model.createSpecialFolders()          // creates missing featured folders + reloads
        selected.formUnion(prefs.featuredFolderNames)
    }

    private func finish() {
        prefs.setShownFolders(Array(selected), forRoot: root)
        model.pendingSetupRoot = nil
    }
}

/// A featured top-level folder shown as a flat, emphasised row at the root. Clicking it browses
/// in (these are containers, not repos). The subtitle is derived from the folder's contents
/// (its subfolder count), so it stays accurate for any featured folder regardless of name.
struct FeaturedRow: View {
    let url: URL
    let icon: String
    var isSelected: Bool = false
    /// When set, used verbatim as the subtitle instead of the async folder count
    /// (e.g. "6 repos" for a project's Repositories folder).
    var subtitleOverride: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var subtitle = " "   // a space reserves the second line until the count loads

    private var highlighted: Bool { hovering || isSelected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(highlighted ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? (isSelected ? Palette.selection : Palette.hover) : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .task(id: url) {
            if let subtitleOverride {
                subtitle = subtitleOverride
                return
            }
            let target = url
            let count = await Task.detached(priority: .utility) {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: target,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                return contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.count
            }.value
            subtitle = count == 1 ? "1 folder" : "\(count) folders"
        }
    }
}

/// A file row in the Scripts view. Clicking opens a menu; for scripts that's Run / Open in
/// Terminal / Edit / Reveal, for other files just Open / Reveal.
struct ScriptRow: View {
    let file: URL
    let isScript: Bool
    let onRun: () -> Void
    let onTerminal: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    @State private var hovering = false

    private var tileColors: [Color] { Palette.tile }

    var body: some View {
        Menu {
            if isScript {
                Button("Run", action: onRun)
                Button("Open in Terminal", action: onTerminal)
                Button("Edit", action: onEdit)
            } else {
                Button("Open", action: onEdit)
            }
            Button("Reveal in Finder", action: onReveal)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: tileColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: isScript ? "terminal" : "doc.text")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: (tileColors.last ?? .black).opacity(0.35), radius: 2, y: 1)
                Text(file.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: isScript ? "play.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0.55)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
    }
}

/// The branch pill with colour-coded git status: dirty (orange), ahead (blue),
/// behind (violet), or clean & synced (green). The branch name itself stays neutral.
struct BranchBadge: View {
    let branch: String
    let status: Git.Status

    private var accent: Color {
        if status.dirty { return Palette.dirty }
        if status.behind > 0 { return Palette.behind }
        if status.ahead > 0 { return Palette.ahead }
        if status.hasUpstream { return Palette.clean }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(branch)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if status.ahead > 0 { counter("arrow.up", status.ahead, Palette.ahead) }
            if status.behind > 0 { counter("arrow.down", status.behind, Palette.behind) }
            if status.dirty {
                Circle().fill(Palette.dirty).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
        .overlay(Capsule(style: .continuous).stroke(accent.opacity(0.28), lineWidth: 0.5))
        .help(helpText)
    }

    private func counter(_ symbol: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("\(n)").font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
    }

    private var helpText: String {
        var parts: [String] = []
        if status.ahead > 0 { parts.append("\(status.ahead) ahead") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        if status.dirty { parts.append("uncommitted changes") }
        if parts.isEmpty { parts.append(status.hasUpstream ? "up to date" : "no upstream") }
        return parts.joined(separator: ", ")
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var favorites: Favorites
    @State private var hovering = false
    @State private var status = Git.Status()
    let url: URL
    var isSelected: Bool = false

    private var branch: String? { url.gitBranch }
    private var isGit: Bool { branch != nil }
    private var isPinned: Bool { favorites.contains(url) }
    private var highlighted: Bool { hovering || isSelected }

    private var tileColors: [Color] { Palette.tile }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: { model.openInTerminal(url) }) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: tileColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: isGit ? "arrow.triangle.branch" : "folder.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .shadow(color: (tileColors.last ?? .black).opacity(0.35), radius: 2, y: 1)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let branch = branch {
                        BranchBadge(branch: branch, status: status)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { model.openInTerminal(url, runClaude: false) }) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(highlighted ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(highlighted ? Color.secondary.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(highlighted ? 1 : 0)
            .help("Open in plain Terminal (no \(model.prefs.launchCommand))")

            PinButton(isPinned: isPinned, visible: highlighted || isPinned) {
                model.togglePin(url)
            }

            Button(action: { model.navigateInto(url) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(highlighted ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(highlighted ? Color.secondary.opacity(0.15) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Browse into \(url.lastPathComponent)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? (isSelected ? Palette.selection : Palette.hover) : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .task(id: url) {
            guard branch != nil else { return }
            status = await Task.detached(priority: .utility) {
                Git.status(at: url)
            }.value
        }
        .contextMenu {
            Button("Open in Terminal with Claude") {
                model.openInTerminal(url)
            }
            Button("Open in Terminal") {
                model.openInTerminal(url, runClaude: false)
            }
            Button("Browse Into Folder") {
                model.navigateInto(url)
            }
            Divider()
            Button(isPinned ? "Unpin" : "Pin to Top") {
                model.togglePin(url)
            }
            let editors = Editors.available
            if !editors.isEmpty {
                Divider()
                ForEach(editors, id: \.bundleId) { editor in
                    Button("Open in \(editor.name)") {
                        model.openInEditor(url, bundleId: editor.bundleId)
                    }
                }
            }
            Divider()
            Button("Open in Finder") {
                model.openInFinder(url)
            }
            Button("Copy Path") {
                model.copyPath(url)
            }
        }
    }
}

/// Small star toggle used by folder rows to pin/unpin a folder.
struct PinButton: View {
    let isPinned: Bool
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(isPinned ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .help(isPinned ? "Unpin" : "Pin to Top")
    }
}

/// A row shown in the top-level deep search: like FolderRow, but it displays the
/// folder's relative path for context and jumps straight to it when browsed into.
struct SearchResultRow: View {
    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var favorites: Favorites
    @State private var hovering = false
    @State private var status = Git.Status()
    let entry: SearchEntry
    var isSelected: Bool = false
    /// Whether to compute & show git status. Off for transient deep-search results (which
    /// churn on every keystroke), on for the stable Pinned / Recent rows.
    var showStatus: Bool = false
    /// Called after an action that should dismiss the search (e.g. clearing the filter).
    let onNavigate: () -> Void

    private var url: URL { entry.url }
    private var branch: String? { url.gitBranch }
    private var isGit: Bool { branch != nil }
    private var isPinned: Bool { favorites.contains(url) }
    private var highlighted: Bool { hovering || isSelected }
    private var tileColors: [Color] { Palette.tile }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: { model.openInTerminal(url); onNavigate() }) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: tileColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: isGit ? "arrow.triangle.branch" : "folder.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .shadow(color: (tileColors.last ?? .black).opacity(0.35), radius: 2, y: 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !entry.relativePath.isEmpty {
                            Text(entry.relativePath)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 6)
                    if showStatus, let branch = branch {
                        BranchBadge(branch: branch, status: status)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { model.openInTerminal(url, runClaude: false); onNavigate() }) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(highlighted ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(highlighted ? Color.secondary.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(highlighted ? 1 : 0)
            .help("Open in plain Terminal (no \(model.prefs.launchCommand))")

            PinButton(isPinned: isPinned, visible: highlighted || isPinned) {
                model.togglePin(url)
            }

            Button(action: { model.navigateTo(url); onNavigate() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(highlighted ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(highlighted ? Color.secondary.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Browse into \(url.lastPathComponent)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? (isSelected ? Palette.selection : Palette.hover) : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .task(id: url) {
            guard showStatus, branch != nil else { return }
            let target = url
            status = await Task.detached(priority: .utility) { Git.status(at: target) }.value
        }
        .contextMenu {
            Button("Open in Terminal with Claude") { model.openInTerminal(url); onNavigate() }
            Button("Open in Terminal") { model.openInTerminal(url, runClaude: false); onNavigate() }
            Button("Browse Into Folder") { model.navigateTo(url); onNavigate() }
            Divider()
            Button(isPinned ? "Unpin" : "Pin to Top") { model.togglePin(url) }
            Divider()
            Button("Open in Finder") { model.openInFinder(url) }
            Button("Copy Path") { model.copyPath(url) }
        }
    }
}

// MARK: - Easter egg: a tiny side-scroller

/// A scrolling obstacle — a "bug". Crawlers (`flying == false`) sit on the floor and are hopped
/// over; fliers hover at head height and must be passed *under* by staying grounded. `w`/`h` are
/// in points; `x` is the left edge; `y` is the bottom edge above the ground (0 for crawlers);
/// `kind` picks which little critter symbol is drawn.
struct Obstacle: Identifiable {
    let id = UUID()
    var x: CGFloat
    let y: CGFloat
    let h: CGFloat
    let w: CGFloat
    let kind: Int
    let flying: Bool
    var charger = false     // a fast red bug that rushes the hero
    var golden = false      // a rare shiny bug worth a jackpot when cleared
    var scored = false
    var smashed = false     // plowed through during a coffee dash
    var minGap: CGFloat = 999   // closest vertical clearance while over the hero (for near-misses)
}

/// A floating bonus token. They sometimes come in a short jumpable arc, and a magnet pulls them in.
struct Token: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat          // height above the ground
    var taken = false
}

/// The power-ups: a one-hit shield, a caffeine dash (invincible + fast + smashes bugs), a tortoise
/// that slows the world down, and a magnet that reels in every token on screen.
enum PowerKind: CaseIterable { case shield, coffee, tortoise, magnet }

struct Power: Identifiable {
    let id = UUID()
    var x: CGFloat
    let y: CGFloat
    let kind: PowerKind
    var taken = false
}

/// A short-lived particle. `tint`: 0 grey dust, 1 gold sparkle, 2 red hit-debris.
struct Particle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var life: CGFloat       // 1 → 0
    let size: CGFloat
    let tint: Int
}

/// A slow parallax background prop — a drifting cloud by day, a faint star by night.
struct Decor: Identifiable {
    let id = UUID()
    var x: CGFloat
    let y: CGFloat          // distance from the top of the field
    let scale: CGFloat
    let speed: CGFloat
}

/// A tiny endless runner hidden behind the magic word `xyzzy` in the search box. The hero — a
/// blinking little block with a face — hops crawlers, ducks fliers, double-jumps, grabs tokens
/// and power-ups, builds a combo multiplier, and runs through a rolling day→night sky. State is
/// plain values so the view renders it with ordinary shapes (no Canvas needed).
@MainActor
final class RunnerGame: ObservableObject {
    enum Phase { case ready, running, over }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var heroY: CGFloat = 0
    @Published private(set) var obstacles: [Obstacle] = []
    @Published private(set) var tokens: [Token] = []
    @Published private(set) var powers: [Power] = []
    @Published private(set) var particles: [Particle] = []
    @Published private(set) var decor: [Decor] = []
    @Published private(set) var score = 0
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "CFL.runnerBest")

    // Combo.
    @Published private(set) var combo = 0
    @Published private(set) var multiplier = 1

    // Power-up state.
    @Published private(set) var shieldActive = false
    @Published private(set) var dashTimer = 0
    @Published private(set) var slowTimer = 0
    @Published private(set) var magnetTimer = 0
    @Published private(set) var invulnTimer = 0

    // Character & juice.
    @Published private(set) var stretch: CGFloat = 0
    @Published private(set) var landSquash: CGFloat = 0
    @Published private(set) var blink = false
    @Published private(set) var shake: CGFloat = 0
    @Published private(set) var scorePop: CGFloat = 0
    @Published private(set) var spinAngle: CGFloat = 0
    @Published private(set) var flash: CGFloat = 0
    @Published private(set) var toast: String?
    @Published private(set) var overLine = ""
    @Published private(set) var groundScroll: CGFloat = 0
    @Published private(set) var runPhase: CGFloat = 0
    @Published private(set) var dayPhase: CGFloat = 0
    @Published private(set) var tick = 0

    var dashActive: Bool { dashTimer > 0 }
    var slowActive: Bool { slowTimer > 0 }
    var magnetActive: Bool { magnetTimer > 0 }

    let width: CGFloat = 314
    let height: CGFloat = 186
    var groundY: CGFloat { height - 26 }
    let heroX: CGFloat = 38
    let heroSize: CGFloat = 20
    let dashLength = 240
    let slowLength = 300
    let magnetLength = 300

    private var vy: CGFloat = 0
    private var speed: CGFloat = 3.2
    private var spawn = 44
    private var blinkTimer = 120
    private var toastTimer = 0
    private var speedTier = 0
    private var metFlyer = false
    private var jumps = 0
    private var spinFrames = 0
    private let gravity: CGFloat = 0.9
    private let jumpVelocity: CGFloat = 14.5

    private static let quips = [
        "Squashed.", "Segmentation fault.", "That bug won.", "Stack overflow.",
        "Kernel panic.", "Task failed successfully.", "It compiled, though.",
        "Skill issue.", "Ship it anyway?", "Out of coffee.",
    ]
    private static let cheers = [
        "nice", "smooth", "on a roll", "showing off", "no notes", "unstoppable",
    ]

    /// Show the title card without starting a run, seeding the parallax so it drifts on the menu.
    func enterReady() {
        phase = .ready
        resetRun()
        dayPhase = 0.06
        seedDecor()
    }

    private func start() {
        phase = .running
        resetRun()
        dayPhase = 0.06
        spawn = 30
        if decor.isEmpty { seedDecor() }
    }

    private func resetRun() {
        heroY = 0; vy = 0
        obstacles = []; tokens = []; powers = []; particles = []
        score = 0; combo = 0; multiplier = 1
        shieldActive = false; dashTimer = 0; slowTimer = 0; magnetTimer = 0; invulnTimer = 0
        stretch = 0; landSquash = 0; shake = 0; scorePop = 0; spinAngle = 0; flash = 0
        toast = nil; toastTimer = 0
        speed = 3.2; spawn = 44; speedTier = 0; metFlyer = false
        jumps = 0; spinFrames = 0
    }

    private func seedDecor() {
        let scales: [CGFloat] = [0.7, 1.1, 0.9, 1.3]
        let speeds: [CGFloat] = [0.25, 0.45, 0.35, 0.55]
        var props: [Decor] = []
        for i in 0..<5 {
            let x: CGFloat = CGFloat(i) * (width / 4) + 12
            let y: CGFloat = CGFloat(14 + (i * 27) % 62)
            props.append(Decor(x: x, y: y, scale: scales[i % 4], speed: speeds[i % 4]))
        }
        decor = props
    }

    /// The one input: start, hop (or double-hop in the air), or restart.
    func jump() {
        switch phase {
        case .ready, .over:
            start()
        case .running:
            if heroY <= 0.01 {
                vy = jumpVelocity; jumps = 1
            } else if jumps < 2 {
                vy = jumpVelocity * 0.92; jumps += 1
                spinFrames = 18
                puff(heroX + heroSize / 2, heroY, 6, 0, 2)
            }
        }
    }

    func step() {
        tick &+= 1
        advanceDecor(); tickBlink(); decay(); advanceParticles()
        guard phase == .running else { return }

        let wasAir = heroY > 0.01
        vy -= gravity
        heroY = max(0, heroY + vy)
        if heroY <= 0 { heroY = 0; if wasAir { land() }; vy = 0; jumps = 0 }
        stretch = max(-0.30, min(0.35, vy * 0.02))
        runPhase += heroY > 0.01 ? 0.10 : 0.30
        if runPhase > 100_000 { runPhase = 0 }

        dayPhase += 0.00035
        if dayPhase >= 1 { dayPhase -= 1 }

        if spinFrames > 0 {
            spinFrames -= 1
            spinAngle += 360.0 / 18.0
            if spinFrames == 0 { spinAngle = 0 }
        }
        if dashActive && tick % 2 == 0 { puff(heroX + heroSize / 2, heroY + heroSize / 2, 1, 1, 0.6) }

        spawnStuff()

        let sMul: CGFloat = (slowActive ? 0.5 : 1) * (dashActive ? 1.6 : 1)
        let eff = speed * sMul

        let hL = heroX + 3, hR = heroX + heroSize - 3
        for i in obstacles.indices {
            obstacles[i].x -= eff * (obstacles[i].charger ? 1.7 : 1)
            let o = obstacles[i]
            // Track the closest vertical clearance while the bug is directly over/under the hero.
            if hR > o.x && hL < o.x + o.w {
                let clr = o.flying ? (o.y - (heroY + heroSize)) : (heroY - o.h)
                obstacles[i].minGap = min(obstacles[i].minGap, max(0, clr))
            }
            if !obstacles[i].scored && obstacles[i].x + obstacles[i].w < heroX {
                obstacles[i].scored = true
                clearedObstacle()
                if obstacles[i].golden {
                    jackpot(o.h)
                } else if obstacles[i].minGap <= 7 && !dashActive {
                    addScore(2 * multiplier)
                    showToast("close! +\(2 * multiplier)")
                    puff(heroX + heroSize, o.y + o.h, 5, 1, 1.5)
                }
            }
        }
        obstacles.removeAll { $0.x < -40 }

        let hx = heroX + heroSize / 2, hy = heroY + heroSize / 2
        for i in tokens.indices {
            tokens[i].x -= eff
            if magnetActive {
                tokens[i].x += (hx - (tokens[i].x + 7)) * 0.16
                tokens[i].y += (hy - tokens[i].y) * 0.16
            }
        }
        collectTokens()
        tokens.removeAll { $0.x < -40 || $0.taken }

        for i in powers.indices { powers[i].x -= eff }
        collectPowers()
        powers.removeAll { $0.x < -40 || $0.taken }

        groundScroll += eff
        if groundScroll > 100_000 { groundScroll = 0 }

        speed += 0.0025
        let tier = Int((speed - 3.2) / 0.6)
        if tier > speedTier { speedTier = tier; showToast("faster!") }

        checkCollision()
    }

    // MARK: - Step helpers

    private func clearedObstacle() {
        combo += 1
        multiplier = min(5, 1 + combo / 8)
        addScore(multiplier)
    }

    private func jackpot(_ h: CGFloat) {
        addScore(15 * multiplier)
        showToast("jackpot! +\(15 * multiplier)")
        puff(heroX + heroSize / 2, h, 14, 1, 3)
    }

    private func addScore(_ n: Int) {
        let before = score
        score += n
        scorePop = 1
        if score / 10 > before / 10 {
            showToast(RunnerGame.cheers[(score / 10 - 1) % RunnerGame.cheers.count])
        }
    }

    private func land() {
        landSquash = 1
        puff(heroX + heroSize / 2, 0, 4, 0, 1.4)
    }

    private func spawnStuff() {
        spawn -= 1
        guard spawn <= 0 else { return }

        let flying = score >= 6 && Int.random(in: 0...2) == 0
        if flying {
            let fh = CGFloat(Int.random(in: 13...17))
            obstacles.append(Obstacle(x: width + 24, y: CGFloat(Int.random(in: 24...31)),
                                      h: fh, w: fh * 1.3, kind: Int.random(in: 0...2), flying: true))
            if !metFlyer { metFlyer = true; showToast("heads up!") }
        } else {
            let golden = score >= 12 && Int.random(in: 0...12) == 0
            let charger = !golden && score >= 15 && Int.random(in: 0...4) == 0
            let big = !golden && !charger && score >= 20 && Int.random(in: 0...5) == 0
            let s = big ? CGFloat(Int.random(in: 38...50)) : CGFloat(Int.random(in: 16...34))
            obstacles.append(Obstacle(x: width + 24, y: 0, h: s, w: s * (big ? 1.05 : 0.9),
                                      kind: Int.random(in: 0...2), flying: false,
                                      charger: charger, golden: golden))
        }
        spawn = Int.random(in: 58...102)

        // Tokens — sometimes a short arc you can sweep through in one hop.
        if Int.random(in: 0...2) == 0 {
            let baseX = width + 24 + CGFloat(Int.random(in: 64...120))
            let n = Int.random(in: 1...4)
            for k in 0..<n {
                let t = n > 1 ? Double(k) / Double(n - 1) : 0
                let arc = sin(t * .pi)
                tokens.append(Token(x: baseX + CGFloat(k) * 18, y: 44 + CGFloat(arc) * 34))
            }
        }

        // Power-ups — rare, and only once you're warmed up.
        if score >= 8 && Int.random(in: 0...9) == 0 {
            powers.append(Power(x: width + 24 + CGFloat(Int.random(in: 40...120)),
                                y: CGFloat(Int.random(in: 46...84)),
                                kind: PowerKind.allCases.randomElement() ?? .shield))
        }
    }

    private func collectTokens() {
        let hx = heroX + heroSize / 2, hy = heroY + heroSize / 2
        for i in tokens.indices where !tokens[i].taken {
            let dx = (tokens[i].x + 7) - hx, dy = tokens[i].y - hy
            if dx * dx + dy * dy < 21 * 21 {
                tokens[i].taken = true
                addScore(5 * multiplier)
                showToast("+\(5 * multiplier)")
                puff(tokens[i].x + 7, tokens[i].y, 8, 1, 2)
            }
        }
    }

    private func collectPowers() {
        let hx = heroX + heroSize / 2, hy = heroY + heroSize / 2
        for i in powers.indices where !powers[i].taken {
            let dx = (powers[i].x + 8) - hx, dy = powers[i].y - hy
            if dx * dx + dy * dy < 24 * 24 {
                powers[i].taken = true
                apply(powers[i].kind)
            }
        }
    }

    private func apply(_ kind: PowerKind) {
        flash = 1
        puff(heroX + heroSize / 2, heroY + heroSize / 2, 10, 1, 2.5)
        switch kind {
        case .shield:   shieldActive = true; showToast("shield up!")
        case .coffee:   dashTimer = dashLength; showToast("caffeinated!")
        case .tortoise: slowTimer = slowLength; showToast("slow-mo")
        case .magnet:   magnetTimer = magnetLength; showToast("magnet!")
        }
    }

    private func checkCollision() {
        let heroLeft = heroX + 3, heroRight = heroX + heroSize - 3
        let heroBottom = heroY, heroTop = heroY + heroSize
        for i in obstacles.indices {
            let o = obstacles[i]
            guard heroRight > o.x + 2, heroLeft < o.x + o.w - 2,
                  heroBottom < o.y + o.h - 3, heroTop > o.y + 3 else { continue }

            if dashActive {
                // Plow straight through it.
                obstacles[i].smashed = true
                if !obstacles[i].scored {
                    obstacles[i].scored = true
                    clearedObstacle()
                    if o.golden { jackpot(o.h) }
                }
                puff(o.x + o.w / 2, o.y + o.h / 2, 8, o.golden ? 1 : 0, 3)
                shake = max(shake, 5)
                continue
            }
            if invulnTimer > 0 { continue }
            if shieldActive {
                shieldActive = false
                invulnTimer = 40
                combo = 0; multiplier = 1
                shake = max(shake, 7); flash = 1
                showToast("blocked!")
                puff(heroX + heroSize / 2, heroY + heroSize / 2, 10, 2, 2.5)
                break
            }
            die()
            break
        }
        obstacles.removeAll { $0.smashed }
    }

    private func die() {
        phase = .over
        overLine = RunnerGame.quips.randomElement() ?? "Squashed."
        shake = 12; flash = 1
        puff(heroX + heroSize / 2, heroY + heroSize / 2, 12, 2, 3)
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "CFL.runnerBest")
        }
    }

    private func puff(_ x: CGFloat, _ y: CGFloat, _ n: Int, _ tint: Int, _ spread: CGFloat) {
        for _ in 0..<n {
            particles.append(Particle(x: x + CGFloat.random(in: -3...3), y: y,
                                      vx: CGFloat.random(in: -spread...spread),
                                      vy: CGFloat.random(in: -spread...(spread + 1)),
                                      life: 1, size: CGFloat.random(in: 2...4), tint: tint))
        }
    }

    private func advanceDecor() {
        for i in decor.indices {
            decor[i].x -= decor[i].speed
            if decor[i].x < -30 { decor[i].x = width + 30 }
        }
    }

    private func advanceParticles() {
        for i in particles.indices {
            particles[i].x += particles[i].vx
            particles[i].y += particles[i].vy
            particles[i].vy -= 0.12
            particles[i].life -= 0.045
        }
        particles.removeAll { $0.life <= 0 || $0.y < -6 }
    }

    private func tickBlink() {
        blinkTimer -= 1
        if blinkTimer <= 0 {
            blink.toggle()
            blinkTimer = blink ? Int.random(in: 4...8) : Int.random(in: 80...200)
        }
    }

    private func decay() {
        if landSquash > 0 { landSquash = max(0, landSquash - 0.12) }
        if shake > 0 { shake = max(0, shake - 0.9) }
        if scorePop > 0 { scorePop = max(0, scorePop - 0.08) }
        if flash > 0 { flash = max(0, flash - 0.06) }
        if phase != .running && stretch != 0 { stretch *= 0.8 }
        if toastTimer > 0 { toastTimer -= 1; if toastTimer == 0 { toast = nil } }
        if phase == .running {
            if dashTimer > 0 { dashTimer -= 1 }
            if slowTimer > 0 { slowTimer -= 1 }
            if magnetTimer > 0 { magnetTimer -= 1 }
            if invulnTimer > 0 { invulnTimer -= 1 }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTimer = 70
    }
}

/// Sky + foreground palette for a given point in the day→night cycle. The game runs its own
/// palette (independent of the app's light/dark theme) so the hero and text stay legible against
/// whatever colour the sky currently is.
struct ScenePalette {
    var skyTop: Color
    var skyBottom: Color
    var ink: Color          // strong foreground (hero body, HUD text)
    var inkSoft: Color      // secondary foreground (bugs, ground)
    var isNight: Bool
    var disc: Color         // sun or moon
    var glow: Color
    var sunUp: Bool
    var discX: CGFloat
    var discY: CGFloat
}

func scenePalette(_ p: CGFloat, width: CGFloat) -> ScenePalette {
    let phases: [CGFloat] = [0.00, 0.28, 0.52, 0.78, 1.00]
    let tops: [[Double]] = [
        [0.55, 0.78, 0.96], [0.98, 0.56, 0.34], [0.09, 0.11, 0.26], [0.52, 0.44, 0.76], [0.55, 0.78, 0.96],
    ]
    let bots: [[Double]] = [
        [0.86, 0.94, 1.00], [0.99, 0.82, 0.55], [0.18, 0.20, 0.40], [0.93, 0.78, 0.82], [0.86, 0.94, 1.00],
    ]
    var i = 0
    while i < phases.count - 1 && p > phases[i + 1] { i += 1 }
    let span = max(0.0001, phases[i + 1] - phases[i])
    let t = Double((p - phases[i]) / span)
    func mix(_ a: [Double], _ b: [Double], _ c: Int) -> Double { a[c] + (b[c] - a[c]) * t }
    let top = Color(red: mix(tops[i], tops[i + 1], 0), green: mix(tops[i], tops[i + 1], 1), blue: mix(tops[i], tops[i + 1], 2))
    let bot = Color(red: mix(bots[i], bots[i + 1], 0), green: mix(bots[i], bots[i + 1], 1), blue: mix(bots[i], bots[i + 1], 2))
    let bright = (mix(bots[i], bots[i + 1], 0) + mix(bots[i], bots[i + 1], 1) + mix(bots[i], bots[i + 1], 2)) / 3
    let night = bright < 0.5
    let ink = Color(white: night ? 0.96 : 0.13)
    let inkSoft = Color(white: night ? 0.72 : 0.34)
    let sunUp = p < 0.5
    let local = sunUp ? p / 0.5 : (p - 0.5) / 0.5
    let arc = sin(Double(local) * .pi)
    let discX = width * CGFloat(local)
    let discY = 14 + CGFloat(1 - arc) * 44
    let disc = sunUp ? Color(red: 1.0, green: 0.86, blue: 0.35) : Color(white: 0.92)
    let glow = sunUp ? Color(red: 1.0, green: 0.80, blue: 0.30) : Color(white: 0.85)
    return ScenePalette(skyTop: top, skyBottom: bot, ink: ink, inkSoft: inkSoft, isNight: night,
                        disc: disc, glow: glow, sunUp: sunUp, discX: discX, discY: discY)
}

struct GameView: View {
    @ObservedObject var game: RunnerGame
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private let gold = Color(red: 0.98, green: 0.74, blue: 0.18)
    private let shieldC = Color(red: 0.30, green: 0.62, blue: 0.98)
    private let coffeeC = Color(red: 0.64, green: 0.42, blue: 0.24)
    private let tortoiseC = Color(red: 0.30, green: 0.70, blue: 0.42)
    private let magnetC = Color(red: 0.88, green: 0.28, blue: 0.30)
    private let hitC = Color(red: 0.92, green: 0.33, blue: 0.30)

    private var pal: ScenePalette { scenePalette(game.dayPhase, width: game.width) }
    private var eyeColor: Color { pal.isNight ? Color(white: 0.10) : .white }

    private var grounded: Bool { game.heroY <= 0.01 }
    private var heroBottom: CGFloat { game.groundY - game.heroY }
    private var churn: CGFloat { CGFloat(sin(Double(game.runPhase))) }
    private var scaleY: CGFloat { max(0.6, 1 + game.stretch - game.landSquash * 0.30) }
    private var scaleX: CGFloat { max(0.7, 1 - game.stretch * 0.5 + game.landSquash * 0.28) }
    private var shakeX: CGFloat { CGFloat(sin(Double(game.tick) * 1.7)) * game.shake }
    private var shakeY: CGFloat { CGFloat(cos(Double(game.tick) * 2.3)) * game.shake * 0.5 }
    private var heroOpacity: Double { (game.invulnTimer > 0 && game.tick % 6 < 3) ? 0.35 : 1 }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [pal.skyTop, pal.skyBottom], startPoint: .top, endPoint: .bottom))

                ZStack(alignment: .topLeading) {
                    celestialLayer
                    decorLayer
                    shootingStarLayer
                    hillsLayer
                    fireflyLayer
                    groundLayer
                    speedLines
                    shadowLayer
                    feetLayer
                    heroLayer
                    bugsLayer
                    tokensLayer
                    powersLayer
                    particlesLayer
                }
                .frame(width: game.width, height: game.height, alignment: .topLeading)
                .offset(x: shakeX, y: shakeY)

                flashLayer
                hud
                if game.phase == .ready { readyCard }
                if game.phase == .over { overCard }
            }
            .frame(width: game.width, height: game.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { game.jump() }

            Text("↑ / space / tap to jump · again to double-jump · esc to leave")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { game.enterReady() }
        .onReceive(timer) { _ in game.step() }
    }

    // MARK: - Sky & background

    private var celestialLayer: some View {
        ZStack {
            Circle().fill(pal.glow.opacity(0.28)).frame(width: 46, height: 46).blur(radius: 8)
            Circle().fill(pal.disc).frame(width: 22, height: 22)
            if !pal.sunUp {
                Circle().fill(pal.skyTop.opacity(0.55)).frame(width: 7, height: 7).offset(x: -3, y: -3)
            }
        }
        .offset(x: pal.discX, y: pal.discY)
    }

    private var decorLayer: some View {
        ForEach(game.decor) { d in
            Group {
                if pal.isNight {
                    Circle().fill(Color.white.opacity(0.75)).frame(width: 2.4 * d.scale, height: 2.4 * d.scale)
                } else {
                    Image(systemName: "cloud.fill").font(.system(size: 15 * d.scale))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .offset(x: d.x, y: d.y)
        }
    }

    @ViewBuilder private var shootingStarLayer: some View {
        if pal.isNight {
            let period = 260, dur = 34
            let local = game.tick % period
            if local < dur {
                let epoch = game.tick / period
                let f = CGFloat(local) / CGFloat(dur)
                let startY = CGFloat((epoch * 41) % 60) + 10
                let startX = game.width * 0.15 + CGFloat((epoch * 53) % 70)
                Capsule().fill(Color.white)
                    .frame(width: 18, height: 2)
                    .rotationEffect(.degrees(22))
                    .opacity(Double(1 - f) * 0.9)
                    .offset(x: startX + f * (game.width * 0.6), y: startY + f * 34)
            }
        }
    }

    private var hillsLayer: some View {
        // Two smooth rolling silhouettes drawn as single filled curves (no overlapping shapes,
        // so no translucent seams), scrolling at different speeds for parallax depth.
        ZStack(alignment: .topLeading) {
            HillShape(phase: game.groundScroll * 0.22, baseY: game.groundY - 30,
                      amplitude: 11, wavelength: 190, floor: game.groundY)
                .fill(pal.inkSoft.opacity(0.13))
            HillShape(phase: game.groundScroll * 0.42 + 90, baseY: game.groundY - 15,
                      amplitude: 8, wavelength: 130, floor: game.groundY)
                .fill(pal.inkSoft.opacity(0.22))
        }
        .frame(width: game.width, height: game.height, alignment: .topLeading)
    }

    @ViewBuilder private var fireflyLayer: some View {
        if pal.isNight {
            ForEach(0..<6, id: \.self) { i in
                let t = Double(game.tick)
                let base = Double(i) * 53 + 20
                let x = (base + t * (0.3 + Double(i % 3) * 0.15)).truncatingRemainder(dividingBy: Double(game.width))
                let y = Double(game.groundY) - 26 - sin(t * 0.03 + Double(i)) * 16 - Double(i % 4) * 6
                let glow = 0.4 + 0.35 * sin(t * 0.08 + Double(i) * 1.7)
                Circle().fill(gold.opacity(0.75))
                    .frame(width: 3, height: 3)
                    .shadow(color: gold.opacity(0.8), radius: 3)
                    .opacity(max(0.15, glow))
                    .offset(x: CGFloat(x), y: CGFloat(y))
            }
        }
    }

    private var groundLayer: some View {
        let spacing: CGFloat = 26
        let shift = game.groundScroll.truncatingRemainder(dividingBy: spacing)
        let count = Int(game.width / spacing) + 2
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(pal.inkSoft.opacity(0.7)).frame(height: 1).offset(y: game.groundY)
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(pal.inkSoft.opacity(0.35)).frame(width: 2, height: 5)
                    .offset(x: CGFloat(i) * spacing - shift, y: game.groundY + 2)
            }
        }
    }

    @ViewBuilder private var speedLines: some View {
        if game.dashActive {
            ForEach(0..<5, id: \.self) { i in
                let span = game.width + 60
                let raw = (CGFloat(game.tick) * 11 + CGFloat(i) * 63).truncatingRemainder(dividingBy: span)
                Capsule().fill(gold.opacity(0.5)).frame(width: 22, height: 2)
                    .offset(x: game.width - raw, y: CGFloat(22 + i * 26))
            }
        }
    }

    // MARK: - Hero

    private var shadowLayer: some View {
        let s = max(0.35, 1 - game.heroY / 130)
        let w = game.heroSize * s
        let c = pal.isNight ? Color.white.opacity(0.10 * Double(s)) : Color.black.opacity(0.18 * Double(s))
        return Ellipse().fill(c).frame(width: w, height: 4)
            .offset(x: game.heroX + (game.heroSize - w) / 2, y: game.groundY - 2)
    }

    private var feetLayer: some View {
        let tuck: CGFloat = grounded ? 0 : -2
        let running = grounded && game.phase == .running
        let a = running ? max(0, churn) * 3 : 0
        let b = running ? max(0, -churn) * 3 : 0
        let topY = heroBottom - 4
        return ZStack(alignment: .topLeading) {
            foot.offset(x: game.heroX + 2, y: topY + tuck + a)
            foot.offset(x: game.heroX + game.heroSize - 8, y: topY + tuck + b)
        }
    }

    private var foot: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(pal.ink).frame(width: 6, height: 4)
    }

    private var heroLayer: some View {
        ZStack {
            if game.shieldActive {
                Circle().stroke(shieldC.opacity(0.85), lineWidth: 2)
                    .frame(width: game.heroSize + 12, height: game.heroSize + 12)
                    .scaleEffect(1 + 0.06 * CGFloat(sin(Double(game.tick) * 0.2)))
            }
            heroBodyGroup.rotationEffect(.degrees(Double(game.spinAngle)))
        }
        .frame(width: game.heroSize, height: game.heroSize)
        .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
        .opacity(heroOpacity)
        .offset(x: game.heroX, y: heroBottom - game.heroSize)
    }

    private var heroBodyGroup: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(pal.ink)
            .frame(width: game.heroSize, height: game.heroSize)
            .overlay(face)
            .overlay(hat)
            .overlay(dashOutline)
    }

    @ViewBuilder private var dashOutline: some View {
        if game.dashActive {
            RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(gold, lineWidth: 2)
        }
    }

    @ViewBuilder private var hat: some View {
        let s = game.score
        if s >= 75 {
            Image(systemName: "crown.fill").font(.system(size: 11)).foregroundStyle(gold).offset(y: -14)
        } else if s >= 50 {
            RoundedRectangle(cornerRadius: 1).fill(Color.black).frame(width: 14, height: 4).offset(y: -3)
        } else if s >= 25 {
            ZStack {
                RoundedRectangle(cornerRadius: 1).fill(gold).frame(width: 15, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(gold).frame(width: 9, height: 6).offset(y: -3)
            }
            .offset(y: -12)
        }
    }

    private var face: some View {
        let dead = game.phase == .over
        return ZStack {
            eye.offset(x: 2, y: -3)
            eye.offset(x: 7, y: -3)
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(eyeColor)
                .frame(width: dead ? 6 : 4, height: dead ? 2 : 1.5)
                .offset(x: 4.5, y: dead ? 4 : 3).opacity(dead ? 1 : 0.7)
        }
    }

    private var eye: some View {
        Group {
            if game.phase == .over {
                ZStack {
                    Capsule().fill(eyeColor).frame(width: 4, height: 1.4).rotationEffect(.degrees(45))
                    Capsule().fill(eyeColor).frame(width: 4, height: 1.4).rotationEffect(.degrees(-45))
                }
            } else if game.blink {
                Capsule().fill(eyeColor).frame(width: 3, height: 1.4)
            } else {
                Circle().fill(eyeColor).frame(width: 3, height: 3)
            }
        }
    }

    // MARK: - Bugs, tokens, power-ups, particles

    private var bugsLayer: some View {
        ForEach(game.obstacles) { o in
            BugView(o: o, tick: game.tick, groundY: game.groundY, tint: pal.inkSoft)
        }
    }

    private var tokensLayer: some View {
        let pulse = 1 + 0.12 * CGFloat(sin(Double(game.tick) * 0.15))
        return ForEach(game.tokens.filter { !$0.taken }) { t in
            Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(gold)
                .shadow(color: gold.opacity(0.6), radius: 4)
                .scaleEffect(pulse)
                .offset(x: t.x, y: game.groundY - t.y)
        }
    }

    private var powersLayer: some View {
        ForEach(game.powers.filter { !$0.taken }) { p in
            powerBadge(p.kind).offset(x: p.x, y: game.groundY - p.y)
        }
    }

    private func powerBadge(_ kind: PowerKind) -> some View {
        let pulse = 1 + 0.10 * CGFloat(sin(Double(game.tick) * 0.18))
        let color = powerColor(kind)
        return ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: 24, height: 24)
            Circle().stroke(color, lineWidth: 1.5).frame(width: 24, height: 24)
            powerIcon(kind, 12)
        }
        .scaleEffect(pulse)
        .shadow(color: color.opacity(0.5), radius: 3)
    }

    private func powerColor(_ kind: PowerKind) -> Color {
        switch kind {
        case .shield:   return shieldC
        case .coffee:   return coffeeC
        case .tortoise: return tortoiseC
        case .magnet:   return magnetC
        }
    }

    @ViewBuilder private func powerIcon(_ kind: PowerKind, _ size: CGFloat) -> some View {
        switch kind {
        case .shield:   Image(systemName: "shield.fill").font(.system(size: size, weight: .bold)).foregroundStyle(shieldC)
        case .coffee:   Image(systemName: "cup.and.saucer.fill").font(.system(size: size, weight: .bold)).foregroundStyle(coffeeC)
        case .tortoise: Image(systemName: "tortoise.fill").font(.system(size: size, weight: .bold)).foregroundStyle(tortoiseC)
        case .magnet:   MagnetIcon().frame(width: size + 2, height: size + 2)
        }
    }

    private func particleColor(_ tint: Int) -> Color {
        switch tint {
        case 1:  return gold
        case 2:  return hitC
        default: return pal.inkSoft
        }
    }

    private var particlesLayer: some View {
        ForEach(game.particles) { p in
            Circle().fill(particleColor(p.tint).opacity(Double(max(0, p.life))))
                .frame(width: p.size, height: p.size)
                .offset(x: p.x, y: game.groundY - p.y)
        }
    }

    // MARK: - Overlays

    private var flashLayer: some View {
        Rectangle().fill(Color.white.opacity(Double(game.flash) * 0.35))
            .frame(width: game.width, height: game.height)
            .allowsHitTesting(false)
    }

    private var hud: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(game.score)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .scaleEffect(1 + game.scorePop * 0.4)
                if game.multiplier > 1 {
                    Text("×\(game.multiplier)")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(gold)
                }
            }
            .foregroundStyle(pal.ink)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10).padding(.top, 8)

            HStack(spacing: 6) {
                if game.shieldActive { pip(.shield, 1) }
                if game.dashActive { pip(.coffee, CGFloat(game.dashTimer) / CGFloat(game.dashLength)) }
                if game.slowActive { pip(.tortoise, CGFloat(game.slowTimer) / CGFloat(game.slowLength)) }
                if game.magnetActive { pip(.magnet, CGFloat(game.magnetTimer) / CGFloat(game.magnetLength)) }
            }
            .padding(.leading, 10).padding(.top, 8)

            if let toast = game.toast {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.3)))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
        }
        .frame(width: game.width, height: game.height, alignment: .topLeading)
    }

    private func pip(_ kind: PowerKind, _ frac: CGFloat) -> some View {
        VStack(spacing: 2) {
            powerIcon(kind, 10)
            Capsule().fill(powerColor(kind)).frame(width: 14 * max(0, min(1, frac)), height: 2)
        }
        .frame(width: 16)
    }

    private var readyCard: some View {
        VStack(spacing: 4) {
            Text("BUG HOP").font(.system(size: 22, weight: .heavy, design: .monospaced)).kerning(2)
            Text("hop crawlers · duck fliers · double-jump")
                .font(.system(size: 10))
            Text("grab stars & power-ups · build a combo")
                .font(.system(size: 10))
            Text("space / tap to start")
                .font(.system(size: 11, weight: .semibold)).padding(.top, 6)
            if game.best > 0 {
                Text("best \(game.best)").font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.top, 2)
            }
        }
        .foregroundStyle(pal.ink)
        .frame(width: game.width, height: game.height)
    }

    private var overCard: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.32))
            VStack(spacing: 3) {
                Text(game.overLine).font(.system(size: 16, weight: .bold))
                Text("score \(game.score) · best \(game.best)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                Text("tap to retry").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).padding(.top, 2)
            }
            .foregroundStyle(.white)
        }
        .frame(width: game.width, height: game.height)
    }
}

/// One bug. Crawlers are a plain critter sitting on the floor; fliers get flapping wings and a
/// gentle hover so it reads instantly as "stay grounded, this one's up top".
private struct BugView: View {
    let o: Obstacle
    let tick: Int
    let groundY: CGFloat
    let tint: Color
    private let chargerRed = Color(red: 0.90, green: 0.35, blue: 0.30)

    private let goldC = Color(red: 0.98, green: 0.78, blue: 0.20)

    var body: some View {
        let symbol = o.kind == 1 ? "ladybug.fill" : "ant.fill"
        let top = groundY - o.y - o.h
        let color = o.golden ? goldC : (o.charger ? chargerRed : tint)
        if o.flying {
            let hover = CGFloat(sin(Double(tick) * 0.12 + Double(o.x) * 0.04)) * 2.5
            let flap = 0.4 + 0.6 * abs(CGFloat(sin(Double(tick) * 0.55)))
            ZStack {
                wing(flap: flap, side: -1)
                wing(flap: flap, side: 1)
                Image(systemName: symbol).resizable().scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: o.w * 0.72, height: o.h)
            }
            .frame(width: o.w, height: o.h)
            .offset(x: o.x, y: top + hover)
        } else {
            let shimmer = o.golden ? 1 + 0.07 * CGFloat(sin(Double(tick) * 0.3)) : 1
            ZStack {
                if o.charger {
                    ForEach(0..<3, id: \.self) { k in
                        Capsule().fill(chargerRed.opacity(0.4 - Double(k) * 0.1))
                            .frame(width: 11 - CGFloat(k) * 2, height: 2)
                            .offset(x: o.w / 2 + 7 + CGFloat(k) * 7, y: -o.h * 0.28 + CGFloat(k) * 4)
                    }
                }
                Image(systemName: symbol).resizable().scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: o.w, height: o.h)
                    .shadow(color: o.golden ? goldC.opacity(0.85) : .clear, radius: o.golden ? 5 : 0)
                    .scaleEffect(shimmer)
            }
            .frame(width: o.w, height: o.h)
            .offset(x: o.x, y: top)
        }
    }

    private func wing(flap: CGFloat, side: CGFloat) -> some View {
        Ellipse().fill(tint.opacity(0.4))
            .frame(width: o.w * 0.5, height: o.h * 0.7)
            .scaleEffect(x: flap, y: 1, anchor: side < 0 ? .trailing : .leading)
            .offset(x: side * o.w * 0.3, y: -o.h * 0.15)
    }
}

/// A rolling-hills silhouette drawn as one continuous filled curve (a scrolling sine wave), so
/// there are no overlapping translucent shapes to create seams. Fills from the wave down to `floor`.
struct HillShape: Shape {
    var phase: CGFloat
    var baseY: CGFloat
    var amplitude: CGFloat
    var wavelength: CGFloat
    var floor: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: floor))
        let step: CGFloat = 6
        var x: CGFloat = 0
        while x <= rect.width {
            let y = baseY + sin(Double((x + phase) / wavelength) * 2 * .pi) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
            x += step
        }
        let yEnd = baseY + sin(Double((rect.width + phase) / wavelength) * 2 * .pi) * amplitude
        p.addLine(to: CGPoint(x: rect.width, y: yEnd))
        p.addLine(to: CGPoint(x: rect.width, y: floor))
        p.closeSubpath()
        return p
    }
}

/// A little horseshoe magnet, drawn so it stays crisp at icon sizes (no macOS-14 SF Symbol needed).
private struct MagnetIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lw = w * 0.30
            let inset = lw / 2
            let red = Color(red: 0.88, green: 0.28, blue: 0.30)
            let steel = Color(white: 0.80)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: inset, y: inset))
                    p.addLine(to: CGPoint(x: inset, y: h * 0.5))
                    p.addQuadCurve(to: CGPoint(x: w - inset, y: h * 0.5), control: CGPoint(x: w / 2, y: h * 1.02))
                    p.addLine(to: CGPoint(x: w - inset, y: inset))
                }
                .stroke(red, style: StrokeStyle(lineWidth: lw, lineCap: .butt))
                Capsule().fill(steel).frame(width: lw, height: lw * 0.62).position(x: inset, y: inset)
                Capsule().fill(steel).frame(width: lw, height: lw * 0.62).position(x: w - inset, y: inset)
            }
        }
    }
}

// MARK: - Settings

struct PreferencesView: View {
    @EnvironmentObject var prefs: Preferences

    /// Installed terminals, plus the currently-selected one even if it's since been removed,
    /// so the picker never shows a blank selection.
    private var terminals: [TerminalOption] {
        var list = Terminals.installed
        if !list.contains(where: { $0.bundleId == prefs.terminalBundleId }),
           let current = Terminals.byId(prefs.terminalBundleId) {
            list.append(current)
        }
        return list
    }

    private var selectedTerminal: TerminalOption? { Terminals.byId(prefs.terminalBundleId) }

    /// Featured folders edited as a single comma-separated field.
    private var featuredBinding: Binding<String> {
        Binding(
            get: { prefs.featuredFolderNames.joined(separator: ", ") },
            set: { prefs.featuredFolderNames = $0
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } }
        )
    }

    private var projectFoldersBinding: Binding<String> {
        Binding(
            get: { prefs.projectFolders.joined(separator: ", ") },
            set: { prefs.projectFolders = $0
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } }
        )
    }

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Open in", selection: $prefs.terminalBundleId) {
                    ForEach(terminals) { Text($0.name).tag($0.bundleId) }
                }
                if selectedTerminal?.runsCommand == false {
                    Label("Warp opens the folder but can't auto-run the launch command.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Launch command") {
                TextField("Command", text: $prefs.launchCommand, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
                Text("Runs after cd-ing into the folder — e.g. claude, claude --resume, claude --model opus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Featured folders") {
                TextField("Names", text: featuredBinding, prompt: Text("PROJECTS, OTHER STUFF"))
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. Shown as quick shortcuts at the top of the root when they exist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("New project template") {
                TextField("Folders", text: projectFoldersBinding,
                          prompt: Text("Repositories, Data, Scripts, Docs, Reference"))
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated folders created for each new project, plus a seeded CLAUDE.md and README.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global hotkey") {
                HotKeyField()
                Text("Opens or closes the launcher from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 500)
    }
}

/// Records a global hotkey by capturing the next key-with-modifiers while "recording" is on.
struct HotKeyField: View {
    @EnvironmentObject var prefs: Preferences
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Text(recording ? "Press a shortcut…" : prefs.hotKeyDisplay)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 90)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(recording ? 0.25 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(recording ? Color.accentColor : .clear, lineWidth: 1.5)
                )
            Button(recording ? "Cancel" : "Record") {
                recording ? stopRecording() : startRecording()
            }
            Button("Reset") {
                stopRecording()
                prefs.resetHotKey()
            }
            Spacer()
        }
        .onDisappear(perform: removeMonitor)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // swallow the event while recording
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Require at least one modifier so a bare key can't become a global hotkey.
        guard !flags.isEmpty else { return }
        let key = HotKeyUtil.keyName(event)
        guard !key.isEmpty else { return }
        prefs.setHotKey(
            code: UInt32(event.keyCode),
            modifiers: HotKeyUtil.carbonModifiers(flags),
            display: HotKeyUtil.modifierSymbols(flags) + key
        )
        stopRecording()
    }

    private func stopRecording() {
        recording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Global hotkey (Carbon)

/// Registers a system-wide hotkey via the Carbon Hot Key API. This works without the
/// Accessibility permission that a global NSEvent key monitor would require.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x43464C31 /* "CFL1" */), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - App delegate (status bar item + popover)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let prefs = Preferences()
    private lazy var model = FolderModel(prefs: prefs)
    private let uiState = UIState()
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var hotKey: GlobalHotKey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Size the symbol to fit the menu-bar icon area. The outline `terminal`
            // glyph is a rounded rectangle, so it must fit vertically — too large a
            // point size makes the status item CLIP the top and bottom edges instead
            // of scaling, leaving only the left/right sides visible. 13pt + a small
            // scale keeps the whole outline inside the menu bar, and scaleProportionally
            // guarantees it shrinks rather than clips on shorter menu bars.
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(scale: .medium))
            let image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "Flaunch"
            )?.withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover hosting the SwiftUI view.
        // .preferredContentSize makes the host controller publish the SwiftUI view's
        // intrinsic size, which the popover then uses — so the popover grows/shrinks
        // with content instead of being a fixed box.
        let host = NSHostingController(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(uiState)
                .environmentObject(model.favorites)
                .environmentObject(model.history)
                .environmentObject(prefs)
        )
        host.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = host

        // Close the popover when clicking outside its window.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        // Keyboard navigation while the popover is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            return self.handleKey(event)
        }

        // Global hotkey (configurable): toggles the launcher from anywhere.
        installHotKey()

        // React to settings changes coming from the SwiftUI views.
        NotificationCenter.default.addObserver(
            forName: .cflHotKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installHotKey() }
        }
        NotificationCenter.default.addObserver(
            forName: .cflOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSettings() }
        }
        NotificationCenter.default.addObserver(
            forName: .cflShowLauncher, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showPopover() }
        }
    }

    /// (Re)registers the global hotkey from the current preferences. Reassigning `hotKey`
    /// deinits the previous registration, unregistering it.
    private func installHotKey() {
        hotKey = GlobalHotKey(keyCode: prefs.hotKeyCode, modifiers: prefs.hotKeyModifiers) { [weak self] in
            Task { @MainActor in self?.togglePopover(nil) }
        }
    }

    /// Opens the settings window (a plain window since this is a menu-bar-only app with no
    /// app menu to host the standard Settings scene).
    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: PreferencesView().environmentObject(prefs))
            let window = NSWindow(contentViewController: host)
            window.title = "Flaunch Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// Handles arrow/enter/escape while the popover is open. Returns nil to swallow the
    /// event, or the event itself to let it fall through (e.g. typing into the filter).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // While the setup screen is up, the folder list is hidden — let SwiftUI handle keys
        // (Done via ⏎, Escape, checkbox focus) instead of driving the invisible list.
        if model.pendingSetupRoot != nil { return event }
        // While the hidden game is up, keys drive it instead of the (hidden) folder list.
        if uiState.filterText.trimmingCharacters(in: .whitespaces).lowercased() == "xyzzy" {
            switch Int(event.keyCode) {
            case kVK_Space, kVK_UpArrow:
                uiState.runner.jump()
                return nil
            case kVK_Escape:
                uiState.filterText = ""
                return nil
            default:
                return nil   // swallow everything else so play isn't interrupted
            }
        }

        let items = uiState.navItems
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            guard !items.isEmpty else { return nil }
            // First arrow press just reveals the highlight at the top; subsequent ones move it.
            uiState.selection = uiState.selectionActive ? min(uiState.selection + 1, items.count - 1) : 0
            uiState.selectionActive = true
            return nil
        case kVK_UpArrow:
            guard !items.isEmpty else { return nil }
            uiState.selection = uiState.selectionActive ? max(uiState.selection - 1, 0) : 0
            uiState.selectionActive = true
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard uiState.selectionActive, uiState.selection < items.count else { return nil }
            let item = items[uiState.selection]
            switch item.kind {
            case .featured:
                // Containers: Return browses in, same as clicking the row.
                model.navigateInto(item.url)
                uiState.filterText = ""
                uiState.selection = 0
                uiState.selectionActive = false
            case .folder, .jump:
                model.openInTerminal(item.url, runClaude: !event.modifierFlags.contains(.command))
                popover.performClose(nil)
            }
            return nil
        case kVK_RightArrow:
            // Only navigate once keyboard nav is active; otherwise let the arrow move the
            // text cursor in the filter field.
            guard uiState.selectionActive, uiState.selection < items.count else { return event }
            let item = items[uiState.selection]
            switch item.kind {
            case .jump: model.navigateTo(item.url)      // pinned/recent/search live elsewhere
            case .featured, .folder: model.navigateInto(item.url)
            }
            uiState.filterText = ""
            uiState.selection = 0
            uiState.selectionActive = false
            return nil
        case kVK_LeftArrow:
            // Go back a level whenever the filter is empty — no need to first activate the
            // selection with an arrow key. While typing a filter, let ← move the text cursor.
            guard uiState.filterText.isEmpty else { return event }
            guard model.canGoBack else { return event }
            model.navigateBack()
            uiState.selection = 0
            uiState.selectionActive = false
            return nil
        case kVK_Escape:
            if !uiState.filterText.isEmpty { uiState.filterText = "" }
            else { popover.performClose(nil) }
            return nil
        default:
            return event
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Opens the popover anchored to the status-bar item and gives it key focus.
    private func showPopover() {
        guard let button = statusItem.button else { return }
        uiState.selection = 0
        uiState.selectionActive = false
        // Don't reopen straight into the easter egg.
        if uiState.filterText.trimmingCharacters(in: .whitespaces).lowercased() == "xyzzy" {
            uiState.filterText = ""
        }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - App entry

@main
struct FlaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window — UI lives in the menu bar popover.
        Settings { EmptyView() }
    }
}
