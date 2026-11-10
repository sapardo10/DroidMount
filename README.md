# DroidMount

A free macOS menu-bar app that mounts your Android phone as a Finder drive with
**full read / write / delete / rename** — the things MacDroid puts behind its PRO
paywall. Connects over **ADB**, mounts via **FUSE-T** (no kernel extension required).

**[Download the latest release](https://github.com/sapardo10/DroidMount/releases/latest)**
— unzip and see [One-time setup](#one-time-setup) below. No build tools required if
you use the prebuilt app; the manual build steps are only needed if you want to
build from source.

## How it works

```
DroidMount.app (menu-bar controller)
      │  launches & supervises
      ▼
adbfs  ──(adb shell / pull / push)──►  Android phone (/sdcard, read-write)
      │
      ▼
FUSE-T (userspace NFS, no kext)  ──►  Finder volume at ~/DroidMount
```

- **adbfs** — a small C++ libfuse filesystem (`vendor/adbfs-rootless`, plus our
  `patches/adbfs-rootless-fuse-t.patch`). The patch adds the `create` handler FUSE-T's
  NFS backend requires, a `statfs` handler (cached 5 s) so the volume reports
  `/sdcard`'s real free space — without it Finder refuses to copy files *into* the phone
  — and a hybrid read strategy: small reads stream in cheap `dd` range fetches, while
  large/sequential reads transparently switch to one `adb pull` per file, so browsing a
  few KB and streaming a 200 MB video are both fast. Read/write by default.
- **FUSE-T** — kext-less FUSE for macOS. No Recovery-mode security downgrade, no reboot.
- **DroidMount.app** — an `NSStatusItem` agent (no Dock icon) that detects devices,
  **auto-mounts** on connect (toggleable), **auto-unmounts on disconnect**, mounts
  `/sdcard` (the phone's user storage) as the volume root, posts notifications for
  mount/unmount/transfer events, offers a **Launch at Login** toggle, and can send the
  current Finder selection straight to/over the phone via batched `adb pull`/`push`.

## One-time setup

1. **Install FUSE-T** (needs your admin password):
   ```
   brew install macos-fuse-t/homebrew-cask/fuse-t
   ```
2. **Install build tools** (if missing): `brew install go pkg-config` and Xcode CLT.
3. **On the phone**: Settings → Developer Options → enable **USB Debugging**.
   Plug in over USB and tap **Allow** on the RSA prompt. Verify:
   ```
   ~/Library/Android/sdk/platform-tools/adb devices
   ```

## Build

```
./build.sh            # builds the adbfs daemon -> bin/adbfs (against FUSE-T)
./app/build_app.sh    # builds build/DroidMount.app (embeds the daemon)
```

## Run

```
open build/DroidMount.app
```

A phone icon appears in the menu bar. Newly attached devices are **mounted
automatically** (first launch asks for permission to show notifications; turn
auto-mount off in the menu any time). Click the icon:
- **Mount “<device>”** / **Unmount** — manual control (unmounting remembers your
  choice until the device reconnects, so it won't immediately re-mount).
- **Open … in Finder** — reveals `~/DroidMount` (the phone's `/sdcard`).
- **Send Finder Selection (fast)…** — bulk copy, see below.
- **Auto-Mount on Connect** / **Launch at Login** — preferences (the second requires
  macOS 13+).
- **Quit** (⌘Q) — unmounts cleanly on exit; the same cleanup runs if the process is
  killed (SIGTERM/SIGINT/SIGHUP), so no orphaned mounts are left behind.

(First launch: if Gatekeeper complains because the app is unsigned, right-click the
app → **Open** once.)

Drag files in/out, edit in place, rename, delete — it all writes straight to the device.

## Bulk transfer (fast path for photos & videos)

Finder drag-drop through the mount is fine for a few files, but slow for hundreds —
every file is staged to a temp dir and copied twice through the NFS layer. For bulk
media, use **Send Finder Selection (fast)** in the menu, which bypasses the mount and
drives `adb pull`/`push` directly. Items are **batched (up to 16 per adb call)**, so
hundreds of files take a handful of connections instead of one process per file. It
**auto-detects direction** from what you have selected in Finder:

- **Phone → Mac**: select photos/videos/folders *inside the mounted phone*, then
  **Send Finder Selection (fast)** → choose a Mac folder. Runs batched `adb pull -a`.
- **Mac → Phone**: select files in *any Mac folder*, then the same menu item → the
  destination picker is **populated with the phone's real top-level folders**
  (Download, DCIM, etc., fetched live over adb). Runs batched `adb push`.

A progress window shows cumulative byte progress (pre-computed up front) with a
Cancel button and a brief "Done" state on success; a notification is posted when the
transfer finishes or fails. Measured ~**60× faster** than dragging the same files
through the mount (60-file test), and 21 mixed-size files (incl. a 10 MB one) copy in
~1.2 s either direction on a Galaxy S24 / emulator.

> First use prompts "DroidMount wants to control Finder" — that's how it reads your
> selection. Approve it once.

## Command-line use (no app)

```
./build.sh
scripts/mount.sh                 # mounts the single attached device at /tmp/DroidMount
scripts/mount.sh <serial> <dir>  # explicit device + mountpoint
# unmount:  umount /tmp/DroidMount
```

## Notes & limits

- **USB only** for now. Wireless ADB (`adb tcpip`) is a small future addition.
- The volume is the phone's **`/sdcard` user storage** (read/write); the rest of the
  device filesystem is not exposed (Android restricts it anyway).
- The *mount* is "browse and edit" grade. For moving lots of photos/videos, use
  **Send Finder Selection (fast)** (see above) — it bypasses the mount via direct adb.
- Unsigned/not notarized — it's a personal build. Distribute = add signing + notarization.

## Layout

```
build.sh                  # build the daemon against FUSE-T
scripts/mount.sh          # CLI mount helper (mounts /sdcard by default)
app/                      # menu-bar app sources + build_app.sh + Info.plist
vendor/adbfs-rootless/    # pinned C++ daemon source (commit 277c088, patched in place)
patches/                  # the full FUSE-T/adbfs patch (create, statfs, rootdir, hybrid reads)
tests/dmtest.swift        # CLI harness that runs the real BulkTransfer engine (see below)
vendor/_adbfs-go-fallback # Plan B: Go adbfs (builds on Go 1.26, runs on macFUSE)
bin/adbfs                 # built daemon
build/DroidMount.app      # built app
```

## Testing

No unit-test framework; verification is live, against a connected device/emulator
(`adb` as ground truth). The menu-bar UI needs a human (notifications, Finder
panels), but the transfer engine is directly testable headless:

```
T=$(mktemp -d)
cp app/Sources/BulkTransfer.swift app/Sources/MountController.swift $T/
cp tests/dmtest.swift $T/main.swift        # must be named main.swift to compile
swiftc -O -framework AppKit -o $T/dmtest $T/*.swift
$T/dmtest <serial> phoneToMac <macDestDir> <devicePaths...>
$T/dmtest <serial> macToPhone <deviceDestDir> <localPaths...>
```

It prints cumulative progress and exits non-zero on failure. Good checks: flat files
in both directions (byte-compare with `cmp`), a directory (lands under its own name,
Finder semantics), and a missing path (clean error naming the failing batch).

## Plan B

If a FUSE-T update ever breaks the C++ daemon, `vendor/_adbfs-go-fallback` is the Go
`zach-klippenstein/adbfs` (already builds on Go 1.26). It needs **macFUSE** instead of
FUSE-T (kernel extension, with a `--no-readonly` flag to enable writes).
