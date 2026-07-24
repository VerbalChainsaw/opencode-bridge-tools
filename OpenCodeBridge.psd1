@{
  RootModule        = 'OpenCodeBridge.psm1'
  ModuleVersion     = '4.0.0'
  GUID              = '4030d944-02aa-47cc-8f50-43d68a362e08'
  Author            = 'zerop'
  CompanyName       = 'OpenCode Bridge Tools'
  Copyright         = '(c) zerop. MIT License.'
  Description       = 'OpenCode lifecycle manager: auto-starts/stops the Hermes Nous AI gateway, monitors health via HTTP liveness checks, tracks idle time for auto-shutdown, and validates opencode configuration.'
  PowerShellVersion = '7.0'
  FunctionsToExport = @(
    'Start-OpenCodeBridge',
    'Stop-OpenCodeBridge',
    'Get-OpenCodePath',
    'Get-OpenCodeBridgeStatus',
    'Test-OpenCodeConfig',
    'Test-OpenCodeBridgeHealth',
    'Test-BridgeConnectivity',
    'Disable-OpenCodeBridge'
  )
  FileList          = @(
    'OpenCodeBridge.psm1',
    'OpenCodeBridge.psd1',
    'profile-loader.ps1',
    'install.ps1',
    'run-tests.ps1',
    'tests\OpenCodeBridge.Tests.ps1',
    'README.md',
    'LICENSE'
  )
  PrivateData       = @{
    PSData = @{
      Tags       = @('opencode', 'hermes', 'nous', 'bridge', 'gateway', 'oh-my-opencode-slim', 'ai', 'lifecycle')
      ProjectUri = 'https://github.com/VerbalChainsaw/opencode-bridge-tools'
      LicenseUri = 'https://github.com/VerbalChainsaw/opencode-bridge-tools/blob/master/LICENSE'
    }
  }
}
