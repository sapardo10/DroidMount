#!/usr/bin/env bash
# Build the adbfs-rootless daemon against FUSE-T (libfuse 2.x compatible, no kernel extension).
# Output: bin/adbfs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/vendor/adbfs-rootless"
OUT="$ROOT/bin"
mkdir -p "$OUT"

# FUSE-T installs its pkg-config files under /usr/local/lib/pkgconfig.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Pick the right pkg-config module name. FUSE-T ships as "fuse-t" (and usually a
# "fuse" compat alias). macFUSE ships "fuse". Try in order of preference.
PC=""
for cand in fuse-t fuse; do
  if pkg-config --exists "$cand" 2>/dev/null; then PC="$cand"; break; fi
done
if [ -z "$PC" ]; then
  echo "ERROR: no FUSE pkg-config module found (looked for fuse-t, fuse)." >&2
  echo "Is FUSE-T installed?  brew install macos-fuse-t/homebrew-cask/fuse-t" >&2
  echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH" >&2
  exit 1
fi
echo "Using pkg-config module: $PC"
echo "  cflags: $(pkg-config --cflags "$PC")"
echo "  libs:   $(pkg-config --libs "$PC")"

# FUSE_USE_VERSION 26 is set in the source. C++11 is enough for this codebase.
# -D_FILE_OFFSET_BITS=64 is required by libfuse headers (off_t sizing).
set -x
c++ -std=c++11 -Wall -O2 \
  -D_FILE_OFFSET_BITS=64 -D_DARWIN_USE_64_BIT_INODE \
  $(pkg-config --cflags "$PC") \
  -o "$OUT/adbfs" \
  "$SRC/adbfs.cpp" \
  $(pkg-config --libs "$PC")
set +x

echo
echo "Built: $OUT/adbfs"
"$OUT/adbfs" --help 2>&1 | head -5 || true
