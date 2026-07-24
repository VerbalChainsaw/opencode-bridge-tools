#Requires -Version 7.0

# OpenCodeBridge.psm1 - OpenCode lifecycle manager
#
# This module manages the lifecycle of an `opencode` invocation, including the
# upstream AI gateway that the opencode `hermes-nous` provider points to
# (the Hermes Nous bridge listening on 127.0.0.1:8642). The opencode CLI is the
# subject of the tool; the Hermes gateway is one upstream dependency that this
# module auto-starts and auto-stops around it.
#
# Public functions:
#   Start-OpenCodeBridge      Ensure the upstream gateway is listening.
#   Stop-OpenCodeBridge       Tear down the gateway when no opencode remains.
#   Get-OpenCodePath          Resolve the opencode CLI executable.
#   Get-OpenCodeBridgeStatus  Report bridge / gateway runtime state.
#   Test-OpenCodeConfig       Validate opencode.jsonc + oh-my-opencode-slim preset.

# ── Configuration ──────────────────────────────────────────────────
# Paths may be overridden via env vars (prefixed with OPENCODE_BRIDGE_).
$script:BridgeCmd        = if (Test-Path env:OPENCODE_BRIDGE_CMD)       { $env:OPENCODE_BRIDGE_CMD       } else { "C:\hermes\gateway-service\Hermes_Gateway.cmd" }
$script:BridgeWorkDir    = if (Test-Path env:OPENCODE_BRIDGE_WORKDIR)   { $env:OPENCODE_BRIDGE_WORKDIR   } else { "C:\hermes" }
$script:BridgePort       = if (Test-Path env:OPENCODE_BRIDGE_PORT)      { [int]$env:OPENCODE_BRIDGE_PORT  } else { 8642 }
$script:BridgeHost       = if (Test-Path env:OPENCODE_BRIDGE_HOST)      { $env:OPENCODE_BRIDGE_HOST      } else { "127.0.0.1" }
$script:BridgeCmdNeedle  = "hermes_cli.main"        # appears in the pythonw cmdline
$script:BridgeImageName  = "pythonw"                # image name we expect on the port

# Timeout / retry constants (also env-overridable)
$script:StaleLockMinutes = if (Test-Path env:OPENCODE_BRIDGE_STALE_LOCK_MIN) { [int]$env:OPENCODE_BRIDGE_STALE_LOCK_MIN } else { 5 }
$script:StartTimeoutSec  = if (Test-Path env:OPENCODE_BRIDGE_START_TIMEOUT)  { [int]$env:OPENCODE_BRIDGE_START_TIMEOUT  } else { 25 }
$script:StartRetryCount  = if (Test-Path env:OPENCODE_BRIDGE_START_RETRIES)  { [int]$env:OPENCODE_BRIDGE_START_RETRIES  } else { 3 }
$script:MinSessionSec    = 15                       # short sessions leave the bridge up
$script:MaxConfigSize    = 1048576                  # 1 MB cap for config files

# Derived paths (read-only after init)
$script:LockFilePath     = Join-Path $env:LOCALAPPDATA "opencode-bridge-starting.lock"
$script:OpenCodeConfig   = Join-Path $env:USERPROFILE ".config\opencode\opencode.jsonc"
$script:OpenCodeSlimCfg  = Join-Path $env:USERPROFILE ".config\opencode\oh-my-opencode-slim.json"
$script:HermesProvider   = "hermes-nous"

# ── Helpers (module-private) ───────────────────────────────────────

function script:Get-BridgeConnection {
  <#
  .SYNOPSIS
    Returns the TCP connection holding the bridge port, or $null.
    Checks Listen, Bound, and Established states because Windows
    Get-NetTCPConnection does not always report Listen for every socket.
  #>
  [CmdletBinding()] param()
  Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue |
    Where-Object {
      $_.State -in @('Listen', 'Bound', 'Established') -and
      $_.LocalAddress -in @($script:BridgeHost, '0.0.0.0', '::')
    } |
    Select-Object -First 1
}

function script:Test-BridgeProcess {
  # Verify a PID actually looks like the Hermes gateway by image + cmdline.
  # Prevents mis-attribution if an unrelated python process happens to bind the port.
  [CmdletBinding()] param([int]$ProcessId)
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $p) { return $false }
  if ($p.Name -notmatch "^$([regex]::Escape($script:BridgeImageName))") { return $false }
  if ($p.CommandLine -notmatch [regex]::Escape($script:BridgeCmdNeedle)) { return $false }
  return $true
}

function script:Get-BridgeProcessId {
  [CmdletBinding()] param()
  $conn = Get-BridgeConnection
  if (-not $conn) { return $null }
  if (-not (Test-BridgeProcess -ProcessId $conn.OwningProcess)) {
    Write-Warning "[opencode-bridge] Port $($script:BridgePort) held by pid $($conn.OwningProcess) but it is NOT the Hermes gateway (image/cmdline mismatch)"
    return $null
  }
  return [int]$conn.OwningProcess
}

# Return one of: 'none' (port free), 'gateway' (verified Hermes), 'intruder'
# (someone else on the port). Used by Start-OpenCodeBridge to decide whether
# the fast path succeeds, the retry loop runs, or we bail immediately.
# When returning 'intruder', also emits a warning with the intruder's details.
function script:Get-PortOccupant {
  [CmdletBinding()] param()
  $conn = Get-BridgeConnection
  if (-not $conn) { return 'none' }
  if (Test-BridgeProcess -ProcessId $conn.OwningProcess) { return 'gateway' }
  # Log the intruder for debugging
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction SilentlyContinue
  $desc = if ($p) { "$($p.Name) '$($p.CommandLine)'" } else { "unknown process" }
  Write-Warning "[opencode-bridge] Port $($script:BridgePort) held by pid $($conn.OwningProcess) ($desc) — it is NOT the Hermes gateway"
  return 'intruder'
}

function script:Acquire-Lock {
  <#
  .SYNOPSIS
    Atomically acquires the startup lock file.
  .DESCRIPTION
    Uses [System.IO.File]::Open with FileMode.CreateNew for atomicity.
    Stale locks are removed first. Returns a disposable FileStream or $null
    if another instance holds the lock.
  #>
  [CmdletBinding()] param()

  # Check for and remove stale lock
  if (Test-Path $script:LockFilePath) {
    try {
      $age = [int]((Get-Date) - (Get-Item $script:LockFilePath).CreationTime).TotalMinutes
      if ($age -ge $script:StaleLockMinutes) {
        Write-Warning "[opencode-bridge] Removing stale lock ($age min old)"
        Remove-Item -LiteralPath $script:LockFilePath -Force -ErrorAction Stop
      }
    } catch {
      # Could not read or remove — likely permission issue
      Write-Warning "[opencode-bridge] Cannot read/remove lock file: $_"
      return $null
    }
  }

  try {
    return [System.IO.File]::Open(
      $script:LockFilePath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
  } catch {
    Write-Warning "[opencode-bridge] Another shell is already starting the gateway"
    return $null
  }
}

function script:Release-Lock {
  param($Lock)
  if ($Lock) {
    try { $Lock.Dispose() } catch {}
  }
  Remove-Item -LiteralPath $script:LockFilePath -ErrorAction SilentlyContinue
}

# ── Public functions ───────────────────────────────────────────────

<#
.SYNOPSIS
  Ensures the Hermes Nous gateway (upstream to opencode's hermes-nous
  provider) is listening on 127.0.0.1:8642.

.DESCRIPTION
  Fast path: returns immediately if a real bridge process already holds the
  port. Otherwise launches Hermes_Gateway.cmd with up to 3 retries, polling
  port + process liveness each cycle. A file lock prevents concurrent
  launches across multiple terminals (TOCTOU guard); locks older than 5
  minutes are treated as orphaned from a crash and removed.

  The retry loop re-checks for an intruder at each attempt — if a non-Hermes
  process binds the port mid-startup, we bail instead of retrying.
#>
function Start-OpenCodeBridge {
  [CmdletBinding()] param()

  # Inspect the port first. Three states:
  #   'gateway'  -> fast path, done
  #   'intruder' -> bail. Do NOT launch a clone that will conflict.
  #   'none'     -> proceed to launch the gateway
  $occupant = Get-PortOccupant
  if ($occupant -eq 'gateway') {
    $pid_ = Get-BridgeProcessId
    Write-Verbose "[opencode-bridge] Gateway already up (pid $pid_)"
    return
  }
  if ($occupant -eq 'intruder') {
    Write-Warning "[opencode-bridge] Port $($script:BridgePort) held by a non-Hermes process — refusing to start a conflicting gateway. Stop that process first or change the bridge port."
    return
  }

  # Bail if gateway script is missing
  if (-not (Test-Path $script:BridgeCmd)) {
    Write-Warning "[opencode-bridge] Gateway script not found: $($script:BridgeCmd)"
    return
  }

  $lock = Acquire-Lock
  if (-not $lock) { return }

  try {
    for ($attempt = 1; $attempt -le $script:StartRetryCount; $attempt++) {
      # Re-check the port at each attempt: an intruder could have appeared
      $occupant = Get-PortOccupant
      if ($occupant -eq 'gateway') {
        # Gateway came up from a previous attempt's child — done
        $pid_ = Get-BridgeProcessId
        Write-Verbose "[opencode-bridge] Gateway ready from prior attempt (pid $pid_)"
        return
      }
      if ($occupant -eq 'intruder') {
        Write-Warning "[opencode-bridge] Non-Hermes process bound port during startup — aborting"
        return
      }

      $proc = $null
      try {
        $proc = Start-Process -FilePath $script:BridgeCmd `
          -WorkingDirectory $script:BridgeWorkDir `
          -WindowStyle Hidden -PassThru -ErrorAction Stop
      } catch {
        Write-Warning "[opencode-bridge] Launch attempt $attempt/$($script:StartRetryCount) failed: $_"
        if ($attempt -lt $script:StartRetryCount) { Start-Sleep -Seconds 3 }
        continue
      }

      # Health check: wait for the port, watching process liveness each cycle
      $elapsed = 0
      while ($elapsed -lt $script:StartTimeoutSec) {
        $pid_ = Get-BridgeProcessId
        if ($pid_) {
          Write-Host "[opencode-bridge] Gateway ready (pid $pid_)"
          return
        }
        if ($proc.HasExited) {
          Write-Warning "[opencode-bridge] Process exited early (code $($proc.ExitCode)) on attempt $attempt/$($script:StartRetryCount)"
          break
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
      }

      if (-not $proc.HasExited) {
        Write-Warning "[opencode-bridge] Attempt $attempt/$($script:StartRetryCount): port $($script:BridgePort) not opened within $($script:StartTimeoutSec)s"
        try { $proc.Kill() } catch { Write-Warning "[opencode-bridge] Could not kill hung process: $_" }
      }
      Start-Sleep -Seconds 2
    }
    Write-Warning "[opencode-bridge] Gateway failed after $($script:StartRetryCount) attempts — opencode will use fallback providers"
  } finally {
    Release-Lock $lock
  }
}

<#
.SYNOPSIS
  Stops the Hermes gateway if no opencode instances remain.

.DESCRIPTION
  Only tears down the gateway after a real interactive session
  (> MinSessionSec), not quick CLI commands. Waits for opencode to fully
  exit, polls remaining processes, and kills the verified gateway process
  (matched by image path + cmdline, never by port number alone).
#>
function Stop-OpenCodeBridge {
  [CmdletBinding()] param([int]$SessionDuration = 0)

  # Short sessions leave the bridge up
  if ($SessionDuration -lt $script:MinSessionSec) { return }

  # Wait for opencode to fully exit, then confirm no other opencode remains
  Start-Sleep -Seconds 3
  for ($i = 0; $i -lt 5; $i++) {
    $remaining = @(Get-Process -Name "opencode" -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }
  if ($remaining.Count -gt 0) { return }

  # Locate the verified gateway process; never kill on port match alone
  $pid_ = Get-BridgeProcessId
  if (-not $pid_) { return }

  try {
    $proc = Get-Process -Id $pid_ -ErrorAction Stop
    $proc.Kill()
    if (-not $proc.WaitForExit(5000)) {
      Write-Warning "[opencode-bridge] Gateway process (pid $pid_) did not exit within 5s — may need manual cleanup"
    }
    Write-Host "[opencode-bridge] Gateway stopped (pid $pid_)"
  } catch {
    if ($_.Exception.Message -match "Cannot find a process") {
      # Already gone — fine
      Write-Host "[opencode-bridge] Gateway already stopped"
    } else {
      Write-Warning "[opencode-bridge] Could not stop gateway process: $_"
    }
  }
}

<#
.SYNOPSIS
  Reports runtime state of the opencode bridge and gateway.

.DESCRIPTION
  Returns a PSCustomObject with: BridgeReady (bool), Port (int),
  ProcessId (int|null), ImagePath (string|null), CmdLine (string|null),
  Uptime (TimeSpan|null), LockFile (string), LockHeld (bool).
#>
function Get-OpenCodeBridgeStatus {
  [CmdletBinding()] param()

  $conn = Get-BridgeConnection
  $procId = $null; $imagePath = $null; $cmdLine = $null; $uptime = $null; $ready = $false

  if ($conn -and (Test-BridgeProcess -ProcessId $conn.OwningProcess)) {
    $procId = [int]$conn.OwningProcess
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if ($p) {
      $imagePath = $p.ExecutablePath
      $cmdLine   = $p.CommandLine
      $pp = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($pp -and $pp.StartTime) { $uptime = (Get-Date) - $pp.StartTime }
      $ready = $true
    }
  }

  [PSCustomObject]@{
    BridgeReady = $ready
    Port        = $script:BridgePort
    ProcessId   = $procId
    ImagePath   = $imagePath
    CmdLine     = $cmdLine
    Uptime      = $uptime
    LockFile    = $script:LockFilePath
    LockHeld    = (Test-Path $script:LockFilePath)
    BridgeCmd   = $script:BridgeCmd
  }
}

<#
.SYNOPSIS
  Validates opencode.jsonc + the oh-my-opencode-slim preset for bridge use.

.DESCRIPTION
  Verifies the hermes-nous provider is configured with the local baseURL,
  and that every model referenced by the active preset's roles resolves to
  the hermes-nous provider. Returns $true on success and writes warnings
  (never throws) on drift, so a degraded config doesn't break the wrapper.

  Config files larger than MaxConfigSize (1 MB default) are rejected.
#>
function Test-OpenCodeConfig {
  [CmdletBinding()] param()

  # Helper: strip JSONC comments safely.
  # Only strips /* */ block comments and line-start // comments.
  # Does NOT strip trailing // to avoid eating URLs like http:// inside strings.
  $stripComments = {
    param([string]$Text)
    $Text = $Text -replace '/\*[\s\S]*?\*/', ''
    $Text = $Text -replace '(?m)^\s*//.*$', ''
    $Text
  }

  # Helper: parse JSONC file with size limit and comment stripping
  $parseJsonc = {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
      Write-Warning "[opencode-bridge] Missing config: $Path"
      return $null
    }
    $size = (Get-Item $Path).Length
    if ($size -gt $script:MaxConfigSize) {
      Write-Warning "[opencode-bridge] Config too large ($size bytes, max $($script:MaxConfigSize)): $Path"
      return $null
    }
    try {
      $raw = Get-Content -Raw -LiteralPath $Path
      ($raw | ForEach-Object { & $stripComments $_ }) | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Write-Warning "[opencode-bridge] Could not parse $Path : $_"
      return $null
    }
  }

  # Parse opencode.jsonc
  $json = & $parseJsonc $script:OpenCodeConfig
  if (-not $json) { return $false }

  # Check hermes-nous provider (use dot notation for case-insensitive access)
  $provider = $json.provider.$($script:HermesProvider)
  if (-not $provider) {
    Write-Warning "[opencode-bridge] '$($script:HermesProvider)' provider missing from opencode.jsonc — bridge has no consumer"
    return $false
  }
  $baseURL = $provider.options.baseURL
  $expected = "http://$($script:BridgeHost):$($script:BridgePort)/v1"
  if ($baseURL -ne $expected) {
    Write-Warning "[opencode-bridge] hermes-nous baseURL is '$baseURL' (expected '$expected')"
    return $false
  }

  # Parse oh-my-opencode-slim preset
  $slim = & $parseJsonc $script:OpenCodeSlimCfg
  if (-not $slim) { return $false }

  $active = $slim.preset
  if (-not $active) {
    Write-Warning "[opencode-bridge] oh-my-opencode-slim has no active preset"
    return $false
  }
  $preset = $slim.presets.$active
  if (-not $preset) {
    Write-Warning "[opencode-bridge] Preset '$active' not found in presets"
    return $false
  }

  # Validate every role's model: must live on hermes-nous provider.
  # Iterate preset properties dynamically (not hardcoded role list).
  $ok = $true
  foreach ($roleKey in $preset.PSObject.Properties.Name) {
    $role = $preset.$roleKey
    if (-not $role -or $role -isnot [PSCustomObject]) { continue }
    $model = $role.model
    if (-not $model) { continue }
    if ($model -notmatch "^$([regex]::Escape($script:HermesProvider))/") {
      Write-Warning "[opencode-bridge] Preset '$active' role '$roleKey' uses '$model' — not on '$($script:HermesProvider)'"
      $ok = $false
    }
  }
  return $ok
}

<#
.SYNOPSIS
  Resolves the path to the opencode CLI executable.
  Prefers copies without spaces in the path to avoid SpawnSync issues.
#>
function Get-OpenCodePath {
  [CmdletBinding()] param()
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\opencode\opencode.exe",
    "$env:USERPROFILE\scoop\shims\opencode.exe",
    "C:\Program Files\nodejs\opencode.cmd"
  )
  foreach ($p in $candidates) {
    if (Test-Path $p) { return $p }
  }
  try {
    $cmd = Get-Command opencode -ErrorAction Stop
    # Validate it: must be an executable (not an alias or function)
    if ($cmd.CommandType -in @('Application', 'ExternalScript')) {
      return $cmd.Source
    }
  } catch {}
  return $null
}

Export-ModuleMember -Function Start-OpenCodeBridge, Stop-OpenCodeBridge, Get-OpenCodePath, Get-OpenCodeBridgeStatus, Test-OpenCodeConfig
