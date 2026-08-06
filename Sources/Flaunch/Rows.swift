import SwiftUI

// MARK: - Shared context menu

/// The right-click menu shared by every folder row. `isRemote` marks rows whose folder lives
/// somewhere else in the tree (search results, pinned, recent), which need "jump to" rather
/// than "browse into".
struct FolderContextMenu: View {
    let url: URL
    var isRemote = false
    var onNavigate: () -> Void = {}

    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var favorites: Favorites

    private var isGit: Bool { url.gitBranch != nil }
    private var isPinned: Bool { favorites.contains(url) }

    var body: some View {
        Button(prefs.effectiveLaunchTarget.actionLabel) {
            model.launch(url)
            onNavigate()
        }

        sessionItems

        Divider()

        if prefs.effectiveLaunchTarget != .terminal {
            Button("Open in Terminal with Claude") {
                model.openInTerminal(url)
                onNavigate()
            }
        }
        Button("Open in Terminal") {
            model.openInTerminal(url, runClaude: false)
            onNavigate()
        }
        Button(isRemote ? "Go to Folder" : "Browse Into Folder") {
            isRemote ? model.navigateTo(url) : model.navigateInto(url)
            onNavigate()
        }

        let editors = Editors.available
        if !editors.isEmpty {
            Menu("Open in Editor") {
                ForEach(editors, id: \.bundleId) { editor in
                    Button(editor.name) { model.openInEditor(url, bundleId: editor.bundleId) }
                }
            }
        }

        Divider()

        Button(isPinned ? "Unpin" : "Pin to Top") { model.togglePin(url) }
        // The occasional stuff lives in submenus, so the menu stays a glanceable length.
        if isGit {
            Menu("Git") { gitItems }
        }
        Menu("Folder") {
            Button("Open in Finder") { model.openInFinder(url) }
            Button("Reveal in Finder") { model.revealInFinder(url) }
            Button("Copy Path") { model.copyPath(url) }
        }
    }

    /// Resume entries, listed only when the folder actually has Claude history. Session labels are
    /// each session's opening prompt, so you can tell them apart.
    @ViewBuilder
    private var sessionItems: some View {
        let sessions = ClaudeSessions.sessions(for: url, limit: 5)
        if !sessions.isEmpty {
            Button("Continue Last Session") {
                model.launch(url, resume: .latest)
                onNavigate()
            }
            Menu("Resume Session") {
                ForEach(sessions) { session in
                    Button("\(RelativeTime.short(session.modified)) — \(ClaudeSessions.label(for: session))") {
                        model.launch(url, resume: .session(session.id))
                        onNavigate()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var gitItems: some View {
        Button("New Worktree…") { model.promptWorktree(for: url) }
        let worktrees = Git.worktrees(at: url).filter { !$0.isPrimary }
        if !worktrees.isEmpty {
            Menu("Worktrees") {
                ForEach(worktrees, id: \.url) { worktree in
                    Button(worktree.branch ?? worktree.url.lastPathComponent) {
                        model.launch(worktree.url)
                        onNavigate()
                    }
                }
            }
        }
        Button("Fetch") { model.fetchRepos([url], force: true) }
        Button("Pull") { model.pullAll([url]) }
        Button(remoteLabel) { model.openRemote(url) }
    }

    /// Names the host when it's known ("Open on GitHub"), otherwise stays generic. Resolved
    /// lazily — the menu is built on demand, so one `git remote` call here is fine.
    private var remoteLabel: String {
        guard let remote = Git.remoteWebURL(at: url) else { return "Open Remote in Browser" }
        return "Open on \(Git.remoteHostName(remote))"
    }
}

// MARK: - Folder row

/// A folder in the list. Clicking launches it; the hover buttons cover the plain terminal,
/// pinning, and browsing in. In multi-select mode clicking instead queues the folder for a
/// batch launch.
struct FolderRow: View {
    @EnvironmentObject var model: FolderModel
    @EnvironmentObject var favorites: Favorites
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var statusStore: GitStatusStore
    @EnvironmentObject var uiState: UIState
    @State private var hovering = false

    let url: URL
    var isSelected: Bool = false
    /// Path shown under the name for folders that live elsewhere in the tree.
    var relativePath: String? = nil
    /// Whether the row's actions jump to the folder rather than descending into it.
    var isRemote: Bool = false
    /// Called after an action that should dismiss a search.
    var onNavigate: () -> Void = {}

    private var branch: String? { url.gitBranch }
    private var isGit: Bool { branch != nil }
    private var isPinned: Bool { favorites.contains(url) }
    private var highlighted: Bool { hovering || isSelected }
    private var status: Git.Status { statusStore.status(for: url) ?? Git.Status() }
    private var tileColors: [Color] { Palette.tile }

    private var showsPath: Bool { relativePath?.isEmpty == false }

    private var queuePosition: Int? {
        uiState.batchSelection.firstIndex(of: url.path).map { $0 + 1 }
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: primaryAction) {
                HStack(spacing: 10) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // The name wins the width fight: a shortened branch name still
                                // shows its colour and ahead/behind counters, but a shortened
                                // folder name tells you nothing.
                                .layoutPriority(1)
                            // Pinned state rides inline so the star doesn't need permanent
                            // space in the trailing controls.
                            if isPinned, !uiState.batchMode {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            if !showsPath { Spacer(minLength: 6); inlineBadge }
                        }
                        if showsPath {
                            HStack(spacing: 5) {
                                inlineBadge
                                Text(relativePath ?? "")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    // Decorative: keeps the "there's more inside" cue on every row. The real
                    // browse control is the matching button in the hover overlay.
                    if !uiState.batchMode {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if uiState.batchMode {
                queueBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowBackground)
        )
        // The row actions float above the row on hover rather than reserving ~70pt of every row
        // for controls you can't see — that space is what was truncating folder names.
        .overlay(alignment: .trailing) {
            if highlighted && !uiState.batchMode {
                hoverButtons
                    .padding(.trailing, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? Palette.selection : Palette.hover)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.background.opacity(0.75)))
                    )
            }
        }
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .task(id: url) {
            if isGit { statusStore.request(url) }
        }
        .contextMenu {
            FolderContextMenu(url: url, isRemote: isRemote, onNavigate: onNavigate)
        }
    }

    /// A single-line row keeps the branch badge on the right. Rows that show a path move it
    /// under the name so long folder names stay readable.
    @ViewBuilder
    private var inlineBadge: some View {
        if let branch = branch, !uiState.batchMode {
            BranchBadge(branch: branch, status: status)
        }
    }

    private var rowBackground: Color {
        if queuePosition != nil { return Color.accentColor.opacity(0.14) }
        guard highlighted else { return .clear }
        return isSelected ? Palette.selection : Palette.hover
    }

    /// Repos keep the solid tile; plain folders get a flat glyph. A screenful of identical filled
    /// tiles was heavy and told you nothing — now the tile itself means "this is a repo".
    @ViewBuilder
    private var tile: some View {
        if isGit {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: tileColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: (tileColors.last ?? .black).opacity(0.35), radius: 2, y: 1)
        } else {
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }

    private func primaryAction() {
        if uiState.batchMode {
            uiState.toggleBatch(url)
            return
        }
        model.launch(url)
        onNavigate()
    }

    @ViewBuilder
    private var queueBadge: some View {
        if let position = queuePosition {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.accentColor))
                .padding(.horizontal, 4)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.55)
                .padding(.horizontal, 4)
        }
    }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            iconButton("terminal", help: "Open in plain Terminal (no \(prefs.launchCommand))") {
                model.openInTerminal(url, runClaude: false)
                onNavigate()
            }

            PinButton(isPinned: isPinned, visible: true) {
                model.togglePin(url)
            }

            iconButton("chevron.right", help: isRemote ? "Go to \(url.lastPathComponent)"
                                                      : "Browse into \(url.lastPathComponent)") {
                isRemote ? model.navigateTo(url) : model.navigateInto(url)
                onNavigate()
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "chevron.right" ? 10 : 11, weight: .semibold))
                .foregroundStyle(highlighted ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(highlighted ? Color.secondary.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
