#requires -Version 5.1
<#
.SYNOPSIS
  One double-click: install a Preflight mod stack (frameworks from GitHub, Nexus downloads queued).

.DESCRIPTION
  Runs three steps and stops at the first one that fails:
    1. `preflight stack plan`  - count the Nexus clicks and refuse a stack that does not fit the
                                 installed game build (exit 3 = blocked).
    2. `preflight install core --apply` - download, sha256-verify and install the frameworks from
                                 GitHub as one undoable transaction (0 Nexus clicks).
    3. `preflight stack run`   - open the next Nexus file page, wait for the download to land in
                                 Vortex's downloads folder, then open the next one.

  Nexus allows one website click per file for a free account, so a stack cannot be one click end to
  end. This gets it to "click Mod manager download on each page it opens for you, hands free".

.EXAMPLE
  .\install-stack.ps1
  .\install-stack.ps1 -Stack stacks\core-2.5.yaml -PlanOnly
#>
[CmdletBinding()]
param(
  [string]$Stack,
  [string]$Game,
  [string]$Downloads,
  [string]$Preflight,
  [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'

function Find-Preflight {
  if ($Preflight) { return (Resolve-Path -LiteralPath $Preflight).Path }
  foreach ($candidate in @(
      (Join-Path $PSScriptRoot 'preflight.exe'),
      (Join-Path $PSScriptRoot '..\preflight\target\release\preflight.exe'),
      (Join-Path $PSScriptRoot '..\preflight\target\debug\preflight.exe')
    )) {
    if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
  }
  $onPath = Get-Command preflight -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  throw "preflight.exe not found. Put it next to this script, or pass -Preflight <path>."
}

function Find-Game {
  param([string]$Given)
  if ($Given) { return (Resolve-Path -LiteralPath $Given).Path }
  if ($env:PREFLIGHT_GAME) { return (Resolve-Path -LiteralPath $env:PREFLIGHT_GAME).Path }
  foreach ($candidate in @(
      'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077',
      'C:\Program Files\Steam\steamapps\common\Cyberpunk 2077',
      'C:\GOG Games\Cyberpunk 2077',
      'D:\SteamLibrary\steamapps\common\Cyberpunk 2077'
    )) {
    if (Test-Path -LiteralPath (Join-Path $candidate 'bin\x64\Cyberpunk2077.exe')) { return $candidate }
  }
  $answer = Read-Host 'Game folder (the one containing bin\x64)'
  return (Resolve-Path -LiteralPath $answer).Path
}

function Find-Stack {
  param([string]$Given)
  if ($Given) { return (Resolve-Path -LiteralPath $Given).Path }
  $stacks = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'stacks') -Filter '*.yaml' -File |
    Where-Object { $_.Name -notlike '*.example.yaml' } | Sort-Object Name
  if (-not $stacks) { throw "no stack files in $(Join-Path $PSScriptRoot 'stacks')" }
  if ($stacks.Count -eq 1) { return $stacks[0].FullName }
  Write-Host 'Stacks:'
  for ($i = 0; $i -lt $stacks.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $stacks[$i].Name) }
  $choice = Read-Host "Pick one [1]"
  if (-not $choice) { $choice = '1' }
  $index = [int]$choice - 1
  if ($index -lt 0 -or $index -ge $stacks.Count) { throw "no stack $choice" }
  return $stacks[$index].FullName
}

function Find-Downloads {
  param([string]$Given)
  if ($Given) { return (Resolve-Path -LiteralPath $Given).Path }
  $vortex = Join-Path $env:APPDATA 'Vortex\downloads\cyberpunk2077'
  if (Test-Path -LiteralPath $vortex) { return $vortex }
  if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Vortex')) {
    Write-Warning "Vortex exists but $vortex does not; watching your Downloads folder instead."
  }
  return (Join-Path $env:USERPROFILE 'Downloads')
}

# Use a locally built rules bundle when the project ships one; otherwise rely on the state dir.
$rulesArgs = @()
$localRules = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\preflight-rules\dist') -Filter 'rules-*.json' -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime | Select-Object -Last 1
if ($localRules -and (Test-Path -LiteralPath "$($localRules.FullName).sig")) {
  $rulesArgs = @('--rules', $localRules.FullName)
}

$preflight = Find-Preflight
$game = Find-Game $Game
$stackFile = Find-Stack $Stack
$downloads = Find-Downloads $Downloads

Write-Host ''
Write-Host "preflight : $preflight"
Write-Host "game      : $game"
Write-Host "stack     : $stackFile"
Write-Host "downloads : $downloads"
Write-Host ''

& $preflight stack plan $stackFile --game $game @rulesArgs
if ($LASTEXITCODE -eq 3) {
  Write-Host ''
  Write-Host 'This stack does not fit the installed build (see BLOCKED above). Nothing was changed.'
  exit 3
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($PlanOnly) { exit 0 }

Write-Host ''
Write-Host 'Installing the public frameworks (0 Nexus clicks, undoable)...'
& $preflight install core --game $game @rulesArgs --apply
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Framework install failed; stopping before the Nexus queue.'
  exit $LASTEXITCODE
}

Write-Host ''
Write-Host 'Walk the Nexus queue: each page opens once, click "Mod manager download", the next page opens when the file lands.'
& $preflight stack run $stackFile --downloads $downloads
exit $LASTEXITCODE
