@{
  RootModule        = 'HermesBridge.psm1'
  ModuleVersion     = '1.0.0'
  GUID              = 'a8f3c2e1-4d5b-4e6f-8a7b-9c0d1e2f3a4b'
  Author            = 'zerop'
  CompanyName       = 'Unknown'
  Copyright         = '(c) zerop. All rights reserved.'
  Description       = 'Hermes Nous Bridge lifecycle management for OpenCode integration.'
  PowerShellVersion = '7.0'
  FunctionsToExport = @('Start-HermesBridge', 'Stop-HermesBridge', 'Get-OpenCodePath')
  FileList          = @('HermesBridge.psm1')
  PrivateData       = @{
    PSData = @{
      Tags       = @('hermes', 'nous', 'opencode', 'bridge')
      ProjectUri = 'https://github.com/zerop/hermes-bridge-tools'
    }
  }
}
