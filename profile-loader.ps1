# profile-loader.ps1
# Drop this into your PowerShell profile to wrap the `opencode` CLI so it
# auto-starts and auto-stops the Hermes Nous gateway (the upstream for the
# hermes-nous provider in opencode.jsonc) around each invocation.
#
# Usage in $PROFILE:
#   . C:\Users\zerop\Development\opencode-bridge-tools\profile-loader.ps1

# Enable background subagents for oh-my-opencode-slim orchestration
$env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"

# Import the OpenCode bridge module
$modulePath = Join-Path $PSScriptRoot 'OpenCodeBridge.psd1'
try {
  Import-Module $modulePath -Force -ErrorAction Stop
} catch {
  Write-Warning "[opencode-bridge] Failed to load module from $modulePath : $_"
  Write-Warning "[opencode-bridge] Bridge auto-start disabled"
  return
}

# Resolve opencode path once at profile load
$script:OpenCodePath = Get-OpenCodePath
if (-not $script:OpenCodePath) {
  Write-Warning "[opencode-bridge] opencode executable not found — opencode wrapper disabled"
}

# Subcommands that never call AI models and therefore never need the gateway.
# Matched against $args[0] using -eq (so ''), with a -version/-help flag fallback.
$script:NoBridgeSubcommands = @(
  'completion', 'mcp', 'models', 'providers', 'auth', 'agent',
  'upgrade', 'uninstall', 'debug', 'stats', 'export', 'import',
  'session', 'plugin', 'plug', 'db', 'acp', 'github'
)
$script:NoBridgeFlags = @('--version', '-v', '--help', '-h')

function script:Test-SkipBridge {
  param([object[]]$Arguments)
  if (-not $Arguments -or $Arguments.Count -eq 0) { return $false }   # bare `opencode` = TUI = needs bridge
  $first = [string]$Arguments[0]
  if ($first -in $script:NoBridgeFlags) { return $true }
  if ($first -in $script:NoBridgeSubcommands) { return $true }
  return $false
}

# Override `opencode` to manage the gateway lifecycle around it.
function global:opencode {
  if (-not $script:OpenCodePath) {
    Write-Error "opencode not found on this system"
    return
  }

  # Bridge-only mode: skip the gateway for quick commands (--version, models, etc.)
  $skipBridge = script:Test-SkipBridge -Arguments $args

  if (-not $skipBridge) {
    # Validate config before launching — fail loud, never silent
    $cfgOK = Test-OpenCodeConfig
    if (-not $cfgOK) {
      Write-Warning "[opencode-bridge] Config validation failed — proceeding, but model calls may fall back"
    }
    Start-OpenCodeBridge
  }

  $start = Get-Date
  try {
    & $script:OpenCodePath @args
  } finally {
    if (-not $skipBridge) {
      $duration = [math]::Round(((Get-Date) - $start).TotalSeconds)
      Stop-OpenCodeBridge -SessionDuration $duration
    }
  }
}
