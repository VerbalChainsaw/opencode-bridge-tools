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
$script:BridgeCmd        = "C:\hermes\gateway-service\Hermes_Gateway.cmd"
$script:BridgeWorkDir    = "C:\hermes"
$script:BridgePort       = 8642
$script:BridgeHost       = "127.0.0.1"
$script:BridgeCmdNeedle  = "hermes_cli.main"        # appears in the pythonw cmdline
$script:BridgeImageName  = "pythonw"                # image name we expect on the port
$script:LockFilePath     = Join-Path $env:LOCALAPPDATA "opencode-bridge-starting.lock"
$script:StaleLockMinutes = 5
$script:StartTimeoutSec  = 25
$script:StartRetryCount  = 3
$script:MinSessionSec    = 15                       # short sessions leave the bridge up
$script:OpenCodeConfig   = Join-Path $env:USERPROFILE ".config\opencode\opencode.jsonc"
$script:OpenCodeSlimCfg  = Join-Path $env:USERPROFILE ".config\opencode\oh-my-opencode-slim.json"
$script:HermesProvider   = "hermes-nous"
$script:SessionDuration  = 0

# ── Helpers (module-private) ───────────────────────────────────────

function script:Get-BridgeConnection {
  [CmdletBinding()] param()
  Get-NetTCPConnection -LocalPort $script:BridgePort -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @($script:BridgeHost, '0.0.0.0', '::') } |
    Select-Object -First 1
}

function script:Test-BridgeProcess {
  # Verify a PID actually looks like the Hermes gateway by image + cmdline.
  # Prevents mis-attribution if an unrelated python process happens to bind 8642.
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
function script:Get-PortOccupant {
  [CmdletBinding()] param()
  $conn = Get-BridgeConnection
  if (-not $conn) { return 'none' }
  if (Test-BridgeProcess -ProcessId $conn.OwningProcess) { return 'gateway' }
  return 'intruder'
}

function script:Remove-StaleLock {
  [CmdletBinding()] param()
  if (-not (Test-Path $script:LockFilePath)) { return $false }
  $age = [int]((Get-Date) - (Get-Item $script:LockFilePath).CreationTime).TotalMinutes
  if ($age -ge $script:StaleLockMinutes) {
    Write-Warning "[opencode-bridge] Removing stale lock ($age min old)"
    Remove-Item -LiteralPath $script:LockFilePath -Force -ErrorAction SilentlyContinue
    return $true
  }
  return $false
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
#>
function Start-OpenCodeBridge {
  [CmdletBinding()] param()

  # Inspect the port first. Three states:
  #   'gateway'  -> fast path, done
  #   'intruder' -> bail. Do NOT launch a clone that will conflict, and
  #                 do NOT loop-retry against a non-Hermes occupier.
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

  $staleRemoved = Remove-StaleLock

  # Acquire exclusive lock (TOCTOU guard across terminals)
  $lock = $null
  try {
    $lock = [System.IO.File]::Open(
      $script:LockFilePath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
  } catch {
    if (-not $staleRemoved) {
      Write-Warning "[opencode-bridge] Another shell is already starting the gateway"
    }
    return
  }

  try {
    for ($attempt = 1; $attempt -le $script:StartRetryCount; $attempt++) {
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
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $script:LockFilePath -ErrorAction SilentlyContinue
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
  [CmdletBinding()] param([int]$SessionDuration = $script:SessionDuration)

  # Short sessions leave the bridge up
  if ($SessionDuration -lt $script:MinSessionSec) { return }

  # Wait for opencode to fully exit, then confirm no other opencode remains
  Start-Sleep -Seconds 3
  $remaining = $null
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
    $proc.WaitForExit(5000) | Out-Null
    Write-Host "[opencode-bridge] Gateway stopped (pid $pid_)"
  } catch {
    Write-Warning "[opencode-bridge] Could not stop gateway process: $_"
  }
}

<#
.SYNOPSIS
  Reports runtime state of the opencode bridge and gateway.

.OUTPUTS
  PSCustomObject with: BridgeReady (bool), Port (int), ProcessId (int|null),
  ImagePath (string|null), Uptime (TimeSpan|null), LockFile (string).
#>
function Get-OpenCodeBridgeStatus {
  [CmdletBinding()] param()

  $conn = Get-BridgeConnection
  $procId = $null; $imagePath = $null; $uptime = $null; $ready = $false
  if ($conn -and (Test-BridgeProcess -ProcessId $conn.OwningProcess)) {
    $procId = [int]$conn.OwningProcess
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if ($p) {
      $imagePath = $p.ExecutablePath
      $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($proc.StartTime) { $uptime = (Get-Date) - $proc.StartTime }
      $ready = $true
    }
  }

  [PSCustomObject]@{
    BridgeReady = $ready
    Port         = $script:BridgePort
    ProcessId    = $procId
    ImagePath    = $imagePath
    CmdLine      = $p.CommandLine
    Uptime       = $uptime
    LockFile     = $script:LockFilePath
    LockHeld     = (Test-Path $script:LockFilePath)
  }
}

<#
.SYNOPSIS
  Validates opencode.jsonc + the oh-my-opencode-slim preset for bridge use.

.DESCRIPTION
  Verifies the hermes-nous provider is configured with the local baseURL,
  and that every model referenced by the active preset's roles resolves to
  the hermes-nous provider. Returns $true on success and emits warnings
  (never throws) on drift, so a degraded config doesn't break the wrapper.

.OUTPUTS
  bool — $true when config is coherent and bridge-ready.
#>
function Test-OpenCodeConfig {
  [CmdletBinding()] param()

  # Strip // line comments and /* */ block comments from JSONC, then parse.
  # Only strip comments at line-start and standalone block comments.
  # Do NOT strip trailing // — it would eat URLs like http:// inside string values.
  $stripComments = {
    param([string]$Text)
    $Text = $Text -replace '/\*[\s\S]*?\*/', ''
    $Text = $Text -replace '(?m)^\s*//.*$', ''
    $Text
  }

  # opencode.jsonc
  if (-not (Test-Path $script:OpenCodeConfig)) {
    Write-Warning "[opencode-bridge] Missing config: $($script:OpenCodeConfig)"
    return $false
  }
  try {
    $raw = Get-Content -Raw -LiteralPath $script:OpenCodeConfig
    $json = (& $stripComments $raw) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning "[opencode-bridge] Could not parse $($script:OpenCodeConfig): $_"
    return $false
  }

  $provider = $json.provider.$script:HermesProvider
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

  # oh-my-opencode-slim preset
  if (-not (Test-Path $script:OpenCodeSlimCfg)) {
    Write-Warning "[opencode-bridge] Missing preset config: $($script:OpenCodeSlimCfg)"
    return $false
  }
  try {
    $slim = Get-Content -Raw -LiteralPath $script:OpenCodeSlimCfg | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning "[opencode-bridge] Could not parse preset config: $_"
    return $false
  }

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

  # Verify every role's model is on the hermes-nous provider.
  $roleNames = 'orchestrator','oracle','explorer','librarian','designer','fixer','observer'
  $ok = $true
  foreach ($role in $roleNames) {
    $m = $preset.$role.model
    if (-not $m) { continue }
    if ($m -notmatch "^$([regex]::Escape($script:HermesProvider))/") {
      Write-Warning "[opencode-bridge] Preset '$active' role '$role' uses '$m' — not on '$($script:HermesProvider)'"
      $ok = $false
    }
  }
  return $ok
}

<#
.SYNOPSIS
  Resolves the path to the opencode CLI executable.
#>
function Get-OpenCodePath {
  [CmdletBinding()] param()
  # Prefer the LOCALAPPDATA copy (no spaces in path) to avoid cmd shim issues.
  # The npm install creates a .cmd shim at "C:\Program Files\nodejs\opencode.cmd"
  # which can cause problems with SpawnSync and other shell tooling.
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\opencode\opencode.exe",
    "$env:USERPROFILE\scoop\shims\opencode.exe",
    "C:\Program Files\nodejs\opencode.cmd"
  )
  foreach ($p in $candidates) {
    if (Test-Path $p) { return $p }
  }
  try { return (Get-Command opencode -ErrorAction Stop).Source } catch { }
  return $null
}

Export-ModuleMember -Function Start-OpenCodeBridge, Stop-OpenCodeBridge, Get-OpenCodePath, Get-OpenCodeBridgeStatus, Test-OpenCodeConfig
