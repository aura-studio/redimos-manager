<#
.SYNOPSIS
    Build redimos-manager into a single, self-contained distributable ZIP.

.DESCRIPTION
    Produces  dist\redimos-manager-<version>-windows-x64.zip  bundling the three
    parts of the project:

        1. Redimos Manager desktop app  (redimos_manager.exe + Flutter runtime + redimos_core.dll)
        2. redimos-v1.exe               (redimos server - redimo v1 line)
        3. redimos-v2.exe               (redimos server - redimo v2 line)

    Double-click  build.cmd  in the project root to run this with sensible
    defaults, or invoke this script directly for more control.

.PARAMETER Version
    Version string for the package name. Defaults to the `version:` in pubspec.yaml.

.PARAMETER RebuildServers
    Also rebuild redimos-v1.exe / redimos-v2.exe from the sibling redimos repos
    (see -V1Repo / -V2Repo). Without this flag the existing bin\redimos-v*.exe are
    reused.

.PARAMETER SkipDll
    Reuse the existing native\redimos_core.dll instead of rebuilding it. Use this
    when Docker is unavailable (the DLL is cross-compiled in a golang+mingw image).

.PARAMETER V1Repo
    Path to the redimos repo checked out on the v1 branch (for -RebuildServers).

.PARAMETER V2Repo
    Path to the redimos v2 worktree/repo (for -RebuildServers).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -RebuildServers -Version 0.2.0
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$RebuildServers,
    [switch]$SkipDll,
    [string]$V1Repo,
    [string]$V2Repo
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# --- paths --------------------------------------------------------------------
$root    = Split-Path -Parent $PSScriptRoot          # repo root
$native  = Join-Path $root 'native'
$binDir  = Join-Path $root 'bin'
$relDir  = Join-Path $root 'build\windows\x64\runner\Release'
$distDir = Join-Path $root 'dist'
if (-not $V1Repo) { $V1Repo = Join-Path (Split-Path -Parent $root) 'redimos' }
if (-not $V2Repo) { $V2Repo = Join-Path (Split-Path -Parent $root) 'redimos-v2-wt' }

# --- pretty logging -----------------------------------------------------------
$script:step = 0
function Step($msg) { $script:step++; Write-Host "`n[$($script:step)] $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Die($msg)  { Write-Host "`nBUILD FAILED: $msg" -ForegroundColor Red; exit 1 }

# --- resolve the Flutter SDK --------------------------------------------------
function Resolve-Flutter {
    $c = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $c = Get-Command flutter -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'),
        'C:\flutter\bin\flutter.bat',
        'C:\src\flutter\bin\flutter.bat')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

Write-Host "==================================================" -ForegroundColor White
Write-Host "  redimos-manager  ::  build & package" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor White

# --- version ------------------------------------------------------------------
if (-not $Version) {
    $line = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^\s*version:\s*(\S+)' | Select-Object -First 1
    if ($line) { $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0] }
    if (-not $Version) { $Version = '0.0.0' }
}
$pkgName = "redimos-manager-$Version-windows-x64"
Info "version        : $Version"
Info "package        : $pkgName.zip"
Info "rebuild servers: $RebuildServers"
Info "rebuild dll    : $(-not $SkipDll)"

# =============================================================================
Step "Preflight"
$flutter = Resolve-Flutter
if (-not $flutter) { Die "Flutter SDK not found. Add flutter\bin to PATH or install it." }
Ok "flutter -> $flutter"
if (-not $SkipDll) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die "Docker not found (needed to cross-compile redimos_core.dll). Use -SkipDll to reuse the existing DLL."
    }
    Ok "docker present"
}
if ($RebuildServers) {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Die "Go not found (needed for -RebuildServers)." }
    Ok "go present"
}

# =============================================================================
Step "Part 1a - Go core library (redimos_core.dll)"
if ($SkipDll) {
    if (-not (Test-Path (Join-Path $native 'redimos_core.dll'))) { Die "native\redimos_core.dll missing; run without -SkipDll." }
    Info "reusing existing native\redimos_core.dll"
} else {
    # A cached golang+mingw image so we don't apt-get every build (the apt fetch
    # is slow and flaky). Built once, reused thereafter.
    $img = 'redimos-mingw:local'
    if (-not (docker images -q $img)) {
        Info "building $img (one-time: golang 1.25 + mingw-w64) ..."
        $ctx = Join-Path $env:TEMP 'redimos-mingw-ctx'
        New-Item -ItemType Directory -Force -Path $ctx | Out-Null
        @"
FROM golang:1.25
RUN apt-get update && apt-get install -y gcc-mingw-w64-x86-64 && rm -rf /var/lib/apt/lists/*
"@ | Set-Content -Path (Join-Path $ctx 'Dockerfile') -Encoding ascii
        docker build -t $img $ctx | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "failed to build $img" }
    }
    Info "cross-compiling redimos_core.dll in $img ..."
    docker run --rm -v "${native}:/w" -w /w $img sh -c `
      'GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc GOTOOLCHAIN=local go build -buildmode=c-shared -o redimos_core.dll .'
    if ($LASTEXITCODE -ne 0) { Die "redimos_core.dll build failed." }
}
Copy-Item (Join-Path $native 'redimos_core.dll') (Join-Path $root 'redimos_core.dll') -Force
Ok "redimos_core.dll ready"

# =============================================================================
Step "Part 1b - Flutter Windows app"
Push-Location $root
try {
    & $flutter build windows --release
    if ($LASTEXITCODE -ne 0) { Die "flutter build windows failed." }
} finally { Pop-Location }
if (-not (Test-Path (Join-Path $relDir 'redimos_manager.exe'))) { Die "redimos_manager.exe was not produced." }
# flutter build does not know about the native DLL - drop it next to the exe.
Copy-Item (Join-Path $native 'redimos_core.dll') (Join-Path $relDir 'redimos_core.dll') -Force
# Bundle the VC++ runtime (msvcp140/vcruntime140*) next to the exe so the app
# starts on machines WITHOUT the VC++ redistributable installed
# (flutter_windows.dll depends on them; app-local deployment is MS-sanctioned).
$vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsRoot = if (Test-Path $vswherePath) { & $vswherePath -latest -products * -property installationPath } else { $null }
$crtDir = if ($vsRoot) {
    Get-ChildItem "$vsRoot\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1
} else { $null }
if ($crtDir) {
    foreach ($d in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        Copy-Item (Join-Path $crtDir.FullName $d) $relDir -Force
    }
    Ok "VC++ CRT DLLs bundled (from $($crtDir.FullName))"
} else {
    Write-Host "    WARN  VC++ redist CRT not found - app may fail on machines without vc_redist" -ForegroundColor Yellow
}
Ok "app built -> $relDir"

# =============================================================================
Step "Parts 2 & 3 - redimos server binaries (v1 / v2)"
function Build-Server($label, $repo, $outExe) {
    if (-not (Test-Path (Join-Path $repo 'cmd\redimos'))) { Die "$label repo not found at $repo (pass -${label}Repo)." }
    $branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
    Info "$label : building from $repo (branch $branch)"
    $env:GOTOOLCHAIN = 'local'
    Push-Location $repo
    try {
        & go build -o $outExe ./cmd/redimos
        if ($LASTEXITCODE -ne 0) { Die "$label go build failed." }
    } finally { Pop-Location }
}
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
if ($RebuildServers) {
    Build-Server 'V1' $V1Repo (Join-Path $binDir 'redimos-v1.exe')
    Build-Server 'V2' $V2Repo (Join-Path $binDir 'redimos-v2.exe')
    Ok "rebuilt redimos-v1.exe + redimos-v2.exe"
} else {
    foreach ($s in @('redimos-v1.exe','redimos-v2.exe')) {
        if (-not (Test-Path (Join-Path $binDir $s))) { Die "bin\$s missing. Build it, or re-run with -RebuildServers." }
    }
    Info "reusing existing bin\redimos-v1.exe + bin\redimos-v2.exe (pass -RebuildServers to recompile)"
}
# sanity: the app passes -endpoint-url, so the servers must understand it.
# (redimos prints its usage to stderr; capture via files to avoid PowerShell's
#  native-stderr-to-terminating-error behaviour. Never fails the build.)
foreach ($s in @('redimos-v1.exe','redimos-v2.exe')) {
    $help = ''
    try {
        $eo = [System.IO.Path]::GetTempFileName()
        $so = [System.IO.Path]::GetTempFileName()
        Start-Process -FilePath (Join-Path $binDir $s) -ArgumentList '-help' -NoNewWindow -Wait `
            -RedirectStandardError $eo -RedirectStandardOutput $so | Out-Null
        $help = (Get-Content $eo -Raw -ErrorAction SilentlyContinue) + (Get-Content $so -Raw -ErrorAction SilentlyContinue)
        Remove-Item $eo, $so -Force -ErrorAction SilentlyContinue
    } catch { }
    if ($help -match 'endpoint-url') { Ok "$s exposes -endpoint-url" }
    else { Write-Host "    WARN  bin\$s does not expose -endpoint-url (stale build?)" -ForegroundColor Yellow }
}

# =============================================================================
Step "Stage & zip (single combined package)"
$stageRoot = Join-Path $distDir $pkgName
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

# 1) the app (whole Release folder: exe + data\ + flutter_windows.dll + redimos_core.dll)
Copy-Item (Join-Path $relDir '*') $stageRoot -Recurse -Force
# 2 & 3) the server binaries, under bin\ next to the app
$stageBin = Join-Path $stageRoot 'bin'
New-Item -ItemType Directory -Force -Path $stageBin | Out-Null
Copy-Item (Join-Path $binDir 'redimos-v1.exe') $stageBin -Force
Copy-Item (Join-Path $binDir 'redimos-v2.exe') $stageBin -Force

# a short run note inside the package
$readme = @"
Redimos Manager $Version (windows-x64)
=======================================

Contents
  redimos_manager.exe   the manager UI (double-click to run)
  redimos_core.dll      native core (loaded automatically; keep it next to the .exe)
  data\, *.dll          Flutter runtime (keep alongside the .exe)
  bin\redimos-v1.exe    redimos server, redimo v1 line
  bin\redimos-v2.exe    redimos server, redimo v2 line

First run
  1. Launch redimos_manager.exe.
  2. Open Settings (gear icon) and point the v1 / v2 binary paths at
     bin\redimos-v1.exe and bin\redimos-v2.exe (in this folder).
  3. Create a config, hit the play button, connect any Redis client to the port.

Notes
  - v1 tables use String (S) pk/sk keys; v2 tables use Binary (B) keys - use a
    separate DynamoDB table per version.
"@
[System.IO.File]::WriteAllText((Join-Path $stageRoot 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))

$zipPath = Join-Path $distDir "$pkgName.zip"
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
Ok "zipped -> $zipPath"

# =============================================================================
$sw.Stop()
$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "  BUILD OK  ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  package : $zipPath  (${sizeMb} MB)"
Write-Host "  staged  : $stageRoot"
Write-Host "  parts   : redimos_manager.exe + bin\redimos-v1.exe + bin\redimos-v2.exe"
Write-Host ""
