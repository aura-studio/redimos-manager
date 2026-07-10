#!/usr/bin/env bash
# Package the full macOS suite into a distributable DMG:
#
#   Redimos Manager.app    Flutter app + redimos_core.dylib + rm-janitor
#                          (built by scripts/build-macos.sh, ad-hoc signed)
#   bin/redimos-v1         redimos server, redimo v1 line (darwin/amd64)
#   bin/redimos-v2         redimos server, redimo v2 line (darwin/amd64)
#   README.txt             first-run notes (Gatekeeper + Settings paths)
#
#   scripts/package-macos.sh   →  dist/redimos-manager-<ver>-macos-x64.dmg
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

echo "==> stage dist/$PKG"
STAGE="dist/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
# ditto preserves xattrs/signature metadata that cp -R can drop.
ditto "build/macos/Build/Products/Release/redimos_manager.app" "$STAGE/Redimos Manager.app"
cp bin/redimos-v1 bin/redimos-v2 "$STAGE/bin/"

cat > "$STAGE/README.txt" <<EOF
Redimos Manager $VER (macos-x64)
=================================

Contents
  Redimos Manager.app   the manager UI
  bin/redimos-v1        redimos server, redimo v1 line
  bin/redimos-v2        redimos server, redimo v2 line

First run
  1. This build is ad-hoc signed (not notarized), so macOS quarantines the
     download. Clear it once:
         xattr -dr com.apple.quarantine "Redimos Manager.app"
     (or right-click the app -> Open -> Open.)
  2. Move the app anywhere you like (e.g. /Applications) and keep the bin/
     folder somewhere stable (e.g. ~/redimos/bin).
  3. Launch the app, open Settings (gear icon), and point the v1 / v2 binary
     paths at bin/redimos-v1 and bin/redimos-v2.
  4. Create a config, hit the play button, connect any Redis client to the port.

Notes
  - v1 tables use String (S) pk/sk keys; v2 tables use Binary (B) keys - use a
    separate DynamoDB table per version.
EOF

echo "==> dmg"
rm -f "dist/$PKG.dmg"
hdiutil create -volname "Redimos Manager" -srcfolder "$STAGE" -ov -format UDZO "dist/$PKG.dmg" >/dev/null
ls -la "dist/$PKG.dmg"
echo "done: dist/$PKG.dmg"
