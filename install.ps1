#Requires -Version 7.0
<#
.SYNOPSIS
  Installs OpenCode Bridge Tools into your PowerShell profile.
.DESCRIPTION
  Adds a dot-source line to $PROFILE so the opencode wrapper is
  loaded automatically in every new PowerShell session.
  Backs up your existing profile before modifying.
.EXAMPLE
  pwsh -NoProfile -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

$moduleDir = $PSScriptRoot
$profilePath = $PROFILE
$loaderLine = ". $moduleDir\profile-loader.ps1"
$marker = '# OpenCode Bridge — auto-managed wrapper'

Write-Host "OpenCode Bridge Tools — Installer" -ForegroundColor Cyan
Write-Host "  Module:   $moduleDir"
Write-Host "  Profile:  $profilePath"

# --- Validate ---
if (-not $profilePath) { Write-Error '$PROFILE is not defined. Ensure you have a PowerShell profile path.'; exit 1 }
if (-not (Test-Path "$moduleDir\profile-loader.ps1")) { Write-Error "profile-loader.ps1 not found in $moduleDir"; exit 1 }

# --- Backup existing profile ---
if (Test-Path $profilePath) {
  $bak = "$profilePath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $profilePath -Destination $bak -Force
  Write-Host "  Backup:   $bak"
}

# --- Check if already installed ---
if (Test-Path $profilePath) {
  $existing = Get-Content $profilePath -Raw
  if ($existing -match [regex]::Escape($loaderLine)) {
    Write-Host "  Status:   Already installed (loader line exists in profile)" -ForegroundColor Yellow
    Write-Host "  Tip:      Remove the line starting with '. $moduleDir' to uninstall."
    exit 0
  }
}

# --- Install ---
$block = @"

$marker
$loaderLine
"@

if (Test-Path $profilePath) {
  Add-Content -LiteralPath $profilePath -Value "`r`n$block"
} else {
  # Ensure parent directory exists
  $parentDir = Split-Path $profilePath -Parent
  if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
  Set-Content -LiteralPath $profilePath -Value $block
}

Write-Host "  Action:   Added loader line to profile" -ForegroundColor Green
Write-Host "`nInstall complete. Open a NEW PowerShell terminal or run: . `$PROFILE" -ForegroundColor Green
