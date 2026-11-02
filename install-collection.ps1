#requires -Version 5.1
<#
.SYNOPSIS
  One double-click: hand a Nexus mod collection to Vortex for Cyberpunk 2077.

.DESCRIPTION
  Takes a Nexus collection page URL (or bare collection slug) and launches:

      Vortex.exe --game cyberpunk2077 --install "nxm://cyberpunk2077/collections/<slug>/revisions/latest" --start-minimized

  Vortex's own CLI consumes the URL (verified in Vortex 2.9.1: --install is
  consumed on cold start, and a second Vortex.exe launch forwards the same
  arguments to the running instance). No addon, no preflight.exe, no Nexus
  API calls from this script - the nxm URL goes through Vortex's pipeline.

  Behaviour depends on the account logged into Vortex:
    - premium: one click in Vortex and the whole collection is queued.
    - free:    Vortex queues each file behind one website click (Nexus ToS).

.EXAMPLE
  .\install-collection.ps1 https://www.nexusmods.com/cyberpunk2077/collections/abc123
  .\install-collection.ps1 abc123
  .\install-collection.ps1                       # prompts for the URL
  .\install-collection.ps1 -Test                 # run the parsing check, no Vortex
#>
[CmdletBinding()]
param(
  [string]$Collection,
  [string]$VortexExe,
  [switch]$Test
)

$ErrorActionPreference = 'Stop'

function Get-NxmCollectionUrl {
  # ponytail: $Input is an automatic pipeline var, so the param is named $SlugInput
  param([string]$SlugInput)
  $in = $SlugInput.Trim()
  if ($in -match 'nxm://[^/]*/collections/([A-Za-z0-9_-]+)') {
    $slug = $Matches[1]
  } elseif ($in -match 'collections/([A-Za-z0-9_-]+)') {
    $slug = $Matches[1]
  } elseif ($in -match '^[A-Za-z0-9_-]+$') {
    $slug = $in
  } else {
    throw "no collection slug in '$in' - expected a collections page URL or a bare slug"
  }
  return "nxm://cyberpunk2077/collections/$slug/revisions/latest"
}

function Find-Vortex {
  if ($VortexExe) { return (Resolve-Path -LiteralPath $VortexExe).Path }
  if ($env:VORTEX_EXE) { return (Resolve-Path -LiteralPath $env:VORTEX_EXE).Path }
  foreach ($candidate in @(
      'C:\Program Files\Vortex\Vortex.exe',
      'C:\Program Files (x86)\Vortex\Vortex.exe',
      (Join-Path $env:LOCALAPPDATA 'Programs\Vortex\Vortex.exe')
    )) {
    if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
  }
  # Start-menu shortcuts point at any custom install location
  $lnk = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Vortex.lnk',
           (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Vortex.lnk')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($lnk) {
    $ws = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $target = (Split-Path -Parent $ws.TargetPath)
    $exe = Join-Path $target 'Vortex.exe'
    if (Test-Path -LiteralPath $exe) { return (Resolve-Path -LiteralPath $exe).Path }
  }
  $answer = Read-Host 'Path to Vortex.exe'
  return (Resolve-Path -LiteralPath $answer).Path
}

# ---- parsing check (one runnable check for this script) ----
if ($Test) {
  $cases = @(
    @('https://www.nexusmods.com/cyberpunk2077/collections/abc123', 'abc123'),
    @('https://www.nexusmods.com/games/cyberpunk2077/collections/abc123', 'abc123'),
    @('https://www.nexusmods.com/cyberpunk2077/collections/abc123?mtm_source=nexusmodsapp', 'abc123'),
    @('nxm://cyberpunk2077/collections/abc123/revisions/latest', 'abc123'),
    @('  abc123  ', 'abc123')
  )
  $fail = 0
  foreach ($c in $cases) {
    $url = Get-NxmCollectionUrl $c[0]
    if ($url -ne "nxm://cyberpunk2077/collections/$($c[1])/revisions/latest") {
      Write-Host "FAIL: $($c[0]) -> $url"
      $script:fail = 1
    } else {
      Write-Host "ok:   $($c[0]) -> $url"
    }
  }
  try {
    Get-NxmCollectionUrl 'https://www.nexusmods.com/cyberpunk2077/mods/12345' | Out-Null
    Write-Host 'FAIL: mod URL accepted'
    $fail = 1
  } catch {
    Write-Host 'ok:   mod URL rejected'
  }
  if ($fail) { exit 1 }
  Write-Host 'all checks passed'
  exit 0
}

# ---- main path ----
if (-not $Collection) { $Collection = Read-Host 'Nexus collection URL or slug' }
$nxm = Get-NxmCollectionUrl $Collection
$exe = Find-Vortex

Write-Host "using Vortex:   $exe"
Write-Host "installing:     $nxm"
Write-Host 'Vortex will open minimized. Premium = one click in Vortex; free = one website click per file.'
Start-Process -LiteralPath $exe -ArgumentList '--game', 'cyberpunk2077', '--install', $nxm, '--start-minimized'
