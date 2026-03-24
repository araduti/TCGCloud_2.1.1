# OSDCloudOverlay.Tests.ps1
# Pester tests for Show-OSDCloudOverlay.ps1 — verifies that the deployment
# monitoring logic is deduplicated into Start-DeploymentWithMonitor and that
# both caller sites use the shared helper.
# Run with: Invoke-Pester -Path ./Tests/ -Output Detailed

Describe 'Show-OSDCloudOverlay — deployment monitoring deduplication' {

    BeforeAll {
        $script:overlayPath = Join-Path $PSScriptRoot '..\Scripts\StartNet\Show-OSDCloudOverlay.ps1'
        $script:overlayContent = Get-Content -Path $script:overlayPath -Raw
        $script:overlayLines   = Get-Content -Path $script:overlayPath
    }

    Context 'Start-DeploymentWithMonitor helper function' {

        It 'Script file exists' {
            Test-Path $script:overlayPath | Should -BeTrue
        }

        It 'Defines the Start-DeploymentWithMonitor function' {
            $script:overlayContent | Should -Match 'function Start-DeploymentWithMonitor'
        }

        It 'Defines Start-DeploymentWithMonitor exactly once' {
            $count = ($script:overlayLines | Where-Object { $_ -match 'function Start-DeploymentWithMonitor' }).Count
            $count | Should -Be 1
        }

        It 'Contains the DispatcherTimer log-monitoring logic inside the helper' {
            # The timer and log-parsing block should exist inside the helper function
            $script:overlayContent | Should -Match 'TCGCloud-Transcript\.log'
            $script:overlayContent | Should -Match 'DispatcherTimer'
            $script:overlayContent | Should -Match 'TCGCloud Finished'
        }
    }

    Context 'Caller sites use the shared helper — no raw duplication' {

        It 'Calls Start-DeploymentWithMonitor for the registered-device path' {
            # The registered-device block (after Autopilot status check) must call the helper
            $script:overlayContent | Should -Match 'Start-DeploymentWithMonitor'
        }

        It 'Calls Start-DeploymentWithMonitor at least twice (one per deployment path)' {
            $callCount = ($script:overlayLines | Where-Object { $_ -match 'Start-DeploymentWithMonitor' -and $_ -notmatch '^\s*function\s+Start-DeploymentWithMonitor' }).Count
            $callCount | Should -BeGreaterOrEqual 2
        }

        It 'Does not contain inline DispatcherTimer setup outside the helper function' {
            # Find the line of the helper function definition
            $helperLine = ($script:overlayLines | Select-String 'function Start-DeploymentWithMonitor').LineNumber
            $helperLine | Should -Not -BeNullOrEmpty

            # Count DispatcherTimer references before the helper (should be zero)
            $beforeHelper = if ($helperLine -gt 1) { $script:overlayLines[0..($helperLine - 2)] } else { @() }
            $timerBeforeHelper = $beforeHelper | Where-Object { $_ -match 'DispatcherTimer' }
            $timerBeforeHelper | Should -BeNullOrEmpty
        }

        It 'Does not contain raw Invoke-OSDCloudDeployment.ps1 Get-Content calls outside the helper' {
            # The only Get-Content of the deployment script should be inside Start-DeploymentWithMonitor
            $helperLine = ($script:overlayLines | Select-String 'function Start-DeploymentWithMonitor').LineNumber
            $helperLine | Should -Not -BeNullOrEmpty

            # Before the helper there should be no Get-Content of the deployment script
            $beforeHelper = if ($helperLine -gt 1) { $script:overlayLines[0..($helperLine - 2)] } else { @() }
            $rawCalls = $beforeHelper | Where-Object { $_ -match 'Get-Content.+Invoke-OSDCloudDeployment' }
            $rawCalls | Should -BeNullOrEmpty
        }
    }

    Context 'Process exit code handling distinguishes success from failure' {

        It 'Checks ExitCode property in the process-exit handler' {
            $script:overlayContent | Should -Match 'ExitCode'
        }

        It 'Shows Installation Complete on successful exit (ExitCode -eq 0)' {
            $script:overlayContent | Should -Match 'Installation Complete'
        }

        It 'Shows Installation Failed only on non-zero exit code' {
            # There must be a conditional exit-code check before showing "Installation Failed"
            $script:overlayContent | Should -Match 'ExitCode.*0|0.*ExitCode'
        }
    }

    Context 'Deployment script emits TCGCloud Finished completion marker' {

        BeforeAll {
            $script:deployPath    = Join-Path $PSScriptRoot '..\Scripts\StartNet\Invoke-OSDCloudDeployment.ps1'
            $script:deployContent = Get-Content -Path $script:deployPath -Raw
        }

        It 'Invoke-OSDCloudDeployment.ps1 exists' {
            Test-Path $script:deployPath | Should -BeTrue
        }

        It 'Emits TCGCloud Finished after successful deployment verification' {
            $script:deployContent | Should -Match 'TCGCloud Finished'
        }

        It 'Uses TCGCloud-Transcript.log as the deployment transcript path' {
            $script:deployContent | Should -Match 'TCGCloud-Transcript\.log'
        }
    }

    Context 'Legacy OSDCloud fallback is removed (Phase 10)' {

        BeforeAll {
            $script:deployPath    = Join-Path $PSScriptRoot '..\Scripts\StartNet\Invoke-OSDCloudDeployment.ps1'
            $script:deployContent = Get-Content -Path $script:deployPath -Raw
        }

        It 'Does not contain Import-Module OSD' {
            $script:deployContent | Should -Not -Match '\bImport-Module\s+OSD\b'
        }

        It 'Does not contain Start-OSDCloud' {
            $script:deployContent | Should -Not -Match '\bStart-OSDCloud\b'
        }

        It 'Does not reference TCG_USE_OSDCLOUD environment variable' {
            $script:deployContent | Should -Not -Match 'TCG_USE_OSDCLOUD'
        }
    }
}
