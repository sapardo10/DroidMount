#!/usr/bin/env bash
# Local CI for DroidMount. Run on the committed head. Mirrors .github/workflows/release.yml build steps plus a compile of the headless harness; needs FUSE-T and pkg-config. No unit tests exist.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
echo "Local CI on $(git rev-parse --short HEAD)"
[ -z "$(git status --porcelain)" ] || { echo "Uncommitted changes: commit first"; exit 1; }
./build.sh
./app/build_app.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp app/Sources/BulkTransfer.swift app/Sources/MountController.swift "$T/"
cp tests/dmtest.swift "$T/main.swift"
swiftc -O -framework AppKit -o "$T/dmtest" "$T"/*.swift
echo "Local CI: PASS"
