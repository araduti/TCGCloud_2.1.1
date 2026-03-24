# Invoke-OSDCloudDeployment.ps1
# Shared deployment logic used by both the registered and unregistered Autopilot
# code paths in Show-OSDCloudOverlay.ps1.
#
# This script is designed to run inside an encoded PowerShell process launched
# from the WPF overlay. It reads selections from JSON files, prepares the disk,
# and starts the OS deployment using either Start-TCGDeploy (default) or the
# legacy Start-OSDCloud engine (set env:TCG_USE_OSDCLOUD=true to fall back).

$VerbosePreference = 'Continue'
$ProgressPreference = 'Continue'
$ErrorActionPreference = 'Continue'

Start-Transcript -Path "X:\OSDCloud\Logs\TCGCloud-Transcript.log" -Force

try {
    $selections = Get-Content "X:\OSDCloud\Config\Scripts\Custom\osd-selections.json" | ConvertFrom-Json

    # Read OS selection from file
    $osSelection = Get-Content "X:\OSDCloud\Config\Scripts\Custom\os-selection.json" | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $osSelection) {
        # Default to Windows 11 if selection file doesn't exist
        $osSelection = @{
            OSVersion  = 'Windows 11'
            OSBuild    = '24H2'
            OSLanguage = 'en-us'
        }
        Write-Host 'No OS selection found, defaulting to Windows 11 24H2' -ForegroundColor Yellow
    }
    else {
        Write-Host "Using selected OS: $($osSelection.OSVersion) $($osSelection.OSBuild)" -ForegroundColor Green
    }

    Write-Host "OSDStatus: Starting deployment with language $($selections.Language) and OS $($osSelection.OSVersion) $($osSelection.OSBuild)"

    # Import custom disk functions
    . X:\OSDCloud\Config\Scripts\StartNet\Invoke-DiskFunctions.ps1

    # Initialize disk with RAID support if needed
    $TargetDisk = Initialize-CustomDisk -DetectRAID -CreateMirror:$false -PreserveExistingData:$false -NoRecoveryPartition:$false

    # Register the EFI partition for boot configuration
    Register-EfiPartition

    # Run diagnostics to verify disk partitioning
    Get-DiskDiagnostics

    # Log the selected disk
    if ($TargetDisk) {
        Write-Host "OSDStatus: Using disk $($TargetDisk.Number) ($($TargetDisk.FriendlyName)) for installation" -ForegroundColor Green
    }
    else {
        Write-Host 'OSDStatus: Warning - No suitable disk found by custom handler' -ForegroundColor Yellow
    }

    # -------------------------------------------------------------------------
    # Deployment engine selection
    # Set env:TCG_USE_OSDCLOUD=true to fall back to the legacy OSDCloud engine.
    # Default is the native Start-TCGDeploy engine (no OSDCloud dependency).
    # -------------------------------------------------------------------------
    if ($env:TCG_USE_OSDCLOUD -eq 'true') {
        Write-Host 'OSDStatus: Using legacy OSDCloud engine (TCG_USE_OSDCLOUD=true)' -ForegroundColor Yellow

        # OSDCloud global configuration
        $Global:MyOSDCloud = [ordered]@{
            Restart               = $true
            RecoveryPartition     = $true
            OEMActivation         = $true
            WindowsUpdate         = $false
            WindowsUpdateDrivers  = $false
            WindowsDefenderUpdate = $false
            SetTimeZone           = $true
            ClearDiskConfirm      = $false
            ShutdownSetupComplete = $false
            SyncMSUpCatDriverUSB  = $true
            CheckSHA1             = $false
            SkipClearDisk         = $true
            SkipNewOSDisk         = $true
        }

        Import-Module OSD -Force

        Start-OSDCloud -OSLanguage $selections.Language `
            -OSVersion $osSelection.OSVersion -OSBuild $osSelection.OSBuild `
            -OSEdition 'Enterprise' -OSActivation 'Volume' `
            -SkipAutopilot -SkipODT -ZTI -Verbose |
        Tee-Object -FilePath 'X:\OSDCloud\Logs\TCGCloud-Output.log'
    }
    else {
        Write-Host 'OSDStatus: Using native TCGDeploy engine' -ForegroundColor Cyan

        # Load the TCGCloud module (available in USB boot; also injected into WinPE by Edit-TCGWinPE)
        $tcgModulePath = 'X:\OSDCloud\Config\Scripts\Modules\TCGCloud\TCGCloud.psd1'
        if (Test-Path $tcgModulePath) {
            Import-Module $tcgModulePath -Force
        }
        else {
            # Dot-source the function directly if the module is not installed in WinPE
            $startTcgDeploy = 'X:\OSDCloud\Config\Scripts\Modules\TCGCloud\Public\Start-TCGDeploy.ps1'
            if (Test-Path $startTcgDeploy) {
                . $startTcgDeploy
            }
            else {
                throw 'Start-TCGDeploy not found. Ensure the TCGCloud module is embedded in WinPE or set TCG_USE_OSDCLOUD=true to fall back.'
            }
        }

        $deployParams = @{
            OSLanguage    = $selections.Language
            OSVersion     = $osSelection.OSVersion
            OSBuild       = $osSelection.OSBuild
            OSEdition     = 'Enterprise'
            OSActivation  = 'Volume'
            SkipAutopilot = $true   # Autopilot registration is handled by Invoke-ImportAutopilot.ps1 before deployment
            SkipODT       = $true
            ZTI           = $true
            ScriptsRoot   = 'X:\OSDCloud\Config\Scripts'
        }

        $deployResult = Start-TCGDeploy @deployParams

        if (-not $deployResult.Success) {
            throw "Start-TCGDeploy failed: $($deployResult.Message)"
        }
    }

    # Verify OS files exist after deployment
    Write-Host 'Verifying Windows installation...' -ForegroundColor Cyan
    $windowsDrives = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\winload.exe" -ErrorAction SilentlyContinue) }

    if ($windowsDrives) {
        foreach ($vol in $windowsDrives) {
            Write-Host "Windows files found on drive $($vol.DriveLetter): — installation successful" -ForegroundColor Green
        }
        Write-Host 'TCGCloud Finished'
    }
    else {
        Write-Host 'ERROR: Windows files not found on any drive — installation may have failed' -ForegroundColor Red
        Get-DiskDiagnostics
    }
}
catch {
    Write-Error "Error in deployment process: $_"
    $_ | Out-File -FilePath 'X:\OSDCloud\Logs\TCGCloud-Error.log' -Append
    throw
}
finally {
    Stop-Transcript
}
