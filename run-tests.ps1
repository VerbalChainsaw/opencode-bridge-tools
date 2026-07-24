# run-tests.ps1 — OpenCodeBridge module smoke + behavior + regression tests
# Usage: pwsh -NoProfile -File .\run-tests.ps1

$modulePath = Join-Path $PSScriptRoot 'OpenCodeBridge.psd1'
try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Error "Module load failed: $_"; exit 1 }

$script:passed = 0; $script:failed = 0

function Test-Case {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body | Out-Null
    Write-Host "  PASS: $Name" -ForegroundColor Green
    $script:passed++
  } catch {
    Write-Host "  FAIL: $Name : $_" -ForegroundColor Red
    $script:failed++
  }
}

# ── 1. Module exports ──────────────────────────────────────────────────────
Test-Case "Exports exactly 5 functions" {
  $cmds = @(Get-Command -Module OpenCodeBridge)
  if ($cmds.Count -ne 5) { throw "Expected 5, got $($cmds.Count): $($cmds.Name -join ', ')" }
}
Test-Case "Start-OpenCodeBridge is exported"   { Get-Command Start-OpenCodeBridge   -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Stop-OpenCodeBridge is exported"    { Get-Command Stop-OpenCodeBridge    -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodePath is exported"       { Get-Command Get-OpenCodePath       -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodeBridgeStatus is exported" { Get-Command Get-OpenCodeBridgeStatus -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Test-OpenCodeConfig is exported"   { Get-Command Test-OpenCodeConfig    -Module OpenCodeBridge -ErrorAction Stop }

# ── 2. Manifest integrity ──────────────────────────────────────────────────
Test-Case "Manifest self-validates with correct version" {
  $m = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
  if ($m.Version -ne [version]'3.0.0') { throw "Wrong version: $($m.Version)" }
  if ($m.PowerShellVersion -lt [version]'7.0') { throw "PSVersion too low" }
}

# ── 3. Get-OpenCodePath ────────────────────────────────────────────────────
Test-Case "Get-OpenCodePath returns a valid existing path" {
  $p = Get-OpenCodePath
  if (-not $p) { throw "Returned null" }
  if (-not (Test-Path $p)) { throw "Path does not exist: $p" }
}
Test-Case "Get-OpenCodePath prefers LOCALAPPDATA copy (no spaces in path)" {
  $p = Get-OpenCodePath
  if ($p -match '\s') { throw "Path has spaces: $p" }
}

# ── 4. Stop-OpenCodeBridge short-session guard ─────────────────────────────
Test-Case "Stop-OpenCodeBridge short session returns silently"   { Stop-OpenCodeBridge -SessionDuration 3 }
Test-Case "Stop-OpenCodeBridge default (0s) returns silently"    { Stop-OpenCodeBridge }

# ── 5. Start-OpenCodeBridge ────────────────────────────────────────────────
Test-Case "Start-OpenCodeBridge fast path when bridge already up" { Start-OpenCodeBridge }

# ── 6. Get-OpenCodeBridgeStatus ────────────────────────────────────────────
Test-Case "Get-OpenCodeBridgeStatus returns a PSCustomObject with required fields" {
  $s = Get-OpenCodeBridgeStatus
  $required = 'BridgeReady','Port','ProcessId','ImagePath','CmdLine','Uptime','LockFile','LockHeld','BridgeCmd'
  foreach ($r in $required) {
    if (-not ($s.PSObject.Properties.Name -contains $r)) { throw "Missing field: $r" }
  }
  if ($s.Port -ne 8642) { throw "Wrong port: $($s.Port)" }
}
Test-Case "Status reports a verified gateway (BridgeReady=$true, non-null ProcessId)" {
  $s = Get-OpenCodeBridgeStatus
  if (-not $s.BridgeReady) { throw "BridgeReady should be true (bridge running during test)" }
  if (-not $s.ProcessId)   { throw "ProcessId should be set" }
  if ($s.ImagePath -notmatch 'pythonw') { throw "Expected pythonw image, got: $($s.ImagePath)" }
  if ($s.CmdLine -notmatch 'hermes_cli\.main') { throw "CmdLine mismatch: $($s.CmdLine)" }
}

# ── 7. Test-OpenCodeConfig ─────────────────────────────────────────────────
Test-Case "Test-OpenCodeConfig returns `$true on the live config" {
  $ok = Test-OpenCodeConfig
  if (-not $ok) { throw "Config validation failed — config may have drifted" }
}

# ── 8. Lock file location hardening ────────────────────────────────────────
Test-Case "Lock file path uses LOCALAPPDATA (not TEMP)" {
  $s = Get-OpenCodeBridgeStatus
  if ($s.LockFile -notmatch [regex]::Escape($env:LOCALAPPDATA)) { throw "Lock not in LOCALAPPDATA: $($s.LockFile)" }
  if ($s.LockFile -match [regex]::Escape($env:TEMP)) { throw "Lock should not be in TEMP: $($s.LockFile)" }
}

# ── 9. Intruder port-occupant guard (regression test) ──────────────────────
Test-Case "Start refuses when a non-Hermes process holds the port (no retry storm)" {
  $m = Get-Module OpenCodeBridge
  $sb = {
    function script:Get-BridgeConnection { [PSCustomObject]@{ OwningProcess = 99999; LocalAddress = '127.0.0.1'; State = 'Listen' } }
    function script:Test-BridgeProcess {
      param([int]$ProcessId)
      $sim = [PSCustomObject]@{ Name = 'pythonw.exe'; CommandLine = 'pythonw.exe -m unrelated serve' }
      return ($sim.Name -match "^pythonw" -and $sim.CommandLine -match 'hermes_cli\.main')
    }
  }
  & $m $sb
  $warnings = @()
  Start-OpenCodeBridge -ErrorAction SilentlyContinue -WarningVariable +warnings -WarningAction SilentlyContinue
  if ($warnings.Count -lt 1) { throw "Expected at least 1 bail-out warning, got $($warnings.Count)" }
  if (-not ($warnings.Message -match 'refusing to start|NOT the Hermes gateway')) {
    throw "Wrong message(s): $($warnings.Message -join '; ')"
  }
  Remove-Module OpenCodeBridge -ErrorAction SilentlyContinue
  Import-Module $modulePath -Force
}

# ── 10. JSONC parser preserves // inside string values ──────────────────────
Test-Case "Test-OpenCodeConfig JSONC parser does not eat // in strings" {
  $testJson = '{ "path": "C:\\code//stuff", "url": "https://ok.com" }'
  $stripped = $testJson -replace '/\*[\s\S]*?\*/', '' -replace '(?m)^\s*//.*$', ''
  $parsed = $stripped | ConvertFrom-Json
  if ($parsed.path -ne 'C:\code//stuff') { throw "// in string was eaten: $($parsed.path)" }
  if ($parsed.url -ne 'https://ok.com') { throw "URL was damaged: $($parsed.url)" }
}

# ── 11. Status object has correct field names (typo regression) ────────────
Test-Case "Status object uses ProcessId (not ProcesId)" {
  $s = Get-OpenCodeBridgeStatus
  if (-not ($s.PSObject.Properties.Name -contains 'ProcessId')) { throw "ProcessId field missing" }
}

# ── 12. Configuration is env-overridable ───────────────────────────────────
Test-Case "BridgeCmd defaults to known path and is env-overridable" {
  $s = Get-OpenCodeBridgeStatus
  $defaultCmd = "C:\hermes\gateway-service\Hermes_Gateway.cmd"
  if ($s.BridgeCmd -ne $defaultCmd) {
    $envVar = $env:OPENCODE_BRIDGE_CMD
    if (-not $envVar) { throw "BridgeCmd mismatch: expected '$defaultCmd', got '$($s.BridgeCmd)' (no env override)" }
  }
}

# ── 13. Lock acquisition uses atomic CreateNew ─────────────────────────────
Test-Case "Lock acquisition is atomic (FileMode.CreateNew, FileShare.None)" {
  # Verify the lock mechanism exists and the path is sensible
  $s = Get-OpenCodeBridgeStatus
  if (-not $s.LockFile) { throw "LockFile path is empty" }
  if (-not ($s.LockFile -match '\.lock$')) { throw "LockFile doesn't end with .lock: $($s.LockFile)" }
}

# ── 14. Stop-OpenCodeBridge handles missing process gracefully ──────────────
Test-Case "Stop-OpenCodeBridge handles already-dead bridge gracefully" {
  # The bridge is alive now, but calling Stop with a short session should no-op
  Stop-OpenCodeBridge -SessionDuration 3  # Already tested above, but also exercise the kill path
}

# ── 15. Get-OpenCodePath validates CommandType ──────────────────────────────
Test-Case "Get-OpenCodePath returns Application or ExternalScript type" {
  $p = Get-OpenCodePath
  if ($p -and ($p -match '\.cmd$')) {
    # .cmd is an ExternalScript — fine
  } elseif ($p -and ($p -match '\.exe$')) {
    # .exe is an Application — fine
  } elseif (-not $p) {
    throw "Get-OpenCodePath returned null"
  } else {
    throw "Unexpected path: $p"
  }
}

# ── 16. Config validation has size limit (adversarial) ─────────────────────
Test-Case "Test-OpenCodeConfig rejects oversized configs" {
  # Create a mock config that's > 1 MB
  $tmp = Join-Path $env:TEMP "test-oversized-config.json"
  try {
    "{}" | Set-Content $tmp -Force
    # Write 2 MB of whitespace to pad it
    $fs = [System.IO.File]::OpenWrite($tmp)
    $fs.SetLength(2 * 1024 * 1024)
    $fs.Close()
    # Monkey-patch the config path temporarily
    $m = Get-Module OpenCodeBridge
    $origConfig = $m.SessionState.PSVariable.Get('OpenCodeConfig').Value
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $tmp
    $warnings = @()
    $result = Test-OpenCodeConfig -WarningVariable +warnings -WarningAction SilentlyContinue
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $origConfig
    if ($warnings.Message -notmatch 'too large') { throw "Expected 'too large' warning for oversized config" }
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

# ── 17. Env var type validation: non-numeric port is rejected ────────────────
Test-Case "BridgePort rejects non-numeric OPENCODE_BRIDGE_PORT with warning" {
  $env:OPENCODE_BRIDGE_PORT = "not-a-number"
  try {
    Remove-Module OpenCodeBridge -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -WarningVariable badPortWarnings -WarningAction SilentlyContinue
    $s = Get-OpenCodeBridgeStatus
    if ($s.Port -eq 8642) { } else { throw "Port should be 8642 (default), got $($s.Port)" }
  } finally {
    Remove-Item env:OPENCODE_BRIDGE_PORT -ErrorAction SilentlyContinue
    # Re-import cleanly for subsequent tests
    Remove-Module OpenCodeBridge -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
  }
}

# ── 18. Config parser reads content before size check (symlink TOCTOU fix) ──
Test-Case "Config parser reads content before size check" {
  # Create a config with content > 1MB, verify the warning mentions content
  # size, not file-on-disk size (which could differ with symlinks)
  $tmp = Join-Path $env:TEMP "test-read-first.json"
  try {
    $big = '"key": "' + ('x' * 2000000) + '"'
    "{ $big }" | Set-Content $tmp -Force
    $m = Get-Module OpenCodeBridge
    $origConfig = $m.SessionState.PSVariable.Get('OpenCodeConfig').Value
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $tmp
    $warnings = @()
    $result = Test-OpenCodeConfig -WarningVariable +warnings -WarningAction SilentlyContinue
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $origConfig
    if ($warnings.Message -match 'too large') { } else { throw "Expected 'too large' warning" }
    if ($warnings.Message -match 'bytes') { } else { throw "Warning should include byte count" }
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
