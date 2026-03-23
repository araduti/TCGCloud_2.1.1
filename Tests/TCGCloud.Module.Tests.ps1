# TCGCloud.Module.Tests.ps1
# Pester tests for the TCGCloud PowerShell module.
# Run with: Invoke-Pester -Path ./Tests/

Describe 'TCGCloud Module' {

    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Scripts\Modules\TCGCloud\TCGCloud.psd1'
        Import-Module $modulePath -Force
    }

    AfterAll {
        Remove-Module TCGCloud -ErrorAction SilentlyContinue
    }

    Context 'Module manifest' {
        It 'Has a valid module manifest' {
            $manifest = Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..\Scripts\Modules\TCGCloud\TCGCloud.psd1')
            $manifest | Should -Not -BeNullOrEmpty
        }

        It 'Exports expected functions' {
            $exported = (Get-Module TCGCloud).ExportedFunctions.Keys
            $exported | Should -Contain 'Get-TCGTemplate'
            $exported | Should -Contain 'Connect-TCGWiFi'
        }

        It 'Has version 2.1.1' {
            (Get-Module TCGCloud).Version.ToString() | Should -Be '2.1.1'
        }
    }

    Context 'Get-TCGTemplate' {
        It 'Returns $null when no template exists' {
            # ProgramData path will not contain a TCGCloud template in CI
            $result = Get-TCGTemplate -Name 'NonExistentTemplate'
            $result | Should -BeNullOrEmpty
        }

        It 'Accepts a custom Name parameter' {
            { Get-TCGTemplate -Name 'CustomName' } | Should -Not -Throw
        }
    }

    Context 'Connect-TCGWiFi' {
        It 'Returns a boolean' {
            # In a CI/test environment without a WiFi adapter this should return $false
            $result = Connect-TCGWiFi -ErrorAction SilentlyContinue
            $result | Should -BeOfType [bool]
        }
    }
}
