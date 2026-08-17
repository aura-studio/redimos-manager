#!/usr/bin/env bash
# Package the macOS suite into a single drag-to-install DMG:
#
#   Redimos Manager.app    self-contained bundle:
#                            Flutter app + redimos_core.dylib + rm-janitor
#                            (built by scripts/build-macos.sh, ad-hoc signed)
#                          + Contents/MacOS/bin/redimos-v1  (redimo v1 line)
#                          + Contents/MacOS/bin/redimos-v2  (redimo v2 line)
#   Applications -> /Applications   drag target
#   README.txt             first-run notes (Gatekeeper + Settings paths)
#
#   scripts/package-macos.sh   →  dist/redimos-manager-<ver>-macos-x64.dmg
#
# The server binaries live INSIDE the .app at Contents/MacOS/bin/, which is
# exactly where binaryFor()'s bundled auto-detect looks (bin/ next to the
# executable) — so the dragged-in app runs either server line with zero
# Settings setup, and there is no loose bin/ folder to lose.
#
# The build is ad-hoc signed, NOT notarized — the README tells users to clear
# quarantine once (xattr -dr com.apple.quarantine) or right-click → Open.
set -euo pipefail
cd "$(dirname "$0")/.."
export GOTOOLCHAIN=local

VER=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml | head -1)
PKG="redimos-manager-${VER}-macos-x64"

echo "==> app (scripts/build-macos.sh)"
bash scripts/build-macos.sh

# Same repo layout convention as build-windows-prep.sh:
#   v1 line = ../redimos-v1-wt (worktree pinned to the v1 tag line)
#   v2 line = ../redimos       (main repo, branch v2)
V1_REPO=${V1_REPO:-../redimos-v1-wt}
V2_REPO=${V2_REPO:-../redimos}
mkdir -p bin
echo "==> redimos-v1 / redimos-v2 (darwin/amd64)"
( cd "$V1_REPO" && CGO_ENABLED=0 go build -o "$OLDPWD/bin/redimos-v1" ./cmd/redimos )
( cd "$V2_REPO" && CGO_ENABLED=0 go build -o "$OLDPWD/bin/redimos-v2" ./cmd/redimos )

APP="build/macos/Build/Products/Release/redimos_manager.app"
echo "==> embed servers into $APP/Contents/MacOS/bin"
mkdir -p "$APP/Contents/MacOS/bin"
cp bin/redimos-v1 bin/redimos-v2 "$APP/Contents/MacOS/bin/"

echo "==> re-sign (post-build bundle edits break the seal otherwise)"
codesign --force --deep --sign - "$APP"

echo "==> stage dist/$PKG"
STAGE="dist/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# ditto preserves xattrs/signature metadata that cp -R can drop.
ditto "$APP" "$STAGE/Redimos Manager.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
Redimos Manager $VER (macos-x64)
=================================

Install
  Drag "Redimos Manager.app" onto the Applications folder. Done — the app is
  self-contained: both redimos server lines (v1 and v2) are embedded inside
  the bundle and auto-detected, no Settings path entry needed.

First run
  1. This build is ad-hoc signed (not notarized), so macOS quarantines the
     download. Clear it once:
         xattr -dr com.apple.quarantine "/Applications/Redimos Manager.app"
     (or right-click the app -> Open -> Open.)
  2. Create a config, hit the play button, connect any Redis client to the port.
  3. Optional: to run your OWN server binaries instead of the embedded ones,
     open Settings and point the v1 / v2 binary paths at them.

Notes
  - v1 tables use String (S) pk/sk keys; v2 tables use Binary (B) keys - use a
    separate DynamoDB table per version.
EOF

echo "==> dmg"
rm -f "dist/$PKG.dmg"
hdiutil create -volname "Redimos Manager" -srcfolder "$STAGE" -ov -format UDZO "dist/$PKG.dmg" >/dev/null
ls -la "dist/$PKG.dmg"
echo "done: dist/$PKG.dmg"
