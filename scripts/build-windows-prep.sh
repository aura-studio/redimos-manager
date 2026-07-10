#!/usr/bin/env bash
# Mac-side prep for the Windows package: cross-compile the three Go artifacts
# (redimos_core.dll + redimos-v1.exe + redimos-v2.exe) here on macOS so the
# Parallels/Windows VM only needs Flutter + Visual Studio — no Docker, no Go,
# no mingw inside the VM.
#
#   scripts/build-windows-prep.sh
#     → native/redimos_core.dll   (cgo c-shared, x86_64-w64-mingw32-gcc)
#     → bin/redimos-v1.exe        (from $V1_REPO, default ../redimos-v1-wt, pure Go)
#     → bin/redimos-v2.exe        (from $V2_REPO, default ../redimos,       pure Go)
#
# These are gitignored — they travel to the VM via the Parallels shared folder
# (\\Mac\Home\...), not via git. Then, inside the VM, with the repo copied to a
# LOCAL disk (never build on the \\Mac share):
#
#   build.cmd -SkipDll     → dist\redimos-manager-<ver>-windows-x64.zip
set -euo pipefail
cd "$(dirname "$0")/.."
export GOTOOLCHAIN=local

command -v x86_64-w64-mingw32-gcc >/dev/null \
  || { echo "x86_64-w64-mingw32-gcc not found — brew install mingw-w64"; exit 1; }

echo "==> redimos_core.dll (GOOS=windows cgo c-shared)"
( cd native && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc \
    go build -buildmode=c-shared -o redimos_core.dll . )

# NOTE the repo layout on this Mac differs from the old Windows box:
#   v1 line = ../redimos-v1-wt (worktree pinned to the v1 tag line)
#   v2 line = ../redimos       (main repo, branch v2)
V1_REPO=${V1_REPO:-../redimos-v1-wt}
V2_REPO=${V2_REPO:-../redimos}
mkdir -p bin

echo "==> redimos-v1.exe  ($V1_REPO)"
( cd "$V1_REPO" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
    go build -o "$OLDPWD/bin/redimos-v1.exe" ./cmd/redimos )

echo "==> redimos-v2.exe  ($V2_REPO)"
( cd "$V2_REPO" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
    go build -o "$OLDPWD/bin/redimos-v2.exe" ./cmd/redimos )

echo "done:"
ls -la native/redimos_core.dll bin/redimos-v1.exe bin/redimos-v2.exe
