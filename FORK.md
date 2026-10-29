# Fork notes

This is a personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)
that keeps Ghostty's native tab model (one `NSWindow` per tab) and adds a
left sidebar, project grouping, session restore and a few tools on top.
Fork features live in their own files; edits to upstream files are kept to
small hooks so the daily upstream merge stays painless.

## What this fork adds

- **Left sidebar** in place of the tab bar, with tabs grouped by project
  (`.git`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`,
  `Gemfile`, `pom.xml`, `pubspec.yaml`, Gradle builds) and the project's app
  icon or favicon. Config: `sidebar-fields`, `sidebar-opacity`.
- **Open Folder…** (⇧⌘O, File menu or the + next to PROJECTS) opens a tab
  in any folder, which then shows up as a project.
- **Recent projects** below the open ones; click to open a tab there.
- **Restore on relaunch**: windows and tabs come back, and closing the last
  window quits so they are saved. Nothing is typed into restored terminals;
  the last command and agent resume command are in the tab's context menu.
- **Move tabs between windows** by dragging a tab out of the sidebar or onto
  another window's sidebar, or from the tab's context menu.
- **Git**: per-project diff stats and commit/push in the sidebar, and a git
  panel (branch, changes, commit, push, pull). Config: `sidebar-git`.
  Committing asks first, since it stages everything.
- **Agent status** for Claude Code, Codex, OpenCode and others, read from
  their own transcripts and processes (read-only; nothing is installed).
- **IPC + `cli/ghosttyctl`**: rename tabs, set status or colour, notify,
  list tabs. The socket is `~/Library/Application Support/com.shakib.ghostty/ghostty.sock`,
  owner-only, and rejects other users.
- **Tab colours, attention dots, config editor with theme gallery (⌘,)**.

The app's bundle id is `com.shakib.ghostty` (shown as "Ghostty Fork") so it
can run next to official Ghostty. Both read the same Ghostty config file.

## Building

```sh
scripts/fork-build.sh            # ReleaseLocal
scripts/fork-build.sh Debug
open macos/build/ReleaseLocal/Ghostty.app
```

Needs Zig 0.17.0, Xcode 26+ and the Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

## Staying in sync

- `.github/workflows/sync-upstream.yml` merges `upstream/main` daily at
  06:00 UTC and opens a PR on conflicts. Add a `SYNC_PAT` repository secret.
- `scripts/upstream-sync.sh` lists what upstream changed since the last merge,
  grouped by risk. Run it before resolving a conflicted sync PR.

## Credits

Code in this fork is adapted from these MIT-licensed Ghostty forks. Their
copyright notices are kept in the files that came from them.

- [Pro Plus Ultra](https://github.com/Hankyone/ghostty-pro-plus-ultra)
- [Sidegeist](https://github.com/tomreinert/ghostty-sidegeist)
- [Chostty](https://github.com/chlee1001/chostty)
