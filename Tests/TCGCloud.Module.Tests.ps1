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
            $exported | Should -Contain 'New-TCGTemplate'
            $exported | Should -Contain 'New-TCGWorkspace'
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

    Context 'New-TCGTemplate' {
        It 'Returns $null when ADK is not installed' {
            # In CI there is no Windows ADK, so this should return $null gracefully
            $result = New-TCGTemplate -Name 'TestTemplate' -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }

        It 'Accepts a custom ADKPath parameter' {
            { New-TCGTemplate -ADKPath '/nonexistent/path' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'New-TCGWorkspace' {
        It 'Creates workspace directory structure' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "TCGWorkspaceTest-$(Get-Random)"
            try {
                $result = New-TCGWorkspace -WorkspacePath $testDir
                $result | Should -Be $testDir
                # Verify key directories were created
                Test-Path (Join-Path $testDir 'Media')           | Should -BeTrue
                Test-Path (Join-Path $testDir 'Media\OSDCloud')  | Should -BeTrue
                Test-Path (Join-Path $testDir 'Media\sources')   | Should -BeTrue
                Test-Path (Join-Path $testDir 'Media\EFI\Boot')  | Should -BeTrue
            }
            finally {
                if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
            }
        }

        It 'Requires WorkspacePath parameter' {
            $cmd = Get-Command New-TCGWorkspace
            $param = $cmd.Parameters['WorkspacePath']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory | Should -BeTrue }
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
