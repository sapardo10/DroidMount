#!/usr/bin/env bash
# Mount an Android device (over ADB, via FUSE-T) at a mountpoint.
# Read/write by default — this is the whole point (MacDroid charges for this).
#
# Usage: scripts/mount.sh [<serial>] [<mountpoint>]
#   serial      adb device serial (default: the only attached device)
#   mountpoint  where to mount (default: /tmp/DroidMount)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADBFS="$ROOT/bin/adbfs"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PLATFORM_TOOLS="$(dirname "$ADB")"

[ -x "$ADBFS" ] || { echo "Daemon not built. Run ./build.sh first." >&2; exit 1; }
[ -x "$ADB" ]   || { echo "adb not found at $ADB (set ADB=...)." >&2; exit 1; }

SERIAL="${1:-}"
MOUNT="${2:-/tmp/DroidMount}"

# Resolve the serial if not given: require exactly one device.
if [ -z "$SERIAL" ]; then
  mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  if [ "${#DEVS[@]}" -eq 0 ]; then
    echo "No device. Enable USB Debugging and accept the RSA prompt." >&2; exit 1
  elif [ "${#DEVS[@]}" -gt 1 ]; then
    echo "Multiple devices; pass a serial. Attached:" >&2
    printf '  %s\n' "${DEVS[@]}" >&2; exit 1
  fi
  SERIAL="${DEVS[0]}"
fi

mkdir -p "$MOUNT"
echo "Mounting $SERIAL at $MOUNT (read/write) ..."

# ANDROID_SERIAL pins every bare `adb` call inside the daemon to this device.
# PATH ensures the daemon (which popen's `adb ...`) finds adb.
# -f keeps it in the foreground so the controlling app can supervise it.
export ANDROID_SERIAL="$SERIAL"
export PATH="$PLATFORM_TOOLS:$PATH"
exec "$ADBFS" -f "$MOUNT"
