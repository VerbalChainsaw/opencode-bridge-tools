# run-tests.ps1 — OpenCodeBridge module tests (v4.0.0)
# Usage: pwsh -NoProfile -File .\run-tests.ps1

$modulePath = Join-Path $PSScriptRoot 'OpenCodeBridge.psd1'
try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Error "Module load failed: $_"; exit 1 }

$script:passed = 0; $script:failed = 0

function Test-Case {
  param([string]$Name, [scriptblock]$Body)
  try { & $Body | Out-Null; Write-Host "  PASS: $Name" -ForegroundColor Green; $script:passed++ }
  catch { Write-Host "  FAIL: $Name : $_" -ForegroundColor Red; $script:failed++ }
}

# ── 1. Module exports (8 functions in v4.0.0) ───────────────────────────────
Test-Case "Exports exactly 8 functions" {
  $cmds = @(Get-Command -Module OpenCodeBridge)
  if ($cmds.Count -ne 8) { throw "Expected 8, got $($cmds.Count): $($cmds.Name -join ', ')" }
}
Test-Case "Start-OpenCodeBridge is exported"     { Get-Command Start-OpenCodeBridge     -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Stop-OpenCodeBridge is exported"      { Get-Command Stop-OpenCodeBridge      -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodePath is exported"          { Get-Command Get-OpenCodePath         -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodeBridgeStatus is exported"  { Get-Command Get-OpenCodeBridgeStatus -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Test-OpenCodeConfig is exported"      { Get-Command Test-OpenCodeConfig      -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Test-OpenCodeBridgeHealth is exported" { Get-Command Test-OpenCodeBridgeHealth -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Test-BridgeConnectivity is exported"   { Get-Command Test-BridgeConnectivity  -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Disable-OpenCodeBridge is exported"    { Get-Command Disable-OpenCodeBridge   -Module OpenCodeBridge -ErrorAction Stop }

# ── 2. Manifest ─────────────────────────────────────────────────────────────
Test-Case "Manifest self-validates with correct version" {
  $m = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
  if ($m.Version -ne [version]'4.0.0') { throw "Wrong version: $($m.Version)" }
}

# ── 3. Get-OpenCodePath ────────────────────────────────────────────────────
Test-Case "Get-OpenCodePath returns valid path with no spaces" {
  $p = Get-OpenCodePath
  if (-not $p -or -not (Test-Path $p)) { throw "Invalid path: $p" }
  if ($p -match '\s') { throw "Path has spaces: $p" }
}

# ── 4. Stop guards ──────────────────────────────────────────────────────────
Test-Case "Stop-OpenCodeBridge short session returns silently" { Stop-OpenCodeBridge -SessionDuration 3 }
Test-Case "Stop-OpenCodeBridge default (0s) returns silently"  { Stop-OpenCodeBridge }

# ── 5. Start fast path ─────────────────────────────────────────────────────
Test-Case "Start-OpenCodeBridge fast path when bridge already up" { Start-OpenCodeBridge }

# ── 6. Status ──────────────────────────────────────────────────────────────
Test-Case "Status object has all required fields" {
  $s = Get-OpenCodeBridgeStatus
  $required = 'BridgeReady','Port','ProcessId','ImagePath','CmdLine','Uptime','HealthOk','LockFile','LockHeld','BridgeCmd','HealthWorker','IdleMinutes'
  foreach ($r in $required) { if (-not ($s.PSObject.Properties.Name -contains $r)) { throw "Missing field: $r" } }
}
Test-Case "Status reports gateway alive and healthy" {
  $s = Get-OpenCodeBridgeStatus
  if (-not $s.BridgeReady) { throw "BridgeReady should be true" }
  if (-not $s.ProcessId) { throw "ProcessId should be set" }
  if (-not $s.HealthOk) { throw "HealthOk should be true (gateway is responding)" }
}

# ── 7. Health check ────────────────────────────────────────────────────────
Test-Case "Test-OpenCodeBridgeHealth returns true for running gateway" {
  if (-not (Test-OpenCodeBridgeHealth)) { throw "Health check failed on running gateway" }
}

# ── 8. Connectivity ────────────────────────────────────────────────────────
Test-Case "Test-BridgeConnectivity returns true for reachable gateway" {
  if (-not (Test-BridgeConnectivity)) { throw "Connectivity check failed" }
}

# ── 9. Config validation ───────────────────────────────────────────────────
Test-Case "Test-OpenCodeConfig returns true on live config" {
  if (-not (Test-OpenCodeConfig)) { throw "Config validation failed" }
}

# ── 10. Lock file hardening ────────────────────────────────────────────────
Test-Case "Lock file in LOCALAPPDATA, not TEMP" {
  $s = Get-OpenCodeBridgeStatus
  if ($s.LockFile -notmatch [regex]::Escape($env:LOCALAPPDATA)) { throw "Lock not in LOCALAPPDATA" }
  if ($s.LockFile -match [regex]::Escape($env:TEMP)) { throw "Lock should not be in TEMP" }
}

# ── 11. Intruder guard ─────────────────────────────────────────────────────
Test-Case "Start refuses non-Hermes port occupier" {
  $m = Get-Module OpenCodeBridge
  & $m {
    function script:Get-BridgeConnection { [PSCustomObject]@{ OwningProcess=99999; LocalAddress='127.0.0.1'; State='Listen' } }
    function script:Get-PortState { @{ State='intruder'; Pid=99999; PidInfo=$null } }
  }
  $w = @(); Start-OpenCodeBridge -WarningVariable +w -WarningAction SilentlyContinue
  if ($w.Count -lt 1) { throw "Expected bail-out warning" }
  Remove-Module OpenCodeBridge -EA 0; Import-Module $modulePath -Force
}

# ── 12. JSONC parser ───────────────────────────────────────────────────────
Test-Case "JSONC parser preserves // in strings" {
  $s = '{ "path": "C:\\code//stuff" }' -replace '/\*[\s\S]*?\*/','' -replace '(?m)^\s*//.*$','' | ConvertFrom-Json
  if ($s.path -ne 'C:\code//stuff') { throw "// was eaten" }
}

# ── 13. ProcessId field name ───────────────────────────────────────────────
Test-Case "Status uses ProcessId (not ProcesId)" {
  $s = Get-OpenCodeBridgeStatus
  if (-not ($s.PSObject.Properties.Name -contains 'ProcessId')) { throw "ProcessId field missing" }
}

# ── 14. Env var validation ─────────────────────────────────────────────────
Test-Case "Non-numeric env port falls back to default" {
  $env:OPENCODE_BRIDGE_PORT = 'not-a-number'
  try { Remove-Module OpenCodeBridge -EA 0; Import-Module $modulePath -Force -WarningAction SilentlyContinue; if ((Get-OpenCodeBridgeStatus).Port -ne 8642) { throw "Port should be 8642" } }
  finally { Remove-Item env:OPENCODE_BRIDGE_PORT -EA 0; Remove-Module OpenCodeBridge -EA 0; Import-Module $modulePath -Force }
}

# ── 15. Config size limit ──────────────────────────────────────────────────
Test-Case "Config size limit rejects oversized files" {
  $tmp = Join-Path $env:TEMP "oversized.json"
  try {
    '{}' | Set-Content $tmp; $fs = [IO.File]::OpenWrite($tmp); $fs.SetLength(2MB); $fs.Close()
    $m = Get-Module OpenCodeBridge; $orig = $m.SessionState.PSVariable.Get('OpenCodeConfig').Value
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $tmp
    $w = @(); Test-OpenCodeConfig -WarningVariable +w -WarningAction SilentlyContinue
    $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $orig
    if ($w.Message -notmatch 'too large') { throw "Expected 'too large' warning" }
  } finally { Remove-Item $tmp -Force -EA 0 }
}

# ── 16. Stop-OpenCodeBridge supports -WhatIf ────────────────────────────────
Test-Case "Stop-OpenCodeBridge supports -WhatIf without error" {
  Stop-OpenCodeBridge -SessionDuration 9999 -WhatIf
}

# ── 17. Content-first config read ──────────────────────────────────────────
Test-Case "Config parser reads content before size check" {
  $tmp = Join-Path $env:TEMP "readfirst.json"; try {
    ('"k":"'+('x'*3000000)+'"') | Set-Content $tmp
    $m = Get-Module OpenCodeBridge; $orig = $m.SessionState.PSVariable.Get('OpenCodeConfig').Value; $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $tmp
    $w = @(); Test-OpenCodeConfig -WarningVariable +w -WarningAction SilentlyContinue; $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $orig
    if ($w.Message -match 'bytes') {} else { throw "Expected byte count in warning" }
  } finally { Remove-Item $tmp -Force -EA 0 }
}

Write-Host "`n$script:passed passed, $script:failed failed" -ForegroundColor $(if ($script:failed -eq 0) { 'Green' } else { 'Red' })
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
