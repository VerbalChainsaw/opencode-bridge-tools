@{
  RootModule        = 'OpenCodeBridge.psm1'
  ModuleVersion     = '2.0.0'
  GUID              = '4030d944-02aa-47cc-8f50-43d68a362e08'
  Author            = 'zerop'
  CompanyName       = 'Unknown'
  Copyright         = '(c) zerop. All rights reserved.'
  Description       = 'OpenCode lifecycle manager: auto-starts/stops the Hermes Nous gateway (upstream to the hermes-nous provider) around opencode invocations. Also exposes config validation and bridge status.'
  PowerShellVersion = '7.0'
  FunctionsToExport = @(
    'Start-OpenCodeBridge',
    'Stop-OpenCodeBridge',
    'Get-OpenCodePath',
    'Get-OpenCodeBridgeStatus',
    'Test-OpenCodeConfig'
  )
  FileList          = @('OpenCodeBridge.psm1')
  PrivateData       = @{
    PSData = @{
      Tags       = @('opencode', 'hermes', 'nous', 'bridge', 'gateway', 'oh-my-opencode-slim')
      ProjectUri = 'https://github.com/zerop/opencode-bridge-tools'
    }
  }
}
