# SetupUSB.Tests.ps1
# Pester tests for Setup-OSDCloudUSB.ps1 — verifies that all OSDCloud module
# function calls have been replaced with their TCGCloud equivalents.
# Run with: Invoke-Pester -Path ./Tests/ -Output Detailed

Describe 'Setup-OSDCloudUSB — TCGCloud migration' {

    BeforeAll {
        $script:setupPath    = Join-Path $PSScriptRoot '..\Setup-OSDCloudUSB.ps1'
        $script:setupContent = Get-Content -Path $script:setupPath -Raw
        $script:setupLines   = Get-Content -Path $script:setupPath
    }

    Context 'Script file exists' {

        It 'Setup-OSDCloudUSB.ps1 exists' {
            Test-Path $script:setupPath | Should -BeTrue
        }
    }

    Context 'No OSDCloud module function calls remain' {

        It 'Does not call Get-OSDCloudTemplate' {
            $script:setupContent | Should -Not -Match '\bGet-OSDCloudTemplate\b'
        }

        It 'Does not call New-OSDCloudTemplate' {
            $script:setupContent | Should -Not -Match '\bNew-OSDCloudTemplate\b'
        }

        It 'Does not call New-OSDCloudWorkspace' {
            $script:setupContent | Should -Not -Match '\bNew-OSDCloudWorkspace\b'
        }

        It 'Does not call New-OSDCloudUSB' {
            $script:setupContent | Should -Not -Match '\bNew-OSDCloudUSB\b'
        }

        It 'Does not call Edit-OSDCloudWinPE' {
            $script:setupContent | Should -Not -Match '\bEdit-OSDCloudWinPE\b'
        }

        It 'Does not call Update-OSDCloudUSB' {
            $script:setupContent | Should -Not -Match '\bUpdate-OSDCloudUSB\b'
        }

        It 'Does not import the OSDCloud module' {
            $script:setupContent | Should -Not -Match 'Import-Module\s+OSDCloud'
        }

        It 'Does not install the OSDCloud or OSD module from PSGallery' {
            $script:setupContent | Should -Not -Match 'Install-Module\s+OSDCloud'
            $script:setupContent | Should -Not -Match 'Install-Module\s+OSD\b'
        }
    }

    Context 'TCGCloud function calls are present' {

        It 'Calls Get-TCGTemplate' {
            $script:setupContent | Should -Match '\bGet-TCGTemplate\b'
        }

        It 'Calls New-TCGTemplate' {
            $script:setupContent | Should -Match '\bNew-TCGTemplate\b'
        }

        It 'Calls New-TCGWorkspace' {
            $script:setupContent | Should -Match '\bNew-TCGWorkspace\b'
        }

        It 'Calls New-TCGUSB' {
            $script:setupContent | Should -Match '\bNew-TCGUSB\b'
        }

        It 'Calls Edit-TCGWinPE' {
            $script:setupContent | Should -Match '\bEdit-TCGWinPE\b'
        }

        It 'Calls Update-TCGUSB' {
            $script:setupContent | Should -Match '\bUpdate-TCGUSB\b'
        }

        It 'Loads the TCGCloud module from the bundled Scripts directory' {
            $script:setupContent | Should -Match 'TCGCloud.*TCGCloud\.psd1'
        }
    }
}

Describe '_init.ps1 — TCGCloud migration' {

    BeforeAll {
        $script:initPath    = Join-Path $PSScriptRoot '..\Scripts\StartNet\_init.ps1'
        $script:initContent = Get-Content -Path $script:initPath -Raw
    }

    Context 'Script file exists' {

        It '_init.ps1 exists' {
            Test-Path $script:initPath | Should -BeTrue
        }
    }

    Context 'No OSDCloud/OSD function calls remain' {

        It 'Does not import the OSD module' {
            $script:initContent | Should -Not -Match 'Import-Module\s+OSD\b'
        }

        It 'Does not call Start-WinREWiFi' {
            $script:initContent | Should -Not -Match '\bStart-WinREWiFi\b'
        }
    }

    Context 'TCGCloud function calls are present' {

        It 'Loads the TCGCloud module' {
            $script:initContent | Should -Match 'TCGCloud\.psd1'
        }

        It 'Calls Connect-TCGWiFi' {
            $script:initContent | Should -Match '\bConnect-TCGWiFi\b'
        }
    }
}

Describe 'SetupComplete.ps1 — OSD module removal' {

    BeforeAll {
        $script:setupCompletePath    = Join-Path $PSScriptRoot '..\Scripts\SetupComplete\SetupComplete.ps1'
        $script:setupCompleteContent = Get-Content -Path $script:setupCompletePath -Raw
    }

    Context 'Script file exists' {

        It 'SetupComplete.ps1 exists' {
            Test-Path $script:setupCompletePath | Should -BeTrue
        }
    }

    Context 'No OSD module dependency remains' {

        It 'Does not import the OSD module' {
            $script:setupCompleteContent | Should -Not -Match 'Import-Module\s+OSD\b'
        }

        It 'Does not install the OSD module from PSGallery' {
            $script:setupCompleteContent | Should -Not -Match 'Install-Module\s+OSD\b'
        }
    }
}
