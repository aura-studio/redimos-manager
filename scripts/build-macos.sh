#!/usr/bin/env bash
# Build the macOS app end to end: Go core dylib + the rm-janitor lifeline helper,
# then the Flutter .app, then bundle the two native artifacts into it and
# re-sign (post-build bundle edits break the seal otherwise).
#
# The janitor MUST be bundled alongside the dylib — without it the SIGKILL-proof
# child cleanup (P3) silently degrades to the boot-sweep backstop. janitorBinary()
# looks for it next to the dylib (Contents/MacOS) or the executable.
set -euo pipefail
cd "$(dirname "$0")/.."

export GOTOOLCHAIN=local

echo "==> Go core dylib"
( cd native && CGO_ENABLED=1 go build -buildmode=c-shared -o redimos_core.dylib . )

echo "==> rm-janitor helper"
( cd native && go build -o rm-janitor ./janitor )

echo "==> flutter build macos --release"
flutter build macos --release

APP="build/macos/Build/Products/Release/redimos_manager.app"
echo "==> bundle native artifacts into $APP"
cp native/redimos_core.dylib "$APP/Contents/MacOS/redimos_core.dylib"
cp native/rm-janitor        "$APP/Contents/MacOS/rm-janitor"

echo "==> re-sign"
codesign --force --deep --sign - "$APP"

echo "done: $APP"
