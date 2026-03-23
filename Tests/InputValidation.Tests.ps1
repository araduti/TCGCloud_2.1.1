# InputValidation.Tests.ps1
# Pester tests for input validation in Utils.ps1 and Invoke-ImportAutopilot.ps1.
# Run with: Invoke-Pester -Path ./Tests/

Describe 'Input Validation — Utils.ps1' {

    BeforeAll {
        $utilsPath = Join-Path $PSScriptRoot '..\Scripts\StartNet\Utils.ps1'
        . $utilsPath
    }

    Context 'Get-GraphToken credential validation' {
        It 'Returns $null when credentials are empty' {
            $result = Get-GraphToken -TenantId '' -ClientId '' -ClientSecret '' -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }

        It 'Returns $null when TenantId is not a valid GUID' {
            $result = Get-GraphToken -TenantId 'not-a-guid' -ClientId '00000000-0000-0000-0000-000000000000' -ClientSecret 'secret' -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }

        It 'Returns $null when ClientId is not a valid GUID' {
            $result = Get-GraphToken -TenantId '00000000-0000-0000-0000-000000000000' -ClientId 'bad-id' -ClientSecret 'secret' -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Test-AutopilotStatus serial number validation' {
        It 'Returns failure when SerialNumber is empty' {
            $result = Test-AutopilotStatus -SerialNumber '' -Token 'dummy' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns failure when SerialNumber is whitespace' {
            $result = Test-AutopilotStatus -SerialNumber '   ' -Token 'dummy' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }
    }

    Context 'Test-UserExists email validation' {
        It 'Returns failure for empty email' {
            $result = Test-UserExists -UserEmail '' -Token 'dummy' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns failure for invalid email format' {
            $result = Test-UserExists -UserEmail 'not-an-email' -Token 'dummy' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }

        It 'Returns failure for email with injection attempt' {
            $result = Test-UserExists -UserEmail "' or 1 eq 1 or '" -Token 'dummy' -ErrorAction SilentlyContinue
            $result.Success | Should -BeFalse
        }
    }
}
