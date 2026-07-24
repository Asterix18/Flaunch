# Flaunch

A menu bar app for opening a Terminal running `claude` in any of your project folders.

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
- The folder-name menu in the header lists recently used root folders and lets you switch to a
  different root entirely.
- The `⋯` menu in the footer has **Launch at Login** and **Quit**.

### Pinned & recent

- Hover a row and click the ★ (or right-click → **Pin to Top**) to pin a folder. Pinned folders
  show in a **Pinned** section at the top of the root, wherever they live in the tree.
- Folders you launch appear under **Recent** at the root, ordered by how recently and often you
  open them, so your day-to-day projects float to the top.

### Settings

Open **Settings…** from the `⋯` menu in the footer (or press **⌘,** while the launcher is
open). From there you can configure:

- **Terminal** — which terminal app launches open in. Terminal and iTerm2 get full support;
  Ghostty, kitty, WezTerm, and Alacritty are launched via their CLIs; Warp opens the folder
  only (it has no reliable way to auto-run a command). Only installed terminals are listed.
- **Launch command** — what runs after `cd`-ing into a folder. Defaults to `claude`; set it to
  anything, e.g. `claude --resume` or `claude --model opus`.
- **Featured folders** — the comma-separated top-level folder names shown as shortcuts at the
  root (defaults to `PROJECTS, OTHER STUFF`).
- **Global hotkey** — click **Record** and press a shortcut (with at least one modifier) to
  rebind the launcher's global hotkey; **Reset** returns it to the default.

### Global hotkey

- Press **⌃⌥C** (Control-Option-C) anywhere to open/close the launcher without reaching for the
  mouse. You can change this in **Settings** (see above).

### Keyboard navigation

While the launcher is open:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move the selection up/down the list |
| `⏎` | Open the selected folder in Terminal with `claude` |
| `⌘⏎` | Open the selected folder in a plain Terminal |
| `→` | Browse into the selected folder |
| `←` | Go back up a level |
| `Esc` | Clear the filter, or close the window if it's already empty |
| _typing_ | Filters / searches immediately |

## Rebuilding from source

```bash
./build-app.sh            # builds Flaunch.app in this folder
./build-app.sh --install  # also copies it to /Applications, replacing the running instance
./build-app.sh --dist     # also packages app + install.command into Flaunch.zip
```
