# Pester tests for HermesBridge module
# Run with: pwsh -NoProfile -File .\run-tests.ps1

BeforeAll {
  $modulePath = Join-Path $PSScriptRoot '..' 'HermesBridge.psd1'
  Import-Module $modulePath -Force
}

Describe 'Module exports' {
  It 'Exports Start-HermesBridge, Stop-HermesBridge, Get-OpenCodePath' {
    $exports = (Get-Module HermesBridge).ExportedFunctions.Values.Name | Sort-Object
    $exports | Should -Contain 'Start-HermesBridge'
    $exports | Should -Contain 'Stop-HermesBridge'
    $exports | Should -Contain 'Get-OpenCodePath'
  }

  It 'Has valid module manifest with version' {
    $manifest = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
    $manifest.Version | Should -Not -BeNullOrEmpty
  }
}

Describe 'Get-OpenCodePath' {
  It 'Returns a non-null path to opencode' {
    $path = Get-OpenCodePath
    $path | Should -Not -BeNullOrEmpty
    Test-Path $path | Should -Be $true
  }
}

Describe 'Stop-HermesBridge short-session guard' {
  It 'Returns immediately when SessionDuration < 15' {
    Stop-HermesBridge -SessionDuration 3 | Should -BeNullOrEmpty
  }

  It 'Returns immediately with no argument (defaults to 0)' {
    Stop-HermesBridge | Should -BeNullOrEmpty
  }
}

Describe 'Start-HermesBridge fast path' {
  It 'Succeeds silently when bridge is already listening' {
    Start-HermesBridge | Should -BeNullOrEmpty
  }
}

Describe 'Module configuration' {
  It 'Lock file path uses LOCALAPPDATA (not TEMP)' {
    $lockPath = (Get-Module HermesBridge).ScriptBlock.Ast.EndBlock.Statements |
      Where-Object { $_ -match 'LockFilePath' } | Out-String
    $lockPath | Should -Match 'LOCALAPPDATA'
  }
}
