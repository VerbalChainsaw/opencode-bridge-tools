#Requires -Version 7.0

# profile-loader.ps1
# Drop this into your PowerShell profile to wrap the `opencode` CLI so it
# auto-starts and auto-stops the Hermes Nous gateway (the upstream for the
# hermes-nous provider in opencode.jsonc) around each invocation.
#
# Usage in $PROFILE:
#   . C:\Users\zerop\Development\opencode-bridge-tools\profile-loader.ps1

# Enable background subagents for oh-my-opencode-slim orchestration.
# Scoped to opencode wrapper invocations only — set on each call, not globally.
# Initial profile load sets it for the session; wrapper re-applies on each run.
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
# Derived from `opencode --help` on 2026-07-24 (open code 1.18.4).
# New subcommands added via `opencode upgrade` may need manual updates here.
$script:NoBridgeSubcommands = @(
  'completion', 'mcp', 'models', 'providers', 'auth', 'agent',
  'upgrade', 'uninstall', 'debug', 'stats', 'export', 'import',
  'session', 'plugin', 'plug', 'db', 'acp', 'github'
)
$script:NoBridgeFlags = @('--version', '-v', '--help', '-h')

# Config validation cache: avoid re-validating on every invocation.
# Only re-validate if >60s since last check or $null (first run).
$script:ConfigCache = @{ Result = $null; Timestamp = [datetime]::MinValue }

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
  # Guard: if the cached path went stale (e.g. opencode updated mid-session),
  # re-resolve once before giving up.
  if ($script:OpenCodePath -and -not (Test-Path $script:OpenCodePath)) {
    $script:OpenCodePath = Get-OpenCodePath
    if ($script:OpenCodePath) {
      Write-Host "[opencode-bridge] Re-resolved opencode path: $($script:OpenCodePath)" -ForegroundColor Yellow
    }
  }

  if (-not $script:OpenCodePath) {
    Write-Error "opencode not found on this system"
    return
  }

  # Re-apply the env var so subprocesses inherit it (belt-and-suspenders)
  $env:OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true"

  # Bridge-only mode: skip the gateway for quick commands (--version, models, etc.)
  $skipBridge = script:Test-SkipBridge -Arguments $args

  if (-not $skipBridge) {
    # Validate config before launching. Cache result for 60 seconds.
    $now = Get-Date
    if ($script:ConfigCache.Result -eq $null -or
        ($now - $script:ConfigCache.Timestamp).TotalSeconds -ge 60) {
      $script:ConfigCache.Result = Test-OpenCodeConfig
      $script:ConfigCache.Timestamp = $now
    }
    if (-not $script:ConfigCache.Result) {
      # Test-OpenCodeConfig already wrote its own diagnostic warning, so
      # only add a brief status line (don't duplicate the detailed warning).
      Write-Warning "[opencode-bridge] Config validation failed (see above) — model calls may fall back"
    }
    Start-OpenCodeBridge
  }

  $start = Get-Date
  $exitCode = 0
  try {
    & $script:OpenCodePath @args
    $exitCode = $LASTEXITCODE
  } finally {
    if (-not $skipBridge) {
      $duration = [math]::Round(((Get-Date) - $start).TotalSeconds)
      Stop-OpenCodeBridge -SessionDuration $duration
    }
    # Restore exit code so callers (scripts, CI) see the real result.
    # PowerShell's $LASTEXITCODE persists through finally for native commands,
    # but we capture it explicitly for clarity.
    $global:LASTEXITCODE = $exitCode
  }
}
