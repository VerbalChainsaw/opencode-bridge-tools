# HermesBridge.psm1 - Hermes Nous Bridge lifecycle management
# Provides Start-HermesBridge and Stop-HermesBridge for the Hermes Gateway
# service that proxies Nous Research subscription models to OpenCode.

# ── Configuration ──────────────────────────────────────────────────
$script:BridgeCmd    = "C:\hermes\gateway-service\Hermes_Gateway.cmd"
$script:BridgeWorkDir = "C:\hermes"
$script:BridgePort   = 8642
$script:LockFile     = "$env:TEMP\.hermes-bridge-starting.lock"
$script:SessionDuration = 0

<#
.SYNOPSIS
  Ensures the Hermes Nous bridge is running on port 8642.
.DESCRIPTION
  Checks if the bridge is already listening. If not, launches the Hermes
  Gateway via Hermes_Gateway.cmd with up to 3 retries and waits up to 25s
  per attempt for the port to open. Uses a file lock to prevent concurrent
  launches from multiple terminal sessions (TOCTOU guard). Monitors process
  liveness during the health check so dead processes abort early.
#>
function Start-HermesBridge {
  [CmdletBinding()]
  param()

  # Fast path: already running
  $existing = Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue
  if ($existing) { return }

  # Bail if gateway script is missing
  if (-not (Test-Path $script:BridgeCmd)) {
    Write-Warning "[hermes] Gateway script not found: $($script:BridgeCmd)"
    return
  }

  # File lock: avoid TOCTOU race when two terminals open simultaneously
  $lock = $null
  try {
    $lock = [System.IO.File]::Open(
      $script:LockFile,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
  } catch {
    Write-Warning "[hermes] Another shell is already starting the bridge"
    return
  }

  try {
    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
      try {
        $proc = Start-Process -FilePath $script:BridgeCmd `
          -WorkingDirectory $script:BridgeWorkDir `
          -WindowStyle Hidden -PassThru -ErrorAction Stop
      } catch {
        Write-Warning "[hermes] Launch attempt $attempt/${maxRetries} failed: $_"
        if ($attempt -lt $maxRetries) { Start-Sleep -Seconds 3 }
        continue
      }

      # Health check: wait for port, checking process liveness each cycle
      $timeout = 25
      $elapsed = 0
      while ($elapsed -lt $timeout) {
        $listening = Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue
        if ($listening) {
          Write-Host "[hermes] Bridge ready (pid $($listening.OwningProcess))"
          return
        }
        if ($proc.HasExited) {
          Write-Warning "[hermes] Process exited early (code $($proc.ExitCode)) on attempt $attempt/${maxRetries}"
          break
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
      }

      if (-not $proc.HasExited) {
        Write-Warning "[hermes] Attempt $attempt/${maxRetries}: port ${script:BridgePort} not opened within ${timeout}s"
        try { $proc.Kill() } catch { Write-Warning "[hermes] Could not kill hung process: $_" }
      }
      Start-Sleep -Seconds 2
    }

    Write-Warning "[hermes] Bridge failed after $maxRetries attempts — OpenCode will use fallback providers"
  } finally {
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $script:LockFile -ErrorAction SilentlyContinue
  }
}

<#
.SYNOPSIS
  Stops the Hermes Nous bridge if no OpenCode instances remain.
.DESCRIPTION
  Only kills the bridge after a real interactive session (>15s runtime).
  Waits up to 5s for OpenCode to fully exit, polls for remaining processes.
  Uses WaitForExit(5000) to give the bridge process time to shut down cleanly.
#>
function Stop-HermesBridge {
  [CmdletBinding()]
  param(
    [int]$SessionDuration = $script:SessionDuration
  )

  # Only kill bridge after a real interaction (ran > 15s), not quick CLI commands
  if ($SessionDuration -lt 15) { return }

  # Wait for OpenCode to fully exit, then confirm no other instances
  Start-Sleep -Seconds 3
  for ($i = 0; $i -lt 5; $i++) {
    $remaining = Get-Process -Name "opencode" -ErrorAction SilentlyContinue
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Seconds 1
  }
  if ((Get-Process -Name "opencode" -ErrorAction SilentlyContinue).Count -gt 0) { return }

  $conn = Get-NetTCPConnection -LocalPort $script:BridgePort -ErrorAction SilentlyContinue
  if (-not $conn) { return }

  try {
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction Stop
    if ($proc.ProcessName -match 'python|cmd') {
      $proc.Kill()
      $proc.WaitForExit(5000) | Out-Null
      Write-Host "[hermes] Bridge stopped"
    }
  } catch {
    Write-Warning "[hermes] Could not stop bridge process: $_"
  }
}

Export-ModuleMember -Function Start-HermesBridge, Stop-HermesBridge
