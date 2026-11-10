# DroidMount — project guide for Codex

A free MacDroid alternative: mounts an Android phone's **`/sdcard`** user storage as a
macOS Finder drive with full **read / write / delete / rename** over ADB, auto-mounts on
connect, auto-unmounts on disconnect, plus a fast batched direct-adb bulk transfer mode.
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
scripts/mount.sh [<serial>] [<mountpoint>]   # default mountpoint /tmp/DroidMount, mounts /sdcard
umount /tmp/DroidMount

# Headless test of the real transfer engine (see "Verification"):
cp app/Sources/BulkTransfer.swift app/Sources/MountController.swift <tmp>/ && cp tests/dmtest.swift <tmp>/main.swift
swiftc -O -framework AppKit -o <tmp>/dmtest <tmp>/*.swift
<tmp>/dmtest <serial> phoneToMac|macToPhone <destDir> <paths...>
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
     NOT the mount root — macOS calls statfs on `/`, whose fs is Android's tiny, full root
     partition. It's cached for 5 s (`statfs_cached*`) since Finder polls it constantly.

3. **Build flags**: FUSE-T pkg-config module is `fuse-t` (fallback `fuse`); needs
   `-D_FILE_OFFSET_BITS=64`; headers under `/usr/local/include/fuse/`. `build.sh` handles this.

4. **Device selection needs no code patch**: the daemon runs bare `adb` via `popen`, so the
   launcher exports `ANDROID_SERIAL=<serial>` (adb honors it) + prepends platform-tools to PATH.
   See `scripts/mount.sh` and `MountController.swift`.

5. **The app passes `-o rootdir=/sdcard`** (custom daemon opt, `MountController.swift` and
   `scripts/mount.sh`). The daemon resolves the symlink at startup (`readlink -f` →
   e.g. `/storage/emulated/0`) and mounts the phone's *user storage* as the volume root;
   all device commands go through `devPath()`/`dev_escaped` while cache keys stay FUSE paths.

6. **Hybrid read strategy** (daemon): read-only opens register per-fd `ReadOnlyState`;
   reads use one-shot full `adb pull` when size ≤ `FULL_PULL_MAX` (32 MiB) OR a single
   read ≥ `LARGE_READ` (128 KiB — FUSE-T's kernel readahead makes the first read this big,
   so peeks usually pull once — cheap for typical media) OR dd-traffic ≥ `PULL_UPGRADE_AT`
   (8 MiB, files ≤ `PULL_UPGRADE_MAX` 256 MiB); otherwise cheap `dd` range fetch (capped
   `MAX_DD_FETCH` 8 MiB). Reads clamp to the known EOF. Gotchas found while building it:
   - `parse_ls_size`: the size column is `3 + uid_offset`, not `4 +`.
   - **`adb pull` REPLACES its destination file** (rename → new inode), so any fd held
     before the pull is stale: re-open the temp into `st.pullFd` after the pull, and
     `adb_release` must close it.
   - Per-path `pullLocks` (`pullMutexFor`) serialize concurrent `adb_pull` of the same file.

7. **Bulk transfer bypasses the mount entirely** — Finder drag-drop through FUSE is ~60×
   slower for many files (per-file process spawn + stat storm + double-copy). The
   "Send Finder Selection (fast)" menu item runs **batched** (`≤16` items per call) and
   **parallel** (`maxConcurrent` = 4 adb calls in flight) `adb pull -a` / `adb push`.
   adb quirks it depends on:
   - Multi-source `adb push` requires the destination dir to EXIST (`ensureRemoteDir`).
   - Push destination must be given WITHOUT a trailing slash: a bare existing dir makes
     directory sources land under their own names (Finder semantics); a trailing slash
     merges a directory's CONTENTS into the dest instead. `adb pull` keeps the slash.
   - Pre-size phone paths with ONE `adb shell` call per ≤48 paths; each per-path
     `du -sk` / `stat -c %s` runs in a background subshell on the device
     (`( … ) & … ; wait`), so the chunk costs ~one spawn, not one per path. Indexed
     output (`<i> D|F <bytes>`) keeps the mapping for missing paths (value 0).
   - Progress is parsed from adb's OWN stderr — it prints `<source>: 1 file
     pulled/pushed, …` per file even when stderr is a pipe. The incremental stderr
     reader marks each source done (no extra adb calls, no poll-sleep granularity);
     a slower partial-byte measurement (local sizes for pulls — free; one remote
     stat for pushes per second) fills the gaps. The wait loop itself ticks at 0.1 s.
     NOTE: the progress closure can fire from two threads — keep `lastPolled` locked.
   - Measured (emulator, 60 files ≈ 16 MB): **0.45 s each direction** (was 2.4 s
     sequential — the old 0.5 s poll-sleep per batch dominated); 200 MB single file
     in 0.73 s (~284 MB/s, bandwidth-bound, unchanged by parallelism).

8. **AppKit SIGTERM gotcha (app)**: an accessory app launched from a terminal dies on
   SIGTERM via the default disposition — `applicationWillTerminate` NEVER runs (verified:
   zero logs, orphaned mount + daemon). `main.swift` installs `installSignalCleanup` which
   `execv("/sbin/umount <mountpoint>")`s on SIGTERM/SIGINT/SIGHUP; the daemon's fuse loop
   then sees ENOTCONN and exits. Don't "simplify" this away.

9. **Fast-browsing caches (daemon)** — every browse op used to be a live adb round trip
   (~100-300 ms on a real device); three layers now absorb them:
   - **Directory-listing cache**: `adb_readdir` keeps the `ls -la` output in `dirListings`
     for `DIR_LISTING_TTL` (2 s) keyed like `fileData` (escaped FUSE path). Finder
     re-lists on focus changes / back-navigation; re-lists within the TTL are free.
     An EMPTY reply (phone gone) is NOT cached, or files would vanish for 2 s.
   - **Invalidate on mutation**: every mutating handler calls `invalidateParentListing(path)`
     (create/flush/truncate/mknod/mkdir/rename(both parents)/rmdir/unlink/utimens) so a
     listing is re-fetched immediately after a change through the mount. The TTL only
     bounds staleness for OUT-of-mount changes (camera, media scanner, bulk transfers
     that bypass the mount — reflected within 2 s).
   - **Open fast path**: a read-only `adb_open` rides on a fresh (30 s) cached stat from
     `fileData` and skips its `ls -l -a -d` spawn entirely; write opens still verify live.
   Note: on the emulator the macOS NFS **kernel dentry cache** absorbs re-lists too, so
   test these layers by watching the daemon log — fresh fetches log `exec_command:
   adb shell "ls -l -a …"`; cache hits log nothing new.

## Modifying the vendored daemon

`vendor/adbfs-rootless/adbfs.cpp` is tracked as plain files (no nested git repo, no
submodule). The committed version already contains our changes (pure upstream lives in
the initial commit `636377f`); `patches/adbfs-rootless-fuse-t.patch` is the cumulative
diff of the patched file vs that upstream blob, so it still applies to a fresh clone of
upstream. After changes, regenerate the patch against the upstream blob (relative paths)
and verify the round-trip:
```bash
git diff --relative=vendor/adbfs-rootless 636377f -- vendor/adbfs-rootless/adbfs.cpp > patches/adbfs-rootless-fuse-t.patch
B=$(mktemp -d) && git show 636377f:vendor/adbfs-rootless/adbfs.cpp > $B/adbfs.cpp \
  && patch -s $B/adbfs.cpp < patches/adbfs-rootless-fuse-t.patch \
  && diff $B/adbfs.cpp vendor/adbfs-rootless/adbfs.cpp   # must be empty
./build.sh && ./app/build_app.sh                                          # rebuild daemon + app
```
Upstream pin: commit `277c088` (as committed in the outer repo's initial commit `636377f`).
FUSE op registration is in `main()`.

## App source (`app/Sources/`)

- `main.swift` — `AppDelegate`, `NSStatusItem`, dynamic menu (toggles, ⌘Q), auto-mount /
  unmount-blocklist logic, mount-failure retries (5×10 s — the boot race where adb
  reports the device before `/sdcard` is ready used to brick the app until replug),
  notifications wiring, dynamic phone-folder picker, and
  `installSignalCleanup` (the SIGTERM umount handler — see gotcha #8).
- `MountController.swift` — resolves adb + bundled adbfs, mount/unmount lifecycle
  (passes `-o rootdir=/sdcard`), `isMounted()`, `adopt()` for relaunch re-adoption.
  Daemon stdout/stderr goes to `~/Library/Logs/DroidMount/daemon.log` (fresh per
  mount attempt — ground truth for mount failures). `mountPoint` is `static`
  (shared with the signal handler).
- `DeviceMonitor.swift` — polls `adb devices -l` every 2s (fast auto-mount/unmount
  reaction) with a generation counter (stale results discarded) and an 8 s watchdog
  kill for hung adb.
- `BulkTransfer.swift` — Finder selection via osascript, direction classify, **parallel**
  batched adb pull/push engine (≤16 items/call, up to 4 calls in flight), parallel
  device-side pre-sizing, cumulative progress driven by adb's per-file stderr lines.
- `ProgressWindow.swift` — cumulative progress + transient "Done" state + cancel.
- `Notifier.swift` — UNUserNotificationCenter wrapper (request + post).

Cross-file SourceKit "cannot find X in scope" warnings are **artifacts** — swiftc compiles
all sources together and they resolve. Trust the build, not per-file diagnostics.

## Verification (how this project is tested)

Live verification against an emulator/device with `adb` as ground truth. App lifecycle
cycles verified live: launch → auto-mount (~3-6 s); `adb kill-server` → auto-unmount
within one 2 s poll → reconnect → auto-remount; SIGTERM/SIGINT/quit → mount + daemon
gone in <1 s. Transfer engine verified headless via `tests/dmtest.swift` (compiles the
real `BulkTransfer` + `MountController` with a CLI `main`): flat files both directions
(byte-compared), directories (Finder semantics), missing paths (clean batch error).
Current benchmark (emulator, 60 files ≈ 16 MB): 0.45 s each direction (was 2.4 s
before the parallel + stderr-progress engine); 200 MB file in 0.73 s (~284 MB/s).
Browsing: re-lists within the 2 s daemon TTL (and the kernel dentry cache) are
instant; a create through the mount invalidates the parent listing immediately.

When changing the daemon, still do the classic pass: mount → create/modify/rename/delete
a file through the mount → confirm each with `adb shell ls`/`cat` → check `df -h <mount>`
shows real `/sdcard` space → unmount cleanly (`mount | grep DroidMount` empty).

## Known limits / future work

- **USB only.** Wireless ADB (`adb tcpip` + connect) is a small future add.
- The volume is `/sdcard` (user storage); the rest of the device fs is not exposed.
- Unsigned / not notarized — first launch may need right-click → Open. Distribution needs signing.
- Launch-at-login uses `SMAppService` (macOS 13+); untested for ad-hoc-signed bundles run
  from outside /Applications — register() may need a stable location/identity.
- Notifications require the user to approve the first-launch permission prompt.
- Bulk transfer runs up to 4 adb calls in flight (`maxConcurrent`); beyond that,
  more concurrency risks device-side process pressure and muddies error attribution.
- The 2 s directory-listing TTL means out-of-mount changes (camera, bulk transfer)
  take up to 2 s to appear in an already-open Finder window.

## Setup the user must do once

1. `brew install macos-fuse-t/homebrew-cask/fuse-t` (needs admin password).
2. Phone: enable USB Debugging, plug in USB, accept the RSA prompt. Verify `adb devices`.
3. First bulk transfer prompts "DroidMount wants to control Finder" — approve (that's how
   it reads the Finder selection).
