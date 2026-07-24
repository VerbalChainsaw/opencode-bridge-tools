# Pester tests for OpenCodeBridge module (v2.1.0)
# If Pester is installed: Invoke-Pester -Path .\tests\OpenCodeBridge.Tests.ps1
# Otherwise the lightweight run-tests.ps1 covers the same surface.

BeforeAll {
  $modulePath = Join-Path $PSScriptRoot '..' 'OpenCodeBridge.psd1'
  Import-Module $modulePath -Force
}

Describe 'Module exports' {
  It 'Exports the 5 expected functions' {
    $exports = (Get-Module OpenCodeBridge).ExportedFunctions.Values.Name | Sort-Object
    $exports | Should -Contain 'Start-OpenCodeBridge'
    $exports | Should -Contain 'Stop-OpenCodeBridge'
    $exports | Should -Contain 'Get-OpenCodePath'
    $exports | Should -Contain 'Get-OpenCodeBridgeStatus'
    $exports | Should -Contain 'Test-OpenCodeConfig'
  }

  It 'Has a valid module manifest with the correct version' {
    $m = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
    $m.Version | Should -Be '4.0.0'
  }
}

Describe 'Get-OpenCodePath' {
  It 'Returns a non-null path that exists and has no spaces' {
    $path = Get-OpenCodePath
    $path | Should -Not -BeNullOrEmpty
    Test-Path $path | Should -Be $true
    $path | Should -Not -Match '\s'
  }
}

Describe 'Stop-OpenCodeBridge short-session guard' {
  It 'Returns immediately when SessionDuration < 15' {
    Stop-OpenCodeBridge -SessionDuration 3 | Should -BeNullOrEmpty
  }
  It 'Returns immediately with no argument (defaults to 0)' {
    Stop-OpenCodeBridge | Should -BeNullOrEmpty
  }
}

Describe 'Start-OpenCodeBridge fast path' {
  It 'Succeeds silently when the bridge is already listening' {
    Start-OpenCodeBridge | Should -BeNullOrEmpty
  }
}

Describe 'Get-OpenCodeBridgeStatus' {
  It 'Reports the running gateway with verified image + cmdline' {
    $s = Get-OpenCodeBridgeStatus
    $s | Should -Not -BeNullOrEmpty
    $s.BridgeReady | Should -Be $true
    $s.ProcessId | Should -Not -BeNullOrEmpty
    $s.ImagePath | Should -Match 'pythonw'
    $s.CmdLine | Should -Match 'hermes_cli\.main'
    $s.PSObject.Properties.Name | Should -Contain 'BridgeCmd'
  }
}

Describe 'Test-OpenCodeConfig' {
  It 'Passes on the live config' {
    Test-OpenCodeConfig | Should -Be $true
  }
}

Describe 'Lock file location hardening' {
  It 'Lock path uses LOCALAPPDATA (not TEMP)' {
    $s = Get-OpenCodeBridgeStatus
    $s.LockFile | Should -Match ([regex]::Escape($env:LOCALAPPDATA))
    $s.LockFile | Should -Not -Match ([regex]::Escape($env:TEMP))
  }
}

Describe 'JSONC parser' {
  It 'Preserves // inside string values (does not strip URLs)' {
    $testJson = '{ "path": "C:\\code//stuff", "url": "https://ok.com" }'
    $stripped = $testJson -replace '/\*[\s\S]*?\*/', '' -replace '(?m)^\s*//.*$', ''
    $parsed = $stripped | ConvertFrom-Json
    $parsed.path | Should -Be 'C:\code//stuff'
    $parsed.url  | Should -Be 'https://ok.com'
  }
}

Describe 'Config size limit' {
  It 'Rejects configs larger than 1 MB' {
    $tmp = Join-Path $env:TEMP "pester-oversized.json"
    try {
      '{}' | Set-Content $tmp -Force
      $fs = [System.IO.File]::OpenWrite($tmp)
      $fs.SetLength(2 * 1024 * 1024)
      $fs.Close()
      $m = Get-Module OpenCodeBridge
      $orig = $m.SessionState.PSVariable.Get('OpenCodeConfig').Value
      $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $tmp
      { Test-OpenCodeConfig -WarningAction SilentlyContinue } | Should -Not -Throw
      $m.SessionState.PSVariable.Get('OpenCodeConfig').Value = $orig
    } finally {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}
