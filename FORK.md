# Fork notes

This is a personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)
that keeps Ghostty's native tab model (one `NSWindow` per tab) and adds a
left sidebar, project grouping, session restore and a few tools on top.
Fork features live in their own files; edits to upstream files are kept to
small hooks so the daily upstream merge stays painless.

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
