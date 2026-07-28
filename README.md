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
  `patches/adbfs-rootless-fuse-t.patch` adding the `create` handler FUSE-T's NFS
  backend requires, and a `statfs` handler so the volume reports `/sdcard`'s real free
  space — without it Finder refuses to copy files *into* the phone). Read/write by default.
- **FUSE-T** — kext-less FUSE for macOS. No Recovery-mode security downgrade, no reboot.
- **DroidMount.app** — an `NSStatusItem` agent (no Dock icon) that detects devices,
  mounts/unmounts, and reveals the volume in Finder.

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

A phone icon appears in the menu bar. Click it:
- **Mount “<device>”** — mounts the phone read/write and opens it in Finder.
- **Open … in Finder** / **Unmount** — once mounted.
- **Quit** — unmounts cleanly on exit.

(First launch: if Gatekeeper complains because the app is unsigned, right-click the
app → **Open** once.)

Drag files in/out, edit in place, rename, delete — it all writes straight to the device.

## Bulk transfer (fast path for photos & videos)

Finder drag-drop through the mount is fine for a few files, but slow for hundreds —
every file is staged to a temp dir and copied twice through the NFS layer. For bulk
media, use **Send Finder Selection (fast)** in the menu, which bypasses the mount and
drives `adb pull`/`push` directly (one connection, no per-file overhead). It
**auto-detects direction** from what you have selected in Finder:

- **Phone → Mac**: select photos/videos/folders *inside the mounted phone*, then
  **Send Finder Selection (fast)** → choose a Mac folder. Runs `adb pull -a`.
- **Mac → Phone**: select files in *any Mac folder*, then the same menu item →
  pick/type a device folder (presets: Download, DCIM/Camera, Movies, Pictures). Runs `adb push`.

A progress window shows item-by-item progress with a Cancel button. Measured ~**60×
faster** than dragging the same files through the mount (60-file test).

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
- Mounts the device root; the writable area is `/sdcard` (Android restricts the rest).
- The *mount* is "browse and edit" grade. For moving lots of photos/videos, use
  **Send Finder Selection (fast)** (see above) — it bypasses the mount via direct adb.
- Unsigned/not notarized — it's a personal build. Distribute = add signing + notarization.

## Layout

```
build.sh                  # build the daemon against FUSE-T
scripts/mount.sh          # CLI mount helper
app/                      # menu-bar app sources + build_app.sh + Info.plist
vendor/adbfs-rootless/    # pinned C++ daemon source (commit 277c088) + create patch
patches/                  # the FUSE-T create-handler patch
vendor/_adbfs-go-fallback # Plan B: Go adbfs (builds on Go 1.26, runs on macFUSE)
bin/adbfs                 # built daemon
build/DroidMount.app      # built app
```

## Plan B

If a FUSE-T update ever breaks the C++ daemon, `vendor/_adbfs-go-fallback` is the Go
`zach-klippenstein/adbfs` (already builds on Go 1.26). It needs **macFUSE** instead of
FUSE-T (kernel extension, with a `--no-readonly` flag to enable writes).
