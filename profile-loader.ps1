#Requires -Version 7.0

# profile-loader.ps1 — OpenCode wrapper for PowerShell $PROFILE
#
# Usage in $PROFILE:
#   . C:\Users\zerop\Development\opencode-bridge-tools\profile-loader.ps1

$env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"

# Import the OpenCode bridge module
$modulePath = Join-Path $PSScriptRoot 'OpenCodeBridge.psd1'
try { Import-Module $modulePath -Force -ErrorAction Stop }
catch { Write-Warning "[opencode-bridge] Failed to load module: $_"; return }

# Resolve opencode path
$script:OpenCodePath = Get-OpenCodePath
if (-not $script:OpenCodePath) { Write-Warning "[opencode-bridge] opencode executable not found — wrapper disabled" }

# Subcommands that skip the bridge (no AI model calls)
$script:NoBridgeSubcommands = @('completion','mcp','models','providers','auth','agent','upgrade','uninstall','debug','stats','export','import','session','plugin','plug','db','acp','github')
$script:NoBridgeFlags = @('--version','-v','--help','-h')

# Config cache (60s TTL)
$script:ConfigCache = @{ Result = $null; Timestamp = [datetime]::MinValue }

# Session metrics
$script:SessionCount = 0
$script:TotalSessionSec = 0

function script:Test-SkipBridge {
  param([object[]]$Arguments)
  if (-not $Arguments -or $Arguments.Count -eq 0) { return $false }
  $first = [string]$Arguments[0]
  return ($first -in $script:NoBridgeFlags -or $first -in $script:NoBridgeSubcommands)
}

function global:opencode {
  # Stale path recovery
  if ($script:OpenCodePath -and -not (Test-Path $script:OpenCodePath)) {
    $script:OpenCodePath = Get-OpenCodePath
    if ($script:OpenCodePath) { Write-Host "[opencode-bridge] Re-resolved opencode path: $($script:OpenCodePath)" -ForegroundColor Yellow }
  }
  if (-not $script:OpenCodePath) { Write-Error "opencode not found on this system"; return }

  $env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"
  $skipBridge = script:Test-SkipBridge -Arguments $args

  if (-not $skipBridge) {
    # Config validation (cached 60s)
    $now = Get-Date
    if ($script:ConfigCache.Result -eq $null -or ($now - $script:ConfigCache.Timestamp).TotalSeconds -ge 60) {
      $script:ConfigCache.Result = Test-OpenCodeConfig
      $script:ConfigCache.Timestamp = $now
    }
    if (-not $script:ConfigCache.Result) { Write-Warning "[opencode-bridge] Config validation failed (see above) — model calls may fall back" }

    # Quick connectivity check before starting (fail fast if offline)
    if (-not (Test-BridgeConnectivity)) { Write-Warning "[opencode-bridge] Cannot reach gateway at $((Get-OpenCodeBridgeStatus).BridgeCmd) — opencode will use fallback providers" }
    else { Start-OpenCodeBridge }

    # Track activity for idle timeout
    $script:LastActivity = Get-Date
    $actFile = Join-Path $env:LOCALAPPDATA 'opencode-bridge-activity.txt'
    try { $script:LastActivity.ToString('o') | Set-Content $actFile -Force -ErrorAction SilentlyContinue } catch {}
  }

  $script:SessionCount++
  $start = Get-Date
  $exitCode = 0
  try {
    & $script:OpenCodePath @args
    $exitCode = $LASTEXITCODE
  } finally {
    if (-not $skipBridge) {
      $duration = [math]::Round(((Get-Date) - $start).TotalSeconds)
      $script:TotalSessionSec += $duration
      Stop-OpenCodeBridge -SessionDuration $duration
    }
    $global:LASTEXITCODE = $exitCode
  }
}
