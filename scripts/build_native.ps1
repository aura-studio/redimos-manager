# Builds the Go core as a Windows c-shared library (redimos_core.dll) and copies
# it next to the app executable so dart:ffi can load it.
#
# There is no native gcc/mingw on this machine, so the build is cross-compiled
# inside a golang container with mingw-w64. Requires Docker Desktop.
#
#   powershell -ExecutionPolicy Bypass -File scripts\build_native.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$native = Join-Path $root "native"

Write-Host "==> building redimos_core.dll (docker + mingw)..."
docker run --rm -v "${native}:/w" -w /w golang:1.25 sh -c @'
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gcc-mingw-w64-x86-64 >/dev/null 2>&1
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc GOTOOLCHAIN=local \
  go build -buildmode=c-shared -o redimos_core.dll .
ls -la redimos_core.dll
'@
if ($LASTEXITCODE -ne 0) { throw "native build failed" }

$dll = Join-Path $native "redimos_core.dll"
Copy-Item $dll (Join-Path $root "redimos_core.dll") -Force
Write-Host "==> copied to project root"

# Copy beside any already-built Flutter runner so `flutter run` / a built app can load it.
foreach ($cfg in @("Debug", "Release", "Profile")) {
  $dst = Join-Path $root "build\windows\x64\runner\$cfg"
  if (Test-Path $dst) {
    Copy-Item $dll (Join-Path $dst "redimos_core.dll") -Force
    Write-Host "==> copied to $dst"
  }
}
Write-Host "done."
