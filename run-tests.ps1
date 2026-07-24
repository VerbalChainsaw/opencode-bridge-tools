# run-tests.ps1 — HermesBridge module smoke tests
# Usage: pwsh -NoProfile -File .\run-tests.ps1

$modulePath = Join-Path $PSScriptRoot 'HermesBridge.psd1'
try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Error "Module load failed: $_"; exit 1 }

$passed = 0; $failed = 0

function Test-Case($Name, $ScriptBlock) {
  try {
    & $ScriptBlock | Out-Null
    Write-Host "  PASS: $Name" -ForegroundColor Green
    $script:passed++
  } catch {
    Write-Host "  FAIL: $Name : $_" -ForegroundColor Red
    $script:failed++
  }
}

Test-Case "Get-Command exports 3 functions" { $commands = Get-Command -Module HermesBridge; if ($commands.Count -ne 3) { throw "Expected 3, got $($commands.Count)" } }
Test-Case "Start-HermesBridge is exported" { Get-Command Start-HermesBridge -Module HermesBridge -ErrorAction Stop }
Test-Case "Stop-HermesBridge is exported" { Get-Command Stop-HermesBridge -Module HermesBridge -ErrorAction Stop }
Test-Case "Get-OpenCodePath is exported" { Get-Command Get-OpenCodePath -Module HermesBridge -ErrorAction Stop }
Test-Case "Get-OpenCodePath returns valid path" { $p = Get-OpenCodePath; if (-not $p -or -not (Test-Path $p)) { throw "Invalid path: $p" } }
Test-Case "Stop-HermesBridge short session" { Stop-HermesBridge -SessionDuration 3 | Out-Null }
Test-Case "Stop-HermesBridge default param" { Stop-HermesBridge | Out-Null }
Test-Case "Start-HermesBridge fast path" { Start-HermesBridge | Out-Null }

Write-Host "`n$passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { exit 1 }
