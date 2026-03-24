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
            $exported | Should -Contain 'New-TCGUSB'
            $exported | Should -Contain 'Edit-TCGWinPE'
            $exported | Should -Contain 'Update-TCGUSB'
            $exported | Should -Contain 'Start-TCGDeploy'
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

    Context 'New-TCGUSB' {
        It 'Requires WorkspacePath parameter' {
            $cmd = Get-Command New-TCGUSB
            $param = $cmd.Parameters['WorkspacePath']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory | Should -BeTrue }
        }

        It 'Returns failure for non-existent workspace' {
            $result = New-TCGUSB -WorkspacePath '/nonexistent/workspace' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns failure when workspace has no Media directory' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "TCGUSBTest-$(Get-Random)"
            try {
                New-Item -Path $testDir -ItemType Directory -Force | Out-Null
                $result = New-TCGUSB -WorkspacePath $testDir -ErrorAction SilentlyContinue
                $result.Success | Should -BeFalse
            }
            finally {
                if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
            }
        }

        It 'Has DiskNumber and Force parameters' {
            $cmd = Get-Command New-TCGUSB
            $cmd.Parameters.ContainsKey('DiskNumber') | Should -BeTrue
            $cmd.Parameters.ContainsKey('Force') | Should -BeTrue
        }
    }

    Context 'Edit-TCGWinPE' {
        It 'Requires BootWimPath parameter' {
            $cmd = Get-Command Edit-TCGWinPE
            $param = $cmd.Parameters['BootWimPath']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory | Should -BeTrue }
        }

        It 'Returns $false for non-existent boot.wim' {
            $result = Edit-TCGWinPE -BootWimPath '/nonexistent/boot.wim' -ErrorAction SilentlyContinue
            $result | Should -BeFalse
        }

        It 'Has expected parameters for drivers, WiFi, wallpaper, and USB update' {
            $cmd = Get-Command Edit-TCGWinPE
            $cmd.Parameters.ContainsKey('Wallpaper') | Should -BeTrue
            $cmd.Parameters.ContainsKey('DriverPaths') | Should -BeTrue
            $cmd.Parameters.ContainsKey('WirelessConnect') | Should -BeTrue
            $cmd.Parameters.ContainsKey('UpdateUSB') | Should -BeTrue
            $cmd.Parameters.ContainsKey('CloudDriver') | Should -BeTrue
        }
    }

    Context 'Update-TCGUSB' {
        It 'Returns failure when no USB volume and no image found' {
            # In CI there are no removable volumes or mounted ISOs
            $result = Update-TCGUSB -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns failure for non-existent explicit image path' {
            $result = Update-TCGUSB -ImagePath '/nonexistent/install.wim' -USBPath '/tmp' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Has OSName and OSActivation parameters with correct defaults' {
            $cmd = Get-Command Update-TCGUSB
            $cmd.Parameters.ContainsKey('OSName') | Should -BeTrue
            $cmd.Parameters.ContainsKey('OSActivation') | Should -BeTrue
            # OSActivation should have ValidateSet
            $validateSet = $cmd.Parameters['OSActivation'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Start-TCGDeploy' {
        It 'Is exported by the module' {
            $exported = (Get-Module TCGCloud).ExportedFunctions.Keys
            $exported | Should -Contain 'Start-TCGDeploy'
        }

        It 'Has expected parameters' {
            $cmd = Get-Command Start-TCGDeploy
            $cmd.Parameters.ContainsKey('OSLanguage')    | Should -BeTrue
            $cmd.Parameters.ContainsKey('OSVersion')     | Should -BeTrue
            $cmd.Parameters.ContainsKey('OSBuild')       | Should -BeTrue
            $cmd.Parameters.ContainsKey('OSEdition')     | Should -BeTrue
            $cmd.Parameters.ContainsKey('OSActivation')  | Should -BeTrue
            $cmd.Parameters.ContainsKey('ZTI')           | Should -BeTrue
            $cmd.Parameters.ContainsKey('SkipAutopilot') | Should -BeTrue
            $cmd.Parameters.ContainsKey('SkipODT')       | Should -BeTrue
        }

        It 'OSActivation parameter has ValidateSet with Volume and Retail' {
            $cmd = Get-Command Start-TCGDeploy
            $validateSet = $cmd.Parameters['OSActivation'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Volume'
            $validateSet.ValidValues | Should -Contain 'Retail'
        }

        It 'Returns failure when no OS image is found (no USB, no local image)' {
            # In CI there are no USB drives or mounted ISOs
            $result = Start-TCGDeploy -ZTI -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns a PSCustomObject with Success, WindowsDrive, and Message properties' {
            $result = Start-TCGDeploy -ZTI -ErrorAction SilentlyContinue
            $result | Should -BeOfType [PSCustomObject]
            $result.PSObject.Properties.Name | Should -Contain 'Success'
            $result.PSObject.Properties.Name | Should -Contain 'WindowsDrive'
            $result.PSObject.Properties.Name | Should -Contain 'Message'
        }

        It 'Accepts ScriptsRoot override without throwing' {
            { Start-TCGDeploy -ScriptsRoot '/tmp' -ZTI -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }
}
