<#
.SYNOPSIS
  Build the two redimos Docker run-mode images (redimos-v1:local /
  redimos-v2:local) the manager launches when a config's Run mode = Docker.

.DESCRIPTION
  The manager does NOT build these itself (locked design decision). Run this
  once on the machine whose Docker daemon the manager uses, and again whenever
  you bump a redimos version. Each context directory must contain a Dockerfile.

.PARAMETER V1Context
  Path to the redimos v1 source (redimo v1 line). Defaults to a sibling checkout.

.PARAMETER V2Context
  Path to the redimos v2 source (default line). Defaults to a sibling checkout.

.EXAMPLE
  scripts\build-images.ps1
  scripts\build-images.ps1 -V1Context ..\redimos-v1 -V2Context ..\redimos
#>
param(
  [string]$V1Context = "",
  [string]$V2Context = ""
)
$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $PSScriptRoot
$parent = Split-Path -Parent $here

function Pick([string[]]$candidates) {
  foreach ($d in $candidates) { if (Test-Path (Join-Path $d "Dockerfile")) { return $d } }
  return ""
}

if (-not $V1Context) { $V1Context = Pick @("$parent\redimos-v1-wt", "$parent\redimos-v1") }
if (-not $V2Context) { $V2Context = Pick @("$parent\redimos", "$parent\redimos-v2-wt", "$parent\redimos-v2") }

$fail = $false
if (-not $V1Context -or -not (Test-Path (Join-Path $V1Context "Dockerfile"))) {
  Write-Host "!! v1 context not found (pass -V1Context; needs a Dockerfile)"; $fail = $true
}
if (-not $V2Context -or -not (Test-Path (Join-Path $V2Context "Dockerfile"))) {
  Write-Host "!! v2 context not found (pass -V2Context; needs a Dockerfile)"; $fail = $true
}
if ($fail) { exit 1 }

Write-Host "==> building redimos-v1:local  (context: $V1Context)"
docker build -t redimos-v1:local $V1Context
Write-Host "==> building redimos-v2:local  (context: $V2Context)"
docker build -t redimos-v2:local $V2Context

Write-Host ""
Write-Host "done. images:"
docker images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" | Select-String "redimos-v[12]:local"
Write-Host "Set custom image names in the app's Settings if you tag them differently."
