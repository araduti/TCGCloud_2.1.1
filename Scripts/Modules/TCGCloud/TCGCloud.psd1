@{
    RootModule        = 'TCGCloud.psm1'
    ModuleVersion     = '2.1.1'
    GUID              = 'a3d7e8f1-4b2c-4e9a-8f6d-1c5b3a2e7d90'
    Author            = 'Thomas Computing Group'
    CompanyName       = 'Thomas Computing Group'
    Copyright         = '(c) Thomas Computing Group. All rights reserved.'
    Description       = 'Custom deployment module replacing OSDCloud dependencies for TCGCloud Windows deployment toolkit.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-TCGTemplate'
        'New-TCGTemplate'
        'New-TCGWorkspace'
        'Connect-TCGWiFi'
    )
    PrivateData       = @{
        PSData = @{
            Tags       = @('Deployment', 'WinPE', 'OSDCloud', 'Autopilot')
            ProjectUri = 'https://github.com/araduti/TCGCloud_2.1.1'
        }
    }
}
