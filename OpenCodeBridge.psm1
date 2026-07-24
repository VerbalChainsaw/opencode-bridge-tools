#Requires -Version 7.0

# OpenCodeBridge.psm1 — OpenCode lifecycle manager, v3.0
#
# Manages the lifecycle of an `opencode` invocation and its upstream
# Hermes Nous AI gateway (listening on 127.0.0.1:8642 by default).
#
# Public functions:
#   Start-OpenCodeBridge      Ensure the upstream gateway is listening.
#   Stop-OpenCodeBridge       Tear down the gateway when no opencode remains.
#   Get-OpenCodePath          Resolve the opencode CLI executable.
#   Get-OpenCodeBridgeStatus  Bridge runtime state (PID, uptime, image, lock).
#   Test-OpenCodeConfig       Validate opencode.jsonc + oh-my-opencode-slim.

# ── Configuration ──────────────────────────────────────────────────
# All paths/timeouts are env-overridable (OPENCODE_BRIDGE_*).

# Message prefix — used by all log functions for consistency.
$script:Prefix = '[opencode-bridge]'
function script:LogWarn ([string]$Msg)   { Write-Warning "$script:Prefix $Msg" }
function script:LogInfo ([string]$Msg)   { Write-Host       "$script:Prefix $Msg" }
function script:LogDbg  ([string]$Msg)   { Write-Verbose    "$script:Prefix $Msg" }

# Safe int coercion from env-var with min/max clamping.
function script:Get-EnvInt {
  param([string]$Name, [int]$Default, [int]$Min, [int]$Max)
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($raw)) { return $Default }
  $parsed = 0
  if ([int]::TryParse($raw, [ref]$parsed)) {
    $clamped = [Math]::Clamp($parsed, $Min, $Max)
    if ($clamped -ne $parsed) { LogWarn "Env $Name=$parsed clamped to [$Min, $Max]" }
    return $clamped
  }
  LogWarn "Env $Name='$raw' is not a valid integer — using default $Default"
  return $Default
}

# Validate that a path from an env var is within an expected directory.
function script:Assert-SafePath {
  param([string]$Path, [string]$AllowedRoot)
  if ([string]::IsNullOrEmpty($Path)) { return $false }
  try {
    $resolved = (Resolve-Path $Path -ErrorAction Stop).Path
    return $resolved.StartsWith($AllowedRoot, [StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

# Expected Hermes binary path for identity verification.
# The gateway spawns a child process (system pythonw) that actually binds
# the port. We accept either the direct venv pythonw or any pythonw whose
# command line contains hermes_cli.main AND executable ends with pythonw.exe.
$script:BridgeBinaryPath = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_BINARY') ?? "C:\Hermes\hermes-agent\venv\Scripts\pythonw.exe"

# Pre-compile regex for process matching (called frequently in polls).
$script:BridgeCmdlineRe = [regex]::new([regex]::Escape("hermes_cli.main"), [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:PythonwSuffixRe = [regex]::new('pythonw\.exe$', [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Guard: USERPROFILE must be set (system accounts, containers, etc.)
if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set. OpenCodeBridge requires a user profile directory.' }

$script:BridgeCmd        = if ($env:OPENCODE_BRIDGE_CMD) {
  if (-not (Assert-SafePath $env:OPENCODE_BRIDGE_CMD 'C:\hermes')) {
    LogWarn "OPENCODE_BRIDGE_CMD='$($env:OPENCODE_BRIDGE_CMD)' is outside expected directory; using default"
    "C:\hermes\gateway-service\Hermes_Gateway.cmd"
  } else { $env:OPENCODE_BRIDGE_CMD }
} else { "C:\hermes\gateway-service\Hermes_Gateway.cmd" }
$script:BridgeWorkDir    = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_WORKDIR') ?? "C:\hermes"
$script:BridgePort       = Get-EnvInt -Name 'OPENCODE_BRIDGE_PORT'       -Default 8642 -Min 1 -Max 65535
$script:BridgeHost       = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_HOST')      ?? "127.0.0.1"
$script:StaleLockMinutes = Get-EnvInt -Name 'OPENCODE_BRIDGE_STALE_LOCK_MIN' -Default 5  -Min 1 -Max 120
$script:StartTimeoutSec  = Get-EnvInt -Name 'OPENCODE_BRIDGE_START_TIMEOUT'  -Default 25 -Min 5 -Max 300
$script:StartRetryCount  = Get-EnvInt -Name 'OPENCODE_BRIDGE_START_RETRIES'  -Default 3  -Min 1 -Max 10
$script:MinSessionSec    = 15
$script:MaxConfigSize    = 1048576
$script:FastPollSleepMs  = 250
$script:FastPollTimeoutSec = 5

$script:LockFilePath     = Join-Path $env:LOCALAPPDATA 'opencode-bridge-starting.lock'
$script:OpenCodeConfig   = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
$script:OpenCodeSlimCfg  = Join-Path $env:USERPROFILE '.config\opencode\oh-my-opencode-slim.json'
$script:HermesProvider   = 'hermes-nous'

# Valid socket states on Windows (Get-NetTCPConnection may not always report Listen).
$script:ValidSocketStates = @('Listen', 'Bound', 'Established')

# ── Private helpers ─────────────────────────────────────────────────

function script:Get-BridgeConnection {
  [CmdletBinding()] param()
  Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in $script:ValidSocketStates -and $_.LocalAddress -in @($script:BridgeHost, '0.0.0.0', '::') } |
    Select-Object -First 1
}

function script:Get-PortState {
  <#
  .SYNOPSIS
    Returns a hashtable describing the port occupant in a single pass.
    Keys: State ('none','gateway','intruder'), Pid (int|null), PidInfo (CIM|null).
  #>
  [CmdletBinding()] param()
  $conn = Get-BridgeConnection
  if (-not $conn) { return @{ State = 'none'; Pid = $null; PidInfo = $null } }
  $pid = [int]$conn.OwningProcess
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue
  # Verify: exact path match (venv pythonw) OR (cmdline contains hermes_cli.main
  # AND executable ends with pythonw.exe — system Python spawned by the gateway).
  $isGateway = $p.ExecutablePath -eq $script:BridgeBinaryPath -or
               ($p.CommandLine -match $script:BridgeCmdlineRe -and $p.ExecutablePath -match $script:PythonwSuffixRe)
  if ($p -and $isGateway) {
    return @{ State = 'gateway'; Pid = $pid; PidInfo = $p }
  }
  # Intruder — log its details for debugging
  $desc = $p ? "$($p.Name) '$($p.CommandLine)'" : 'unknown process'
  LogWarn "Port $($script:BridgePort) held by pid $pid ($desc) — NOT the Hermes gateway"
  return @{ State = 'intruder'; Pid = $pid; PidInfo = $p }
}

function script:Acquire-Lock {
  [CmdletBinding()] param()
  if (Test-Path $script:LockFilePath) {
    try {
      $age = [int]((Get-Date) - (Get-Item $script:LockFilePath).CreationTime).TotalMinutes
      if ($age -ge $script:StaleLockMinutes) {
        LogWarn "Removing stale lock ($age min old)"
        Remove-Item -LiteralPath $script:LockFilePath -Force -ErrorAction Stop
      }
    } catch {
      LogWarn "Cannot read/remove lock file: $_"
      return $null
    }
  }
  try {
    return [IO.File]::Open($script:LockFilePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  } catch {
    LogWarn 'Another shell is already starting the gateway'
    return $null
  }
}
function script:Release-Lock {
  param($Lock)
  if ($Lock) {
    try { $Lock.Dispose() } catch {}
    Remove-Item -LiteralPath $script:LockFilePath -ErrorAction SilentlyContinue
  }
}
# ── Public functions ─────────────────────────────────────────────────

function Start-OpenCodeBridge {
  <#
  .SYNOPSIS
    Ensures the Hermes gateway is listening on the configured port.
  .DESCRIPTION
    Fast path if already up. Otherwise launches with retries + liveness checks.
    File-lock prevents concurrent launches across terminals.
  #>
  [CmdletBinding()]
  [OutputType([void])] param()

  $ps = Get-PortState
  if ($ps.State -eq 'gateway') { LogDbg "Gateway already up (pid $($ps.Pid))"; return }
  if ($ps.State -eq 'intruder') {
    LogWarn "Port $($script:BridgePort) held by non-Hermes process — refusing to start"
    return
  }
  if (-not (Test-Path $script:BridgeCmd)) {
    LogWarn "Gateway script not found: $($script:BridgeCmd)"; return
  }

  $lock = Acquire-Lock
  if (-not $lock) { return }

  try {
    for ($attempt = 1; $attempt -le $script:StartRetryCount; $attempt++) {
      $ps = Get-PortState
      if ($ps.State -eq 'gateway') { LogDbg "Gateway ready from prior attempt (pid $($ps.Pid))"; return }
      if ($ps.State -eq 'intruder') { LogWarn 'Non-Hermes process bound port during startup — aborting'; return }

      $proc = $null
      try {
        $proc = Start-Process -FilePath $script:BridgeCmd -WorkingDirectory $script:BridgeWorkDir `
          -WindowStyle Hidden -PassThru -ErrorAction Stop
      } catch {
        LogWarn "Launch attempt $attempt/$($script:StartRetryCount) failed: $_"
        if ($attempt -lt $script:StartRetryCount) { Start-Sleep -Seconds 3 }
        continue
      }

      # Health-check: fast-poll then slow-poll with process-liveness watch.
      $elapsed = 0
      $timeouts = @(
        @{ Limit = $script:FastPollTimeoutSec; Sleep = $script:FastPollSleepMs; Unit = 'ms' }
        @{ Limit = $script:StartTimeoutSec;     Sleep = 2000;         Unit = 's'  }
      )
      :healthLoop foreach ($t in $timeouts) {
        while ($elapsed -lt $t.Limit) {
          $ps = Get-PortState
          if ($ps.State -eq 'gateway') { LogInfo "Gateway ready (pid $($ps.Pid))"; return }
          if ($proc.HasExited) { LogWarn "Process exited early (code $($proc.ExitCode)) attempt $attempt/$($script:StartRetryCount)"; break healthLoop }
          if ($t.Unit -eq 'ms') { Start-Sleep -Milliseconds $t.Sleep; $elapsed += $t.Sleep / 1000.0 }
          else { Start-Sleep -Seconds ($t.Sleep / 1000); $elapsed += $t.Sleep / 1000 }
        }
      }
      if (-not $proc.HasExited) {
        LogWarn "Attempt $attempt/$($script:StartRetryCount): port not opened within $($script:StartTimeoutSec)s"
        try { $proc.Kill() } catch { LogWarn "Could not kill hung process: $_" }
      }
      Start-Sleep -Seconds 2
    }
    LogWarn "Gateway failed after $($script:StartRetryCount) attempts — opencode will use fallback providers"
  } finally { Release-Lock $lock }
}

function Stop-OpenCodeBridge {
  <#
  .SYNOPSIS
    Stops the gateway — only if no other opencode instance remains.
  #>
  [CmdletBinding()]
  [OutputType([void])] param([int]$SessionDuration = 0)

  if ($SessionDuration -lt $script:MinSessionSec) { return }

  # Skip the 3-second sleep if no bridge is running
  $ps = Get-PortState
  if ($ps.State -ne 'gateway') { return }

  Start-Sleep -Seconds 3
  $remaining = @()
  for ($i = 0; $i -lt 5; $i++) {
    # Filter to current user only — don't block teardown because another
    # user account is running opencode.
    $remaining = @(Get-Process -Name 'opencode' -IncludeUserName -ErrorAction SilentlyContinue |
      Where-Object UserName -eq $env:USERNAME)
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }
  if ($remaining.Count -gt 0) { return }

  $ps = Get-PortState
  if ($ps.State -ne 'gateway') { return }

  # TOCTOU re-check: another opencode could have started since the poll.
  $recheck = @(Get-Process -Name 'opencode' -IncludeUserName -ErrorAction SilentlyContinue |
    Where-Object UserName -eq $env:USERNAME)
  if ($recheck.Count -gt 0) { return }

  try {
    $proc = Get-Process -Id $ps.Pid -ErrorAction Stop
    $proc.Kill()
    if (-not $proc.WaitForExit(5000)) {
      LogWarn "Gateway process (pid $($ps.Pid)) did not exit within 5s — may need manual cleanup"
    }
    LogInfo "Gateway stopped (pid $($ps.Pid))"
  } catch {
    if ($_.Exception.Message -match 'Cannot find a process') {
      LogInfo 'Gateway already stopped'
    } else {
      LogWarn "Could not stop gateway process: $_"
    }
  }
}

function Get-OpenCodeBridgeStatus {
  <#
  .SYNOPSIS
    Reports runtime state of the gateway.
  .OUTPUTS
    PSCustomObject: BridgeReady, Port, ProcessId, ImagePath, CmdLine, Uptime, LockFile, LockHeld, BridgeCmd.
  #>
  [CmdletBinding()]
  [OutputType([PSCustomObject])] param()

  $ps = Get-PortState; $ready = $ps.State -eq 'gateway'
  $uptime = ($ready -and $ps.PidInfo) ? ((Get-Date) - (Get-Process -Id $ps.Pid -ErrorAction SilentlyContinue).StartTime) : $null

  [PSCustomObject][ordered]@{
    BridgeReady = $ready
    Port        = $script:BridgePort
    ProcessId   = $ready ? $ps.Pid : $null
    ImagePath   = $ready ? $ps.PidInfo.ExecutablePath : $null
    CmdLine     = $ready ? $ps.PidInfo.CommandLine : $null
    Uptime      = $uptime
    LockFile    = $script:LockFilePath
    LockHeld    = Test-Path $script:LockFilePath
    BridgeCmd   = $script:BridgeCmd
  }
}

function Test-OpenCodeConfig {
  <#
  .SYNOPSIS
    Validates opencode.jsonc + oh-my-opencode-slim preset.
  .OUTPUTS
    bool — $true when config is bridge-ready.
  #>
  [CmdletBinding()]
  [OutputType([bool])] param()

  # Module-scoped JSONC comment stripper (compiled once, not per invocation).
  if (-not $script:StripCommentsRe) {
    $script:StripCommentsRe = [regex]::new('/\*[\s\S]*?\*/', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $script:StripLineCommentsRe = [regex]::new('(?m)^\s*//.*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
  }

  filter Strip-Comments {
    $script:StripLineCommentsRe.Replace($script:StripCommentsRe.Replace($_, ''), '')
  }

  $parseJsonc = {
    param([string]$Path)
    if (-not (Test-Path $Path)) { LogWarn "Missing config: $Path"; return $null }
    try {
      $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
      if ($raw.Length -gt $script:MaxConfigSize) {
        LogWarn ('Config too large ({0} bytes, max {1}): {2}' -f $raw.Length, $script:MaxConfigSize, $Path)
        return $null
      }
      $raw | Strip-Comments | ConvertFrom-Json -ErrorAction Stop
    } catch { LogWarn "Could not parse $Path : $_"; return $null }
  }

  $json = & $parseJsonc $script:OpenCodeConfig
  if (-not $json) { return $false }

  $provider = $json.provider.$($script:HermesProvider)
  if (-not $provider) { LogWarn "'$($script:HermesProvider)' provider missing — bridge has no consumer"; return $false }

  $baseURL = $provider.options.baseURL
  $expected = "http://$($script:BridgeHost):$($script:BridgePort)/v1"
  if ($baseURL -ne $expected) { LogWarn "hermes-nous baseURL is '$baseURL' (expected '$expected')"; return $false }

  $slim = & $parseJsonc $script:OpenCodeSlimCfg
  if (-not $slim) { return $false }

  $active = $slim.preset
  if (-not $active) { LogWarn 'oh-my-opencode-slim has no active preset'; return $false }
  $preset = $slim.presets.$active
  if (-not $preset) { LogWarn "Preset '$active' not found in presets"; return $false }

  $ok = $true
  foreach ($roleKey in $preset.PSObject.Properties.Name) {
    $role = $preset.$roleKey
    if (-not $role -or $role -isnot [PSCustomObject]) { continue }
    $model = $role.model
    if (-not $model) { continue }
    if ($model -notmatch "^$([regex]::Escape($script:HermesProvider))/") {
      LogWarn "Preset '$active' role '$roleKey' uses '$model' — not on '$($script:HermesProvider)'"
      $ok = $false
    }
  }
  return $ok
}

function Get-OpenCodePath {
  <#
  .SYNOPSIS
    Resolves the opencode CLI executable path. Prefers copies without spaces.
  #>
  [CmdletBinding()]
  [OutputType([string])] param()

  foreach ($p in @("$env:LOCALAPPDATA\Programs\opencode\opencode.exe",
                    "$env:USERPROFILE\scoop\shims\opencode.exe",
                    "C:\Program Files\nodejs\opencode.cmd")) {
    if (Test-Path $p) { return $p }
  }
  try {
    $cmd = Get-Command opencode -ErrorAction Stop
    if ($cmd.CommandType -in @('Application', 'ExternalScript')) { return $cmd.Source }
  } catch {
    LogWarn "Get-Command opencode failed: $_"
  }
  return $null
}

Export-ModuleMember -Function Start-OpenCodeBridge, Stop-OpenCodeBridge, Get-OpenCodePath, Get-OpenCodeBridgeStatus, Test-OpenCodeConfig
