# Flaunch

A menu bar app for opening a Terminal running `claude` in any of your project folders — and for
picking up where you left off, since it can resume a folder's previous Claude sessions.

## Requirements

- macOS 13+
- The [`claude`](https://claude.com/claude-code) CLI already installed and on your `$PATH`

## First-time setup

1. Unzip the download. You'll get a **Flaunch** folder containing the app and an
   **`install.command`** installer.
2. **Right-click (Control-click) `install.command` → Open → Open.** That's the whole install: it
   copies the app to `/Applications`, clears the macOS quarantine flag, and launches it.
   - Why right-click and not double-click? macOS blocks *downloaded* scripts from unidentified
     developers on a plain double-click; right-click → **Open** is how you approve it. You only
     do this once, on the installer — after it runs, the app itself opens on a normal
     double-click because the installer has already cleared its quarantine flag.
3. Click the terminal icon that appears in the menu bar (top-right of the screen).
4. You'll see "Pick a folder to get started" — click **Choose Folder…** and select the parent
   folder that contains your projects (e.g. your `Solutions` folder, or wherever you keep repos).
   This choice is remembered for next time.
5. A quick **setup screen** appears for the folder you picked:
   - If it doesn't already have them, you can tap **Create PROJECTS & OTHER STUFF** to add those
     recommended starter folders.
   - Otherwise, tick which of the folders it found should show up at this level, then hit
     **Done** (or **Show All** to keep everything). Un-ticked folders are hidden from the root
     but stay reachable through search — this keeps a busy folder tidy.

   This appears whenever you switch to a different root folder, and your choice is remembered
   per folder. You can reopen it anytime from **⋯ → Choose Folders to Show…**.

### Choosing which folders show

When you pick a root, the setup screen lets you curate what appears there — handy if the folder
holds a mix of projects and clutter. Only the folders you tick show at the root; the rest are
hidden from the list but still turn up in search and can be reached by browsing in. Re-run it
from the **⋯** menu (**Choose Folders to Show…**) to adjust later.

### Featured top-level folders

The launcher can also surface a couple of top-level folders as emphasised quick-launch shortcuts
at the top of the root. By default it looks for:

```
PROJECTS      # your client / product work
OTHER STUFF   # tooling & shared infrastructure
```

Any of these that exist (and are shown) appear as emphasised rows at the top — click one to
browse into it. The setup screen offers to create them for you, and you can change which names
are featured in **Settings** (see below). Everything works fine without them.

## Using it

- At the root, type in the search box to search **all** projects nested inside your folders
  (e.g. anything under `PROJECTS/…`), not just the top level — results show their path and
  clicking one jumps straight there. Once you've browsed into a folder, the box filters just
  that folder's contents.
- Click a folder in the list to open it in Terminal running `claude`.
- To open a folder in a plain Terminal (just `cd`, no `claude`), hover the row and click the
  terminal icon (or right-click the row → **Open in Terminal**).
- Click the `›` chevron on a row (or right-click → **Browse Into Folder**) to look inside a
  folder for nested projects, then use the `‹` back button in the header to go back up.
- The terminal icon in the header opens `claude` in whatever folder you're currently browsing
  (including the root itself). Click the chevron next to it for **Open in Terminal** if you
  want a plain terminal there instead.
- The folder-name menu in the header lists recently used root folders, switches to a different
  root, and holds **Refresh**.
- Git repos and plain folders share one list: a repo is the one with a filled tile and a branch
  badge.
- The `⋯` menu in the footer has **Launch at Login** and **Quit**.
- Opening the app again from Finder, Launchpad, or the Dock brings the launcher up, rather than
  looking like nothing happened.

### Pinned & recent

- Hover a row and click the ★ (or right-click → **Pin to Top**) to pin a folder. Pinned folders
  show in a **Pinned** section at the top of the root, wherever they live in the tree.
- The three most recently launched folders appear under **Recent** at the root, ordered by how
  recently and often you open them. Anything already listed below (or the folder you're in) is
  left out, so the section never repeats what's on screen.

## Resuming Claude sessions

Flaunch reads Claude Code's own session store (`~/.claude/projects`), so it knows what you were
last doing in a folder — including sessions started from a plain terminal.

- Right-click a folder for **Continue Last Session**, or **Resume Session ▸** to pick from its
  recent sessions, each labelled with the prompt it opened with.
- **⇧⏎** continues the selected folder's most recent session.
- In a project view, a **Resume** pill appears when the project has Claude history.
- Clicking a folder that already has Claude running brings that terminal window forward instead of
  starting a second session in the same repo (Terminal and iTerm2, which can be searched by tab
  title; other terminals open a new window). Turn it off in **Settings → Launch**.

## Git

The branch badge on each repo shows its branch plus how far ahead/behind it is and whether the
working tree is dirty.

- **Background fetch** keeps those counters honest: while the launcher is open, visible repos are
  fetched (never merged), at most once every 10 minutes each. Configurable in **Settings → Git**.
- **⋯ → Fetch All Repos** / **Pull All Clean Repos**. The pull skips any repo with uncommitted
  changes and tells you which ones it left alone.
- Right-click a repo → **Git ▸** for **Fetch**, **Pull**, **Open on GitHub** (or
  Bitbucket/GitLab — whatever `origin` points at), and **New Worktree…**, which creates a linked
  worktree beside the repo as `<repo>-<branch>` and opens Claude in it, for working a branch in
  parallel with the main checkout. Existing worktrees are listed in the same menu.

## Other bits

- **Sort by activity** (⋯ menu or **Settings → List**) orders folders by the most recent commit,
  Claude session, or file change instead of alphabetically — so what you touched last comes first,
  even if you opened it outside Flaunch.
- **Select Multiple Folders…** (⋯ menu) queues folders as you click them, then opens the lot
  together: one tab per folder in iTerm2, one window each in Terminal.app (which can't script new
  tabs without Accessibility permission).
- Terminal tabs are titled with the folder name, so six open sessions are tellable apart.
- Search can cover **every root** you've pointed the launcher at, not just the current one;
  results say which root they came from. Depth and skipped folder names are configurable.

### Settings

Open **Settings…** from the `⋯` menu in the footer (or press **⌘,** while the launcher is
open).

It's split into four tabs:

- **Launch** — where clicking a folder sends it (Terminal or the Claude desktop app), which
  terminal app to use, the launch command, and whether to reuse a running session. Terminal and
  iTerm2 get full support; Ghostty, kitty, WezTerm, and Alacritty are launched via their CLIs;
  Warp opens the folder only (it has no reliable way to auto-run a command). Only installed
  terminals are listed.
- **List** — activity sorting, featured folder names, the new-project template, and the search
  scope (all roots, depth, skipped folder names).
- **Git** — background fetch and its interval.
- **Advanced** — the global hotkey (click **Record**, press a shortcut with at least one
  modifier; **Reset** restores the default).

### Global hotkey

- Press **⌃⌥C** (Control-Option-C) anywhere to open/close the launcher without reaching for the
  mouse. You can change this in **Settings** (see above).

### Keyboard navigation

While the launcher is open:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move the selection up/down the list |
| `⏎` | Open the selected folder in Terminal with `claude` |
| `⇧⏎` | Continue the most recent Claude session there |
| `⌘⏎` | Open the selected folder in a plain Terminal |
| `→` | Browse into the selected folder |
| `←` | Go back up a level |
| `Esc` | Cancel multi-select, clear the filter, or close the window |
| _typing_ | Filters / searches immediately |

## Rebuilding from source

```bash
./build-app.sh            # builds Flaunch.app in this folder
./build-app.sh --install  # also copies it to /Applications, replacing the running instance
./build-app.sh --dist     # also packages app + install.command into Flaunch.zip
```
