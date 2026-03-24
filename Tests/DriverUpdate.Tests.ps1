# DriverUpdate.Tests.ps1
# Pester tests for Invoke-TCGDriverUpdate — on-demand vendor-specific driver installation.
# Run with: Invoke-Pester -Path ./Tests/ -Output Detailed

Describe 'Invoke-TCGDriverUpdate — module export and interface' {

    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Scripts\Modules\TCGCloud\TCGCloud.psd1'
        Import-Module $modulePath -Force
    }

    AfterAll {
        Remove-Module TCGCloud -ErrorAction SilentlyContinue
    }

    Context 'Module export' {

        It 'Invoke-TCGDriverUpdate is exported by the TCGCloud module' {
            $exported = (Get-Module TCGCloud).ExportedFunctions.Keys
            $exported | Should -Contain 'Invoke-TCGDriverUpdate'
        }
    }

    Context 'Parameter interface' {

        It 'Has a Manufacturer parameter' {
            $cmd = Get-Command Invoke-TCGDriverUpdate
            $cmd.Parameters.ContainsKey('Manufacturer') | Should -BeTrue
        }

        It 'Has a LogPath parameter' {
            $cmd = Get-Command Invoke-TCGDriverUpdate
            $cmd.Parameters.ContainsKey('LogPath') | Should -BeTrue
        }

        It 'Has a Force switch parameter' {
            $cmd = Get-Command Invoke-TCGDriverUpdate
            $cmd.Parameters.ContainsKey('Force') | Should -BeTrue
            $cmd.Parameters['Force'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
        }

        It 'Manufacturer parameter is optional (has a default of empty string)' {
            # Verify the parameter exists and is not mandatory
            $cmd = Get-Command Invoke-TCGDriverUpdate
            $param = $cmd.Parameters['Manufacturer']
            $isMandatory = $param.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory
            $isMandatory | Should -BeFalse
        }
    }

    Context 'Return object contract' {

        It 'Always returns a PSCustomObject' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeOfType [PSCustomObject]
        }

        It 'Return object has Manufacturer property' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.PSObject.Properties.Name | Should -Contain 'Manufacturer'
        }

        It 'Return object has Provider property' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.PSObject.Properties.Name | Should -Contain 'Provider'
        }

        It 'Return object has Success property' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.PSObject.Properties.Name | Should -Contain 'Success'
        }

        It 'Return object has Message property' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.PSObject.Properties.Name | Should -Contain 'Message'
        }

        It 'Success property is a boolean' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.Success | Should -BeOfType [bool]
        }

        It 'Manufacturer property echoes the overridden value' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'TestVendor' -ErrorAction SilentlyContinue
            $result.Manufacturer | Should -Be 'TestVendor'
        }
    }

    Context 'Vendor routing — Dell' {

        It 'Sets Provider to DellCommandUpdate for Dell manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'Dell Inc.' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'DellCommandUpdate'
        }

        It 'Does not throw for Dell manufacturer' {
            { Invoke-TCGDriverUpdate -Manufacturer 'Dell Inc.' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }

        It 'Returns a non-empty Message for Dell' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'Dell Inc.' -ErrorAction SilentlyContinue
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Vendor routing — HP' {

        It 'Sets Provider to HPCMSL for HP manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'HP' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'HPCMSL'
        }

        It 'Sets Provider to HPCMSL for Hewlett-Packard manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'Hewlett-Packard' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'HPCMSL'
        }

        It 'Does not throw for HP manufacturer' {
            { Invoke-TCGDriverUpdate -Manufacturer 'HP' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'Vendor routing — Lenovo' {

        It 'Sets Provider to LSUClient for Lenovo manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'Lenovo' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'LSUClient'
        }

        It 'Does not throw for Lenovo manufacturer' {
            { Invoke-TCGDriverUpdate -Manufacturer 'Lenovo' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'Vendor routing — Microsoft Surface' {

        It 'Sets Provider to WindowsUpdate for Microsoft manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'Microsoft Corporation' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'WindowsUpdate'
        }

        It 'Does not throw for Microsoft manufacturer' {
            { Invoke-TCGDriverUpdate -Manufacturer 'Microsoft Corporation' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'Vendor routing — unknown / fallback' {

        It 'Uses WindowsUpdate provider for an unknown manufacturer' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'UnknownVendorXYZ' -ErrorAction SilentlyContinue
            $result.Provider | Should -Be 'WindowsUpdate'
        }

        It 'Does not throw for an unknown manufacturer' {
            { Invoke-TCGDriverUpdate -Manufacturer 'UnknownVendorXYZ' -ErrorAction SilentlyContinue } | Should -Not -Throw
        }

        It 'Returns a non-empty Message for unknown vendor' {
            $result = Invoke-TCGDriverUpdate -Manufacturer 'UnknownVendorXYZ' -ErrorAction SilentlyContinue
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'LogPath behaviour' {

        It 'Creates the log file when LogPath is specified' {
            $logFile = Join-Path ([System.IO.Path]::GetTempPath()) "TCGDriverTest-$(Get-Random).log"
            try {
                Invoke-TCGDriverUpdate -Manufacturer 'UnknownVendorXYZ' -LogPath $logFile -ErrorAction SilentlyContinue
                Test-Path $logFile | Should -BeTrue
            }
            finally {
                Remove-Item $logFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Does not throw when LogPath directory does not exist' {
            $logFile = Join-Path ([System.IO.Path]::GetTempPath()) "nonexistent-$(Get-Random)\driver.log"
            { Invoke-TCGDriverUpdate -Manufacturer 'UnknownVendorXYZ' -LogPath $logFile -ErrorAction SilentlyContinue } |
                Should -Not -Throw
        }
    }
}

Describe 'Invoke-TCGDriverUpdate — source file conventions' {

    BeforeAll {
        $script:srcPath    = Join-Path $PSScriptRoot '..\Scripts\Modules\TCGCloud\Public\Invoke-TCGDriverUpdate.ps1'
        $script:srcContent = Get-Content -Path $script:srcPath -Raw
    }

    Context 'File exists' {

        It 'Invoke-TCGDriverUpdate.ps1 exists in the Public folder' {
            Test-Path $script:srcPath | Should -BeTrue
        }
    }

    Context 'No OSD/OSDCloud dependency' {

        It 'Does not import the OSD module' {
            $script:srcContent | Should -Not -Match 'Import-Module\s+OSD\b'
        }

        It 'Does not call Start-OSDCloud' {
            $script:srcContent | Should -Not -Match '\bStart-OSDCloud\b'
        }

        It 'Does not reference the OSDCloud driver XML catalogs' {
            $script:srcContent | Should -Not -Match 'DriverPack.*\.xml'
        }
    }

    Context 'Vendor tool references' {

        It 'References Dell Command Update CLI (dcu-cli.exe)' {
            $script:srcContent | Should -Match 'dcu-cli\.exe'
        }

        It 'References the HPCMSL module for HP' {
            $script:srcContent | Should -Match 'HPCMSL'
        }

        It 'References the LSUClient module for Lenovo' {
            $script:srcContent | Should -Match 'LSUClient'
        }

        It 'References Windows Update COM API as a fallback' {
            $script:srcContent | Should -Match 'Microsoft\.Update\.Session'
        }
    }
}

Describe 'SetupComplete.ps1 — on-demand driver update integration' {

    BeforeAll {
        $script:setupPath    = Join-Path $PSScriptRoot '..\Scripts\SetupComplete\SetupComplete.ps1'
        $script:setupContent = Get-Content -Path $script:setupPath -Raw
    }

    Context 'Script file exists' {

        It 'SetupComplete.ps1 exists' {
            Test-Path $script:setupPath | Should -BeTrue
        }
    }

    Context 'Uses Invoke-TCGDriverUpdate instead of the old generic function' {

        It 'Calls Invoke-TCGDriverUpdate' {
            $script:setupContent | Should -Match '\bInvoke-TCGDriverUpdate\b'
        }

        It 'Does not define the old Start-WindowsUpdateDriver function' {
            $script:setupContent | Should -Not -Match '\bfunction\s+Start-WindowsUpdateDriver\b'
        }
    }

    Context 'No OSD module dependency remains' {

        It 'Does not import the OSD module' {
            $script:setupContent | Should -Not -Match 'Import-Module\s+OSD\b'
        }

        It 'Does not install the OSD module from PSGallery' {
            $script:setupContent | Should -Not -Match 'Install-Module\s+OSD\b'
        }
    }
}
