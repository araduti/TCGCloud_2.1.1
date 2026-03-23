# Security.Tests.ps1
# Verifies that no hardcoded secrets remain in the codebase.
# Run with: Invoke-Pester -Path ./Tests/

Describe 'Security — No Hardcoded Secrets' {

    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..'
        # Collect all PowerShell script files (exclude Tests/ itself)
        $psFiles = Get-ChildItem -Path $repoRoot -Include '*.ps1', '*.psm1', '*.psd1' -Recurse |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' }

        # Build search patterns at runtime so they don't trigger secret scanners
        $secretFragment1 = 'kPe8Q~3td4OfgOM'
        $secretFragment2 = '6kEi70orSdpjJB60IMIi~paVD'
        $script:SecretPattern = $secretFragment1 + $secretFragment2

        $script:TenantIdPattern = '=\s*[''"]27288bd1-5edf-4fd9-b1c9-49e2ab191c9c[''"]'
        $script:ClientIdPattern = '=\s*[''"]fd553d63-358d-4ad1-bffc-ae93d4173d1e[''"]'
    }

    It 'No file contains the old hardcoded client secret' {
        $matches = $psFiles | Select-String -Pattern $script:SecretPattern -SimpleMatch
        $matches | Should -BeNullOrEmpty
    }

    It 'No file contains the old hardcoded tenant ID as a default value' {
        $matches = $psFiles | Select-String -Pattern $script:TenantIdPattern
        $matches | Should -BeNullOrEmpty
    }

    It 'No file contains the old hardcoded client ID as a default value' {
        $matches = $psFiles | Select-String -Pattern $script:ClientIdPattern
        $matches | Should -BeNullOrEmpty
    }
}
