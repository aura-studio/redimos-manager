# Compile the Inno Setup installer AFTER `build.cmd -SkipDll` has produced the
# Flutter Release folder. Requires Inno Setup 6.3+ (https://jrsoftware.org/isdl.php).
#
#   powershell -ExecutionPolicy Bypass -File scripts\build-installer.ps1
#   → dist\redimos-manager-<ver>-setup-x64.exe
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$rel = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $rel 'redimos_manager.exe'))) {
    throw "Release build missing — run build.cmd -SkipDll first."
}
if (-not (Test-Path (Join-Path $rel 'redimos_core.dll'))) {
    throw "redimos_core.dll missing next to the exe — run build.cmd -SkipDll first."
}
foreach ($s in 'redimos-v1.exe', 'redimos-v2.exe') {
    if (-not (Test-Path (Join-Path $root "bin\$s"))) {
        throw "bin\$s missing — prep it on the Mac with scripts/build-windows-prep.sh."
    }
}

$line = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^\s*version:\s*(\S+)' | Select-Object -First 1
$ver = ($line.Matches[0].Groups[1].Value -split '\+')[0]

$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                     "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
        if ($p -and (Test-Path $p)) { $iscc = $p; break }
    }
}
if (-not $iscc) { throw "ISCC.exe not found — install Inno Setup 6: https://jrsoftware.org/isdl.php" }

Write-Host "==> ISCC $iscc  (version $ver)"
& $iscc "/DAppVersion=$ver" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with code $LASTEXITCODE" }
Write-Host "installer -> dist\redimos-manager-$ver-setup-x64.exe" -ForegroundColor Green
