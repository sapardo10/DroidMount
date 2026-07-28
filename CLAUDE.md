# DroidMount — project guide for Claude

A free MacDroid alternative: mounts an Android phone as a macOS Finder drive with full
**read / write / delete / rename** over ADB, plus a fast direct-adb bulk transfer mode.
Personal tool — USB only, unsigned, no App Store.

## Stack (and why)

```
DroidMount.app (AppKit NSStatusItem menu-bar agent)
   │ launches & supervises (Process)
   ▼
adbfs  (C++ libfuse daemon, vendored + patched)  ──(adb shell/pull/push)──► phone /sdcard
   │
   ▼
FUSE-T (userspace NFS, NO kernel extension)  ──► Finder volume at ~/DroidMount
```

- **FUSE-T**, not macFUSE: kext-less, no Recovery-mode/reboot. `brew install macos-fuse-t/homebrew-cask/fuse-t`.
- **`adbfs-rootless`** (C++ libfuse), not the Go `adbfs`. See the #1 gotcha below.
- **AppKit menu-bar app** built from CLI (no Xcode project).

## Commands

```bash
./build.sh            # build the daemon -> bin/adbfs (compiles vendor/adbfs-rootless against FUSE-T)
./app/build_app.sh    # build build/DroidMount.app (embeds bin/adbfs as a Resource)
open build/DroidMount.app

# CLI mount without the app:
scripts/mount.sh [<serial>] [<mountpoint>]   # default mountpoint /tmp/DroidMount
umount /tmp/DroidMount
```

Toolchain: Go 1.26 (only for the Plan-B fallback), Xcode CLT (swiftc), `brew install pkg-config`, FUSE-T.

## CRITICAL GOTCHAS (read before changing the daemon or FUSE layer)

1. **Pure-Go go-fuse CANNOT use FUSE-T.** The original plan assumed the Go
   `zach-klippenstein/adbfs` would link FUSE-T. It can't: it uses `hanwen/go-fuse`, which
   opens the *kernel* FUSE device (`/dev/osxfuse*`/`/dev/macfuse*`). FUSE-T has no kernel
   device — its compatibility is at the **libfuse (C) API** level only. So the daemon must
   be a libfuse-based C/C++ FS. That's why we use `adbfs-rootless`. (Go adbfs is kept at
   `vendor/_adbfs-go-fallback/`, builds on Go 1.26, runs on **macFUSE** only — Plan B.)

2. **FUSE-T's NFS backend needs `create` AND `statfs`** that plain macFUSE doesn't.
   Both are in `patches/adbfs-rootless-fuse-t.patch`:
   - **`create`**: FUSE-T calls `create` directly for new files; macFUSE synthesized it
     from mknod+open. Without it, new-file writes failed with EACCES (dirs worked, files didn't).
   - **`statfs`**: without it the volume reports **0 bytes free**, so Finder refuses to copy
     files *into* the phone ("not enough space"). It MUST report `/sdcard` (`df -k /sdcard`),
     NOT the mount root — macOS calls statfs on `/`, whose fs is Android's tiny, full root partition.

3. **Build flags**: FUSE-T pkg-config module is `fuse-t` (fallback `fuse`); needs
   `-D_FILE_OFFSET_BITS=64`; headers under `/usr/local/include/fuse/`. `build.sh` handles this.

4. **Device selection needs no code patch**: the daemon runs bare `adb` via `popen`, so the
   launcher exports `ANDROID_SERIAL=<serial>` (adb honors it) + prepends platform-tools to PATH.
   See `scripts/mount.sh` and `MountController.swift`.

5. **Bulk transfer bypasses the mount entirely** — Finder drag-drop through FUSE is ~60×
   slower for many files (per-file process spawn + stat storm + double-copy). The
   "Send Finder Selection (fast)" menu item runs `adb pull -a` / `adb push` directly. It
   auto-detects direction by whether the Finder selection is under the mountpoint.

## Modifying the vendored daemon

`vendor/adbfs-rootless/adbfs.cpp` is edited in place (it's a clone). After changes:
```bash
git -C vendor/adbfs-rootless diff > patches/adbfs-rootless-fuse-t.patch   # keep the patch current
./build.sh && ./app/build_app.sh                                          # rebuild daemon + app
```
Upstream pin: commit `277c088`. FUSE op registration is in `main()`.

## App source (`app/Sources/`)

- `main.swift` — `AppDelegate`, `NSStatusItem`, dynamic menu, bulk-transfer handlers/pickers.
- `MountController.swift` — resolves adb + bundled adbfs, mount/unmount lifecycle, `isMounted()`.
- `DeviceMonitor.swift` — polls `adb devices -l` every 3s.
- `BulkTransfer.swift` — Finder selection via osascript, direction classify, adb pull/push engine.
- `ProgressWindow.swift` — transfer progress + cancel.

Cross-file SourceKit "cannot find X in scope" warnings are **artifacts** — swiftc compiles
all sources together and they resolve. Trust the build, not per-file diagnostics.

## Verification (how this project is tested)

No unit tests yet — everything is verified against a running emulator/device with `adb`
as ground truth. When changing the daemon, always: mount → create/modify/rename/delete a
file through the mount → confirm each with `adb shell ls`/`cat` → check `df -h <mount>`
shows real `/sdcard` space → unmount cleanly (`mount | grep DroidMount` empty). A
`tests/smoke.sh` that scripts this would be a good addition.

## Known limits / future work

- **USB only.** Wireless ADB (`adb tcpip` + connect) is a small future add.
- Mounts device root; writable area is `/sdcard` (Android restricts the rest).
- Unsigned / not notarized — first launch may need right-click → Open. Distribution needs signing.
- Bulk transfer is per-item sequential; batching sources per `adb` call would speed many-small-files.
- `statfs` shells `df` per call (no cache) — fine, minor.

## Setup the user must do once

1. `brew install macos-fuse-t/homebrew-cask/fuse-t` (needs admin password).
2. Phone: enable USB Debugging, plug in USB, accept the RSA prompt. Verify `adb devices`.
3. First bulk transfer prompts "DroidMount wants to control Finder" — approve (that's how
   it reads the Finder selection).
