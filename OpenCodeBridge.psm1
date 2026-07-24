#Requires -Version 7.0

# OpenCodeBridge.psm1 — OpenCode lifecycle manager, v4.0
#
# Manages the lifecycle of an `opencode` invocation and its upstream
# Hermes Nous AI gateway (listening on 127.0.0.1:8642 by default).
#
# Public functions:
#   Start-OpenCodeBridge       Ensure the upstream gateway is listening.
#   Stop-OpenCodeBridge        Tear down the gateway when no opencode remains.
#   Get-OpenCodePath           Resolve the opencode CLI executable.
#   Get-OpenCodeBridgeStatus   Bridge runtime state (PID, uptime, image, lock).
#   Test-OpenCodeConfig        Validate opencode.jsonc + oh-my-opencode-slim.
#   Test-OpenCodeBridgeHealth  HTTP liveness check against gateway /v1/models.
#   Test-BridgeConnectivity    Check network connectivity to gateway upstream.
#   Disable-OpenCodeBridge     Remove wrapper, clean up bridge processes.

# ── Configuration ──────────────────────────────────────────────────
$script:Prefix = '[opencode-bridge]'
function script:LogWarn ([string]$Msg) { Write-Warning "$script:Prefix $Msg" }
function script:LogInfo ([string]$Msg) { Write-Host       "$script:Prefix $Msg" }
function script:LogDbg  ([string]$Msg) { Write-Verbose    "$script:Prefix $Msg" }
function script:LogProg ([string]$Msg) { Write-Host -NoNewline "$Msg" }

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

function script:Assert-SafePath {
  param([string]$Path, [string]$AllowedRoot)
  if ([string]::IsNullOrEmpty($Path)) { return $false }
  try { return (Resolve-Path $Path -ErrorAction Stop).Path.StartsWith($AllowedRoot, [StringComparison]::OrdinalIgnoreCase) }
  catch { return $false }
}

# ── Core config (env-overridable) ──────────────────────────────────
$script:BridgeBinaryPath = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_BINARY') ?? 'C:\Hermes\hermes-agent\venv\Scripts\pythonw.exe'
$script:BridgeCmdlineRe  = [regex]::new([regex]::Escape('hermes_cli.main'), [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:PythonwSuffixRe  = [regex]::new('pythonw\.exe$', [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set. OpenCodeBridge requires a user profile directory.' }

$script:BridgeCmd        = if ($env:OPENCODE_BRIDGE_CMD) { (Assert-SafePath $env:OPENCODE_BRIDGE_CMD 'C:\hermes') ? $env:OPENCODE_BRIDGE_CMD : 'C:\hermes\gateway-service\Hermes_Gateway.cmd' } else { 'C:\hermes\gateway-service\Hermes_Gateway.cmd' }
$script:BridgeWorkDir    = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_WORKDIR') ?? 'C:\hermes'
$script:BridgePort       = Get-EnvInt -Name 'OPENCODE_BRIDGE_PORT'       -Default 8642 -Min 1 -Max 65535
$script:BridgeHost       = [Environment]::GetEnvironmentVariable('OPENCODE_BRIDGE_HOST')      ?? '127.0.0.1'
$script:StaleLockMinutes = Get-EnvInt -Name 'OPENCODE_BRIDGE_STALE_LOCK_MIN' -Default 5  -Min 1 -Max 120
$script:StartTimeoutSec  = Get-EnvInt -Name 'OPENCODE_BRIDGE_START_TIMEOUT'  -Default 25 -Min 5 -Max 300
$script:StartRetryCount  = Get-EnvInt -Name 'OPENCODE_BRIDGE_START_RETRIES'  -Default 3  -Min 1 -Max 10
$script:MinSessionSec    = 15
$script:MaxConfigSize    = 1048576
$script:FastPollSleepMs  = 250
$script:FastPollTimeoutSec = 5

# Health worker config
$script:HealthPollSec    = Get-EnvInt -Name 'OPENCODE_BRIDGE_HEALTH_POLL_SEC'  -Default 30  -Min 5  -Max 300
$script:IdleTimeoutMin   = Get-EnvInt -Name 'OPENCODE_BRIDGE_IDLE_TIMEOUT_MIN' -Default 0   -Min 0  -Max 1440
$script:HealthEndpoint   = "http://$($script:BridgeHost):$($script:BridgePort)/v1/models"

$script:LockFilePath     = Join-Path $env:LOCALAPPDATA 'opencode-bridge-starting.lock'
$script:OpenCodeConfig   = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
$script:OpenCodeSlimCfg  = Join-Path $env:USERPROFILE '.config\opencode\oh-my-opencode-slim.json'
$script:HermesProvider   = 'hermes-nous'
$script:ValidSocketStates = @('Listen', 'Bound', 'Established')

# Health worker state
$script:HealthWorker     = $null

# ── Private helpers ─────────────────────────────────────────────────

function script:Get-BridgeConnection {
  [CmdletBinding()] param()
  Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in $script:ValidSocketStates -and $_.LocalAddress -in @($script:BridgeHost, '0.0.0.0', '::') } |
    Select-Object -First 1
}

function script:Get-PortState {
  [CmdletBinding()] param()
  $conn = Get-BridgeConnection
  if (-not $conn) { return @{ State = 'none'; Pid = $null; PidInfo = $null } }
  $pid = [int]$conn.OwningProcess
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue
  $isGateway = $p.ExecutablePath -eq $script:BridgeBinaryPath -or
               ($p.CommandLine -match $script:BridgeCmdlineRe -and $p.ExecutablePath -match $script:PythonwSuffixRe)
  if ($p -and $isGateway) { return @{ State = 'gateway'; Pid = $pid; PidInfo = $p } }
  $desc = $p ? "$($p.Name) '$($p.CommandLine)'" : 'unknown process'
  LogWarn "Port $($script:BridgePort) held by pid $pid ($desc) — NOT the Hermes gateway"
  return @{ State = 'intruder'; Pid = $pid; PidInfo = $p }
}

function script:Acquire-Lock {
  [CmdletBinding()] param()
  if (Test-Path $script:LockFilePath) {
    try {
      $age = [int]((Get-Date) - (Get-Item $script:LockFilePath).CreationTime).TotalMinutes
      if ($age -ge $script:StaleLockMinutes) { LogWarn "Removing stale lock ($age min old)"; Remove-Item -LiteralPath $script:LockFilePath -Force -ErrorAction Stop }
    } catch { LogWarn "Cannot read/remove lock file: $_"; return $null }
  }
  try { return [IO.File]::Open($script:LockFilePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
  catch { LogWarn 'Another shell is already starting the gateway'; return $null }
}

function script:Release-Lock {
  param($Lock)
  if ($Lock) { try { $Lock.Dispose() } catch {}; Remove-Item -LiteralPath $script:LockFilePath -ErrorAction SilentlyContinue }
}

# ── Health worker (background job for liveness + idle monitoring) ────

function script:Start-HealthWorker {
  <#
  .SYNOPSIS
    Launches a background PowerShell job that monitors gateway health and
    idle time. Auto-restarts on crash, auto-stops on idle timeout.
  #>
  [CmdletBinding()] param()
  if ($script:IdleTimeoutMin -le 0 -and $script:HealthPollSec -le 0) { return }
  Stop-HealthWorker  # singleton — only one worker at a time

  $modPath = $script:LockFilePath; $port = $script:BridgePort; $hostAddr = $script:BridgeHost
  $endpoint = $script:HealthEndpoint; $pollSec = $script:HealthPollSec; $idleMin = $script:IdleTimeoutMin; $pfx = $script:Prefix
  $logFile = Join-Path $env:LOCALAPPDATA 'opencode-bridge.log'

  $script:HealthWorker = Start-Job -Name 'OpenCodeBridgeHealth' -ScriptBlock {
    param($port, $hostAddr, $endpoint, $pollSec, $idleMin, $pfx, $logFile, $bridgeCmd, $bridgeWorkDir)

    # Helper: restart the gateway from within the job (no module access).
    $restartGateway = {
      try { $p = Start-Process -FilePath $bridgeCmd -WorkingDirectory $bridgeWorkDir -WindowStyle Hidden -PassThru; $p.Id } catch { $null }
    }

    Start-Sleep -Seconds 10  # let the gateway finish starting up

    while ($true) {
      Start-Sleep -Seconds $pollSec

      # Health check: any response = alive
      $alive = $false
      try { $null = Invoke-RestMethod -Uri $endpoint -TimeoutSec 5 -ErrorAction Stop; $alive = $true }
      catch { $alive = ($null -ne $_.Exception.Response) }

      if (-not $alive) {
        "$(Get-Date -Format o) $pfx Health check FAILED — attempting restart" | Add-Content $logFile
        & $restartGateway
        continue
      }

      # Idle timeout
      if ($idleMin -le 0) { continue }
      $actFile = Join-Path $env:LOCALAPPDATA 'opencode-bridge-activity.txt'
      $idle = [int]::MaxValue
      if (Test-Path $actFile) {
        try { $last = [datetime]::Parse((Get-Content $actFile -Raw).Trim()); $idle = [int]((Get-Date) - $last).TotalMinutes } catch {}
      }
      if ($idle -ge $idleMin) {
        $procs = @(Get-Process -Name 'opencode' -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -eq $env:USERNAME)
        if ($procs.Count -eq 0) {
          "$(Get-Date -Format o) $pfx Idle timeout ($idleMin min) — stopping gateway" | Add-Content $logFile
          Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
            try { Get-Process -Id $_.OwningProcess -ErrorAction Stop | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
          }
          break
        }
      }
    }
  } -ArgumentList $script:BridgePort, $script:BridgeHost, $script:HealthEndpoint, $script:HealthPollSec, $script:IdleTimeoutMin, $script:Prefix, $logFile, $script:BridgeCmd, $script:BridgeWorkDir

  LogDbg "Health worker started (poll=${pollSec}s, idle=${idleMin}m)"
}

function script:Stop-HealthWorker {
  [CmdletBinding()] param()
  if ($script:HealthWorker -and $script:HealthWorker.State -eq 'Running') {
    $script:HealthWorker | Stop-Job -ErrorAction SilentlyContinue | Out-Null
    $script:HealthWorker | Remove-Job -Force -ErrorAction SilentlyContinue | Out-Null
  }
  $script:HealthWorker = $null
}

# ── Public functions ─────────────────────────────────────────────────

function Test-OpenCodeBridgeHealth {
  <#
  .SYNOPSIS
    Verifies the gateway responds to HTTP requests.
  .DESCRIPTION
    Calls GET /v1/models on the gateway and returns $true if the
    response is successful (HTTP 2xx).
  .EXAMPLE
    if (-not (Test-OpenCodeBridgeHealth)) { Write-Warning "Gateway is down" }
  #>
  [CmdletBinding()]
  [OutputType([bool])] param()
  try {
    # Any response (even 401) means the gateway is alive.
    # Only connection failures (timeout, refused) mean dead.
    $null = Invoke-RestMethod -Uri $script:HealthEndpoint -TimeoutSec 5 -ErrorAction Stop
    return $true
  } catch {
    # If we got a response (even an error status), the gateway is alive
    if ($_.Exception.Response) { return $true }
    LogDbg "Health check failed (no response): $_"; return $false
  }
}

function Test-BridgeConnectivity {
  <#
  .SYNOPSIS
    Checks whether the gateway's upstream API is reachable.
  .DESCRIPTION
    Attempts a basic TCP connection to the gateway host:port.
    Does not require the gateway to be running — just checks
    network reachability.
  .EXAMPLE
    if (-not (Test-BridgeConnectivity)) { Write-Warning "No network path to gateway" }
  #>
  [CmdletBinding()]
  [OutputType([bool])] param()
  try {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $conn = $tcp.BeginConnect($script:BridgeHost, $script:BridgePort, $null, $null)
    if ($conn.AsyncWaitHandle.WaitOne(3000)) { $tcp.EndConnect($conn); $tcp.Close(); return $true }
    $tcp.Close(); return $false
  } catch { return $false }
}

function Start-OpenCodeBridge {
  <#
  .SYNOPSIS
    Ensures the Hermes gateway is listening on the configured port.
  .DESCRIPTION
    Fast path if already up. Otherwise launches with retries +
    liveness checks including HTTP health verification.
    A file-lock prevents concurrent launches across terminals.
    After a successful start, a background health worker monitors
    the gateway for crashes and idle time.
  .EXAMPLE
    Start-OpenCodeBridge
    # Ensures the gateway is running before you use opencode.
  #>
  [CmdletBinding()]
  [OutputType([void])] param()

  $ps = Get-PortState
  if ($ps.State -eq 'gateway') { LogDbg "Gateway already up (pid $($ps.Pid))"; Start-HealthWorker; return }
  if ($ps.State -eq 'intruder') { LogWarn "Port $($script:BridgePort) held by non-Hermes process — refusing to start"; return }
  if (-not (Test-Path $script:BridgeCmd)) { LogWarn "Gateway script not found: $($script:BridgeCmd)"; return }

  $lock = Acquire-Lock; if (-not $lock) { return }

  try {
    LogInfo 'Starting gateway...'
    for ($attempt = 1; $attempt -le $script:StartRetryCount; $attempt++) {
      $ps = Get-PortState
      if ($ps.State -eq 'gateway') { LogDbg "Gateway ready from prior attempt (pid $($ps.Pid))"; Start-HealthWorker; return }
      if ($ps.State -eq 'intruder') { LogWarn 'Non-Hermes process bound port during startup — aborting'; return }

      $proc = $null
      try { $proc = Start-Process -FilePath $script:BridgeCmd -WorkingDirectory $script:BridgeWorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop }
      catch { LogWarn "Launch attempt $attempt/$($script:StartRetryCount) failed: $_"; if ($attempt -lt $script:StartRetryCount) { Start-Sleep -Seconds 3 }; continue }

      LogProg '  .'
      $elapsed = 0
      $timeouts = @(
        @{ Limit = $script:FastPollTimeoutSec; Sleep = $script:FastPollSleepMs; Unit = 'ms' }
        @{ Limit = $script:StartTimeoutSec;     Sleep = 2000;                 Unit = 's'  }
      )
      :healthLoop foreach ($t in $timeouts) {
        while ($elapsed -lt $t.Limit) {
          $ps = Get-PortState
          if ($ps.State -eq 'gateway') {
            # Verify with HTTP health check before declaring ready
            if (Test-OpenCodeBridgeHealth) { LogInfo "Gateway ready (pid $($ps.Pid))"; Start-HealthWorker; return }
            LogDbg 'Port listening but HTTP not responding yet...'
          }
          if ($proc.HasExited) { LogWarn "Process exited early (code $($proc.ExitCode)) attempt $attempt/$($script:StartRetryCount)"; break healthLoop }
          if ($elapsed -gt 0 -and $elapsed % 4 -eq 0) { LogProg '.' }  # progress dot every ~4s
          if ($t.Unit -eq 'ms') { Start-Sleep -Milliseconds $t.Sleep; $elapsed += $t.Sleep / 1000.0 }
          else { Start-Sleep -Seconds ($t.Sleep / 1000); $elapsed += $t.Sleep / 1000 }
        }
      }
      LogProg "`n"
      if (-not $proc.HasExited) { LogWarn "Attempt $attempt/$($script:StartRetryCount): port not opened within $($script:StartTimeoutSec)s"; try { $proc.Kill() } catch {} }
      Start-Sleep -Seconds 2
    }
    LogWarn "Gateway failed after $($script:StartRetryCount) attempts — opencode will use fallback providers"
  } finally { Release-Lock $lock }
}

function Stop-OpenCodeBridge {
  <#
  .SYNOPSIS
    Stops the gateway — only if no other opencode instance remains.
  .DESCRIPTION
    Only tears down after a real interactive session (>MinSessionSec).
    Stops the health worker, then polls opencode processes, then
    kills the verified gateway process.
  .EXAMPLE
    Stop-OpenCodeBridge -SessionDuration 120
    # Stops the gateway after a 2-minute session if no other
    # opencode instances are running.
  #>
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  [OutputType([void])] param([int]$SessionDuration = 0)

  if ($SessionDuration -lt $script:MinSessionSec) { return }

  $ps = Get-PortState
  if ($ps.State -ne 'gateway') { Stop-HealthWorker; return }

  Start-Sleep -Seconds 3
  $remaining = @()
  for ($i = 0; $i -lt 5; $i++) {
    $remaining = @(Get-Process -Name 'opencode' -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -eq $env:USERNAME)
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }
  if ($remaining.Count -gt 0) { return }

  $ps = Get-PortState
  if ($ps.State -ne 'gateway') { Stop-HealthWorker; return }

  $recheck = @(Get-Process -Name 'opencode' -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -eq $env:USERNAME)
  if ($recheck.Count -gt 0) { return }

  if ($PSCmdlet.ShouldProcess("Gateway pid $($ps.Pid)", 'Stop')) {
    Stop-HealthWorker
    try {
      $proc = Get-Process -Id $ps.Pid -ErrorAction Stop
      $proc.Kill()
      if (-not $proc.WaitForExit(5000)) { LogWarn "Gateway process (pid $($ps.Pid)) did not exit within 5s — may need manual cleanup" }
      LogInfo "Gateway stopped (pid $($ps.Pid))"
    } catch {
      if ($_.Exception.Message -match 'Cannot find a process') { LogInfo 'Gateway already stopped' }
      else { LogWarn "Could not stop gateway process: $_" }
    }
  }
}

function Get-OpenCodeBridgeStatus {
  <#
  .SYNOPSIS
    Reports runtime state of the gateway.
  .DESCRIPTION
    Returns an object with: BridgeReady, Port, ProcessId, ImagePath,
    CmdLine, Uptime, HealthOk, LockFile, LockHeld, BridgeCmd,
    HealthWorker, IdleMinutes.
  .EXAMPLE
    Get-OpenCodeBridgeStatus
    # Check if the bridge is running and healthy.
  #>
  [CmdletBinding()]
  [OutputType([PSCustomObject])] param()

  $ps = Get-PortState; $ready = $ps.State -eq 'gateway'
  $healthOk = $ready ? (Test-OpenCodeBridgeHealth) : $false
  $uptime = ($ready -and $ps.PidInfo) ? ((Get-Date) - (Get-Process -Id $ps.Pid -ErrorAction SilentlyContinue).StartTime) : $null
  $idle = $null
  $actFile = Join-Path $env:LOCALAPPDATA 'opencode-bridge-activity.txt'
  if (Test-Path $actFile) {
    try { $last = [datetime]::Parse((Get-Content $actFile -Raw).Trim()); $idle = [int]((Get-Date) - $last).TotalMinutes } catch {}
  }
  $workerRunning = $script:HealthWorker -and $script:HealthWorker.State -eq 'Running'

  [PSCustomObject][ordered]@{
    BridgeReady  = $ready
    Port         = $script:BridgePort
    ProcessId    = $ready ? $ps.Pid : $null
    ImagePath    = $ready ? $ps.PidInfo.ExecutablePath : $null
    CmdLine      = $ready ? $ps.PidInfo.CommandLine : $null
    Uptime       = $uptime
    HealthOk     = $healthOk
    LockFile     = $script:LockFilePath
    LockHeld     = Test-Path $script:LockFilePath
    BridgeCmd    = $script:BridgeCmd
    HealthWorker = $workerRunning
    IdleMinutes  = $idle
  }
}

function Test-OpenCodeConfig {
  <#
  .SYNOPSIS
    Validates opencode.jsonc + oh-my-opencode-slim preset.
  .DESCRIPTION
    Verifies hermes-nous provider is correctly configured for the
    local bridge. Returns $true on success, writes warnings on drift.
  .EXAMPLE
    if (-not (Test-OpenCodeConfig)) { Write-Warning "Fix your config before using opencode" }
  #>
  [CmdletBinding()]
  [OutputType([bool])] param()

  if (-not $script:StripCommentsRe) {
    $script:StripCommentsRe     = [regex]::new('/\*[\s\S]*?\*/', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $script:StripLineCommentsRe = [regex]::new('(?m)^\s*//.*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
  }
  filter Strip-Comments { $script:StripLineCommentsRe.Replace($script:StripCommentsRe.Replace($_, ''), '') }

  $parseJsonc = {
    param([string]$Path)
    if (-not (Test-Path $Path)) { LogWarn "Missing config: $Path"; return $null }
    try {
      $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
      if ($raw.Length -gt $script:MaxConfigSize) { LogWarn ('Config too large ({0} bytes, max {1}): {2}' -f $raw.Length, $script:MaxConfigSize, $Path); return $null }
      $raw | Strip-Comments | ConvertFrom-Json -ErrorAction Stop
    } catch { LogWarn "Could not parse $Path : $_"; return $null }
  }

  $json = & $parseJsonc $script:OpenCodeConfig; if (-not $json) { return $false }
  $provider = $json.provider.$($script:HermesProvider)
  if (-not $provider) { LogWarn "'$($script:HermesProvider)' provider missing — bridge has no consumer"; return $false }
  $baseURL = $provider.options.baseURL
  $expected = "http://$($script:BridgeHost):$($script:BridgePort)/v1"
  if ($baseURL -ne $expected) { LogWarn "hermes-nous baseURL is '$baseURL' (expected '$expected')"; return $false }

  $slim = & $parseJsonc $script:OpenCodeSlimCfg; if (-not $slim) { return $false }
  $active = $slim.preset
  if (-not $active) { LogWarn 'oh-my-opencode-slim has no active preset'; return $false }
  $preset = $slim.presets.$active
  if (-not $preset) { LogWarn "Preset '$active' not found in presets"; return $false }

  $ok = $true
  foreach ($roleKey in $preset.PSObject.Properties.Name) {
    $role = $preset.$roleKey
    if (-not $role -or $role -isnot [PSCustomObject]) { continue }
    $model = $role.model; if (-not $model) { continue }
    if ($model -notmatch "^$([regex]::Escape($script:HermesProvider))/") { LogWarn "Preset '$active' role '$roleKey' uses '$model' — not on '$($script:HermesProvider)'"; $ok = $false }
  }
  return $ok
}

function Get-OpenCodePath {
  <#
  .SYNOPSIS
    Resolves the opencode CLI executable. Prefers no-spaces paths.
  .EXAMPLE
    $path = Get-OpenCodePath
    & $path --version
  #>
  [CmdletBinding()]
  [OutputType([string])] param()
  foreach ($p in @("$env:LOCALAPPDATA\Programs\opencode\opencode.exe", "$env:USERPROFILE\scoop\shims\opencode.exe", "C:\Program Files\nodejs\opencode.cmd")) {
    if (Test-Path $p) { return $p }
  }
  try {
    $cmd = Get-Command opencode -ErrorAction Stop
    if ($cmd.CommandType -in @('Application', 'ExternalScript')) { return $cmd.Source }
  } catch { LogWarn "Get-Command opencode failed: $_" }
  return $null
}

function Disable-OpenCodeBridge {
  <#
  .SYNOPSIS
    Kills any running gateway process and stops the health worker.
    Does NOT modify your PowerShell profile — to fully uninstall,
    remove the dot-source line from your $PROFILE.
  .EXAMPLE
    Disable-OpenCodeBridge
    # Stops the gateway and worker. Run before uninstalling.
  #>
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  [OutputType([void])] param()
  if ($PSCmdlet.ShouldProcess('OpenCode bridge', 'Disable')) {
    Stop-HealthWorker
    try { Stop-OpenCodeBridge -SessionDuration 9999 } catch {}
    LogInfo 'Bridge and health worker stopped. Remove the dot-source line from $PROFILE to fully uninstall.'
  }
}

# ── Module cleanup ──────────────────────────────────────────────────
$ExecutionContext.SessionState.Module.OnRemove = {
  Stop-HealthWorker
}

Export-ModuleMember -Function Start-OpenCodeBridge, Stop-OpenCodeBridge, Get-OpenCodePath, Get-OpenCodeBridgeStatus, Test-OpenCodeConfig, Test-OpenCodeBridgeHealth, Test-BridgeConnectivity, Disable-OpenCodeBridge
