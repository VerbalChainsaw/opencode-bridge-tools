# profile-loader.ps1
# Drop this into your PowerShell profile to wire up the Hermes bridge lifecycle.
# Usage in $PROFILE: . C:\Users\zerop\Development\hermes-bridge-tools\profile-loader.ps1

# Enable background subagents for oh-my-opencode-slim orchestration
$env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"

# Import bridge management module
$modulePath = Join-Path $PSScriptRoot 'HermesBridge.psd1'
if (Test-Path $modulePath) {
  Import-Module $modulePath -Force -ErrorAction Stop
} else {
  Write-Warning "[hermes] Module not found at $modulePath — bridge auto-start disabled"
}

# Override opencode to manage bridge lifecycle
function global:opencode {
  Start-HermesBridge
  $start = Get-Date
  try {
    & "C:\Program Files\nodejs\opencode.cmd" @args
  } finally {
    $script:SessionDuration = [math]::Round(((Get-Date) - $start).TotalSeconds)
    Stop-HermesBridge
  }
}
