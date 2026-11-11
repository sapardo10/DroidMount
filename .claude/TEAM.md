# DroidMount team rules

Shared model: `~/.claude/team-kit/README.md` and `LEARNINGS.md`. This file holds only what is specific to DroidMount. Runtime state: `~/.claude/droidmount-team/`. Memory: `project_droidmount_arch.md`.

## Stack
- macOS menu-bar agent (AppKit `NSStatusItem`, swiftc, no Xcode project) in `app/Sources/`, supervising `adbfs` (vendored, patched C++ libfuse daemon in `vendor/adbfs-rootless`) over FUSE-T (no kext). Phone `/sdcard` appears as a Finder volume; a fast bulk mode runs `adb pull/push` directly. Personal tool: USB only, unsigned, no App Store. Repo `CLAUDE.md` / `AGENTS.md` carry the gotchas (read them before touching the daemon).

## Hard rules
- Pure-Go go-fuse cannot use FUSE-T (it opens a kernel device). The daemon stays libfuse C++; `vendor/_adbfs-go-fallback` is macFUSE-only Plan B.
- FUSE-T needs `create` AND `statfs` in the daemon (statfs reports `/sdcard`, not `/`). After editing `vendor/adbfs-rootless/adbfs.cpp`, regenerate `patches/adbfs-rootless-fuse-t.patch` (`git -C vendor/adbfs-rootless diff`) and rebuild daemon + app. Upstream pin `277c088`.
- Device selection is `ANDROID_SERIAL` + platform-tools on PATH, no daemon patch. The app passes `-o rootdir=/sdcard`.
- SourceKit "cannot find X in scope" warnings across files are artifacts; trust `swiftc` via the build.
- Daemon changes are verified on a device against `adb` ground truth: mount, create/modify/rename/delete through the mount, confirm with `adb shell`, `df -h` shows real `/sdcard`, unmount leaves `mount | grep DroidMount` empty.
- Never commit `bin/` or `build/` outputs. No sudo or admin password prompts from an agent; FUSE-T install is the owner's.

## Local CI (the merge gate)
- Command: `tool/ci.sh` on the committed head (added by this team: no CI script existed). It runs `./build.sh`, `./app/build_app.sh` and compiles the `tests/dmtest.swift` harness: the same build steps as `.github/workflows/release.yml`. There are no unit tests; behaviour is proven by the device check above (QA role). Needs FUSE-T and pkg-config installed.

## Merge and release
- Merge path today: direct commits on `main` (no PRs in history). Default: local squash-merge into `main` + push `main`, after Local CI PASS + Reviewer GO (+ QA GO on daemon/transfer changes) on one SHA.
- CAUTION: every push to `main` that touches non-`.md` files runs `.github/workflows/release.yml` on a macOS runner and publishes/updates the GitHub Release named by the `VERSION` file. Batch pushes. A new numbered release = bump `VERSION` in a commit (the app bundle version is stamped from it). Releases need the owner's OK in chat; the push of a `VERSION` bump is the release.

## Devices
- Android emulator/AVD named `droidmount_<role>`, or the owner's phone only with the owner in chat (ask first; read-only adb needs no ask). Pin with `ANDROID_SERIAL`. Unmount and kill the daemon after every run; check `mount | grep DroidMount` is empty.

## Skills
Dev: investigate. Reviewer: review, code-review. QA: android-two-device-qa, computer-use only with the owner's grant.

## Commit format
`<type>(<scope>): <description>` (types: feat, fix, chore, docs; no ticket system).
