# profile-loader.ps1
# Drop this into your PowerShell profile to wire up the Hermes bridge lifecycle.
# Usage in $PROFILE: . C:\Users\zerop\Development\hermes-bridge-tools\profile-loader.ps1

# Enable background subagents for oh-my-opencode-slim orchestration
$env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"

# Import bridge management module
$modulePath = Join-Path $PSScriptRoot 'HermesBridge.psd1'
try {
  Import-Module $modulePath -Force -ErrorAction Stop
} catch {
  Write-Warning "[hermes] Failed to load module from $modulePath : $_"
  Write-Warning "[hermes] Bridge auto-start disabled"
  return
}

# Resolve opencode path once at profile load
$script:OpenCodePath = Get-OpenCodePath
if (-not $script:OpenCodePath) {
  Write-Warning "[hermes] opencode executable not found — opencode wrapper disabled"
}

# Override opencode to manage bridge lifecycle
function global:opencode {
  if (-not $script:OpenCodePath) {
    Write-Error "opencode not found on this system"
    return
  }
  Start-HermesBridge
  $start = Get-Date
  try {
    & $script:OpenCodePath @args
  } finally {
    $duration = [math]::Round(((Get-Date) - $start).TotalSeconds)
    Stop-HermesBridge -SessionDuration $duration
  }
}
