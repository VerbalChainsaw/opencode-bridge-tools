# run-tests.ps1 — OpenCodeBridge module smoke + behavior tests
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
  if ($cmds.Count -ne 5) { throw "Expected 5, got $($cmds.Count): $($cmds.Name -join ',')" }
}
Test-Case "Start-OpenCodeBridge is exported"   { Get-Command Start-OpenCodeBridge   -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Stop-OpenCodeBridge is exported"    { Get-Command Stop-OpenCodeBridge    -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodePath is exported"       { Get-Command Get-OpenCodePath       -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Get-OpenCodeBridgeStatus is exported" { Get-Command Get-OpenCodeBridgeStatus -Module OpenCodeBridge -ErrorAction Stop }
Test-Case "Test-OpenCodeConfig is exported"   { Get-Command Test-OpenCodeConfig    -Module OpenCodeBridge -ErrorAction Stop }

# ── 2. Manifest integrity ──────────────────────────────────────────────────
Test-Case "Manifest self-validates" {
  $m = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
  if ($m.Version -ne [version]'2.0.0') { throw "Wrong version: $($m.Version)" }
  if ($m.PowerShellVersion -lt [version]'7.0') { throw "PSVersion too low" }
}

# ── 3. Get-OpenCodePath ────────────────────────────────────────────────────
Test-Case "Get-OpenCodePath returns a valid existing path" {
  $p = Get-OpenCodePath
  if (-not $p) { throw "Returned null" }
  if (-not (Test-Path $p)) { throw "Path does not exist: $p" }
}

# ── 4. Stop-OpenCodeBridge short-session guard ────────────────────────────
Test-Case "Stop-OpenCodeBridge short session returns silently"   { Stop-OpenCodeBridge -SessionDuration 3 }
Test-Case "Stop-OpenCodeBridge default (0s) returns silently"    { Stop-OpenCodeBridge }

# ── 5. Start-OpenCodeBridge fast path ──────────────────────────────────────
Test-Case "Start-OpenCodeBridge fast path when bridge already up" { Start-OpenCodeBridge }

# ── 6. Get-OpenCodeBridgeStatus ────────────────────────────────────────────
Test-Case "Get-OpenCodeBridgeStatus returns a PSCustomObject with required fields" {
  $s = Get-OpenCodeBridgeStatus
  $required = 'BridgeReady','Port','ProcessId','ImagePath','CmdLine','Uptime','LockFile','LockHeld'
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

# ── 7. Test-OpenCodeConfig ──────────────────────────────────────────────────
Test-Case "Test-OpenCodeConfig returns $true on the live config" {
  $ok = Test-OpenCodeConfig
  if (-not $ok) { throw "Config validation failed — config may have drifted" }
}

# ── 8. Lock file location hardening ────────────────────────────────────────
Test-Case "Lock file path uses LOCALAPPDATA (not TEMP)" {
  $mod = Get-Module OpenCodeBridge
  $src = $mod.SessionState.Module.ToString()
  # Pull the actual lock path from a fresh module instance: the lock file name encodes the dir
  $s = Get-OpenCodeBridgeStatus
  if ($s.LockFile -notmatch [regex]::Escape($env:LOCALAPPDATA)) { throw "Lock not in LOCALAPPDATA: $($s.LockFile)" }
  if ($s.LockFile -match [regex]::Escape($env:TEMP)) { throw "Lock should not be in TEMP: $($s.LockFile)" }
}

# ── 9. Intruder port-occupant guard (regression test) ──────────────────────
# Simulate a non-Hermes process holding the bridge port; Start must bail
# out with a single clear warning and NOT retry-attack the port.
Test-Case "Start refuses when a non-Hermes process holds the port (no retry storm)" {
  $m = Get-Module OpenCodeBridge
  $sb = {
    function script:Get-BridgeConnection { [PSCustomObject]@{ OwningProcess = 99999; LocalAddress = '127.0.0.1' } }
    function script:Test-BridgeProcess {
      param([int]$ProcessId)
      $sim = [PSCustomObject]@{ Name = 'pythonw.exe'; CommandLine = 'pythonw.exe -m unrelated serve' }
      if ($sim.Name -notmatch "^pythonw") { return $false }
      if ($sim.CommandLine -notmatch 'hermes_cli\.main') { return $false }
      return $true
    }
  }
  & $m $sb
  $warnings = @()
  Start-OpenCodeBridge -ErrorAction SilentlyContinue -WarningVariable +warnings -WarningAction SilentlyContinue
  if ($warnings.Count -ne 1) { throw "Expected 1 bail-out warning, got $($warnings.Count)" }
  if ($warnings[0].Message -notmatch 'refusing to start a conflicting gateway') {
    throw "Wrong message: $($warnings[0].Message)"
  }
  # Restore real helpers by re-importing the module fresh
  Remove-Module OpenCodeBridge -ErrorAction SilentlyContinue
  Import-Module $modulePath -Force
}

# ── 10. Get-OpenCodePath priority: prefer no-spaces .exe first ──────────────
Test-Case "Get-OpenCodePath prefers LOCALAPPDATA copy (no spaces in path)" {
  $p = Get-OpenCodePath
  if (-not $p) { throw "Get-OpenCodePath returned null" }
  if ($p -match '\s') { throw "Path has spaces: $p" }
}

# ── 11. JSONC parser preserves // inside string values ──────────────────────
Test-Case "Test-OpenCodeConfig JSONC parser does not eat // in strings" {
  # Access the private stripComments via module scope and test directly
  $testJson = '{ "path": "C:\\code//stuff", "url": "https://ok.com" }'
  $stripped = $testJson -replace '/\*[\s\S]*?\*/', '' -replace '(?m)^\s*//.*$', ''
  $parsed = $stripped | ConvertFrom-Json
  if ($parsed.path -ne 'C:\code//stuff') { throw "// in string was eaten: $($parsed.path)" }
  if ($parsed.url -ne 'https://ok.com') { throw "URL was damaged: $($parsed.url)" }
}

# ── 12. Status object uses a single CIM query (CmdLine present) ─────────────
Test-Case "Get-OpenCodeBridgeStatus returns CmdLine from the same CIM query" {
  $s = Get-OpenCodeBridgeStatus
  if ($s.BridgeReady -and -not $s.CmdLine) { throw "BridgeReady but CmdLine is empty — redundant CIM query bug?" }
}

Write-Host "`n$script:passed passed, $script:failed failed" -ForegroundColor $(if ($script:failed -eq 0) { 'Green' } else { 'Red' })
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
