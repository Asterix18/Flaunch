import SwiftUI

/// The settings window: where folders open, what the list shows, git behaviour, and the hotkey.
struct PreferencesView: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        TabView {
            LaunchSettingsTab()
                .tabItem { Label("Launch", systemImage: "terminal") }
            ListSettingsTab()
                .tabItem { Label("List", systemImage: "list.bullet") }
            GitSettingsTab()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape") }
        }
        .frame(width: 470, height: 480)
    }
}

// MARK: - Launch

private struct LaunchSettingsTab: View {
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

    /// The desktop app is only offered when it's actually installed.
    private var launchTargets: [LaunchTarget] {
        ClaudeDesktop.isInstalled ? LaunchTarget.allCases : [.terminal]
    }

    var body: some View {
        Form {
            Section("Open folders in") {
                Picker("Clicking a folder", selection: $prefs.launchTarget) {
                    ForEach(launchTargets) { Text($0.name).tag($0) }
                }
                if prefs.launchTarget == .claudeDesktop {
                    Text("Opens a Code session in the folder. Claude asks once per folder before "
                         + "working in it. The terminal settings below still apply to the plain "
                         + "terminal button on each row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !ClaudeDesktop.isInstalled {
                    Text("Install the Claude desktop app to launch folders into it directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                Toggle("Reuse a running session instead of opening a second one",
                       isOn: $prefs.reuseRunningSession)
                Text("When Claude is already running in a folder, clicking it brings that window "
                     + "forward. Terminal and iTerm2 only — other terminals can't be searched, so "
                     + "they open a new window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Launch command") {
                TextField("Command", text: $prefs.launchCommand, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
                Text("Runs after cd-ing into the folder — e.g. claude, claude --resume, claude --model opus. "
                     + "Terminal launches only; the desktop app has no shell to run it in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - List

private struct ListSettingsTab: View {
    @EnvironmentObject var prefs: Preferences

    /// Featured folders edited as a single comma-separated field.
    private var featuredBinding: Binding<String> {
        Binding(
            get: { prefs.featuredFolderNames.joined(separator: ", ") },
            set: { prefs.featuredFolderNames = Self.split($0) }
        )
    }

    private var projectFoldersBinding: Binding<String> {
        Binding(
            get: { prefs.projectFolders.joined(separator: ", ") },
            set: { prefs.projectFolders = Self.split($0) }
        )
    }

    private var excludedBinding: Binding<String> {
        Binding(
            get: { prefs.excludedFolderNames.joined(separator: ", ") },
            set: { prefs.excludedFolderNames = Self.split($0) }
        )
    }

    static func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section("Order") {
                Toggle("Sort by activity", isOn: $prefs.sortByActivity)
                Text("Orders folders by the most recent commit, Claude session, or file change "
                     + "instead of alphabetically — so what you touched last comes first, even if "
                     + "you opened it outside Flaunch.")
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

            Section("Search") {
                Toggle("Search every root, not just the current one", isOn: $prefs.searchAllRoots)
                Text("Results from other roots are labelled with the root they came from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Depth: \(prefs.searchDepth) level\(prefs.searchDepth == 1 ? "" : "s")",
                        value: $prefs.searchDepth, in: 1...8)
                TextField("Skip folders named", text: excludedBinding,
                          prompt: Text("node_modules, .build, venv"))
                    .textFieldStyle(.roundedBorder)
                Text("Never indexed. The search also stops at git repos, so a project's internals "
                     + "are never scanned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Git

private struct GitSettingsTab: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Background fetch") {
                Toggle("Fetch visible repos while the launcher is open", isOn: $prefs.autoFetch)
                Stepper("At most every \(prefs.fetchInterval) minute\(prefs.fetchInterval == 1 ? "" : "s")",
                        value: $prefs.fetchInterval, in: 1...120)
                    .disabled(!prefs.autoFetch)
                Text("Without a fetch, the ahead/behind counters on each branch badge only reflect "
                     + "the last time something fetched. Fetching never merges — use “Pull All "
                     + "Clean Repos” in the ⋯ menu for that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pulling") {
                Text("“Pull All Clean Repos” skips any repo with uncommitted changes and reports "
                     + "what it left alone. Launching a repo that's behind still offers to pull "
                     + "first, as before.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Worktrees") {
                Text("Right-click a repo → Git → New Worktree… creates a linked worktree beside it "
                     + "as <repo>-<branch> and opens Claude there, for working a branch in parallel "
                     + "with the main checkout. Existing worktrees are listed in the same menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Global hotkey") {
                HotKeyField()
                Text("Opens or closes the launcher from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude sessions") {
                Text("Right-click any folder for Continue Last Session, or Resume Session to pick "
                     + "from its recent sessions. ⇧⏎ continues the selected folder's last session. "
                     + "Read from ~/.claude/projects, so sessions started from a plain terminal "
                     + "count too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
    }
}
