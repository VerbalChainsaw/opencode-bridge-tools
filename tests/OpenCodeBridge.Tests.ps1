# Pester tests for OpenCodeBridge module
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

  It 'Has a valid module manifest with the bumped version' {
    $m = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
    $m.Version | Should -Be '2.0.0'
  }
}

Describe 'Get-OpenCodePath' {
  It 'Returns a non-null path that exists' {
    $path = Get-OpenCodePath
    $path | Should -Not -BeNullOrEmpty
    Test-Path $path | Should -Be $true
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
