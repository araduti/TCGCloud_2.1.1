# Invoke-OSDCloudDeployment.ps1
# Shared deployment logic used by both the registered and unregistered Autopilot
# code paths in Show-OSDCloudOverlay.ps1.
#
# This script is designed to run inside an encoded PowerShell process launched
# from the WPF overlay. It reads selections from JSON files, configures the
# OSDCloud global variables, prepares disk, and starts the OS deployment.

$VerbosePreference = 'Continue'
$ProgressPreference = 'Continue'
$ErrorActionPreference = 'Continue'

Start-Transcript -Path "X:\OSDCloud\Logs\OSDCloud-Transcript.log" -Force

try {
    Import-Module OSD -Force
    $selections = Get-Content "X:\OSDCloud\Config\Scripts\Custom\osd-selections.json" | ConvertFrom-Json
    
    # Read OS selection from file
    $osSelection = Get-Content "X:\OSDCloud\Config\Scripts\Custom\os-selection.json" | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $osSelection) {
        # Default to Windows 11 if selection file doesn't exist
        $osSelection = @{
            OSVersion = "Windows 11"
            OSBuild = "24H2"
        }
        Write-Host "No OS selection found, defaulting to Windows 11 24H2" -ForegroundColor Yellow
    } else {
        Write-Host "Using selected OS: $($osSelection.OSVersion) $($osSelection.OSBuild)" -ForegroundColor Green
    }
    
    Write-Host "OSDStatus: Starting OSDCloud with language $($selections.Language) and OS $($osSelection.OSVersion) $($osSelection.OSBuild)"
    
    # Keep the global variables
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
    # Import custom disk functions
    . X:\OSDCloud\Config\Scripts\StartNet\Invoke-DiskFunctions.ps1

    # Initialize disk with RAID 1 support if needed
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
        Write-Host "OSDStatus: Warning - No suitable disk found, using OSDCloud defaults" -ForegroundColor Yellow
        # Reset the skip flags to let OSDCloud handle it
        $Global:MyOSDCloud.SkipClearDisk = $false
        $Global:MyOSDCloud.SkipNewOSDisk = $false
    }

    Start-OSDCloud -OSLanguage $selections.Language `
        -OSVersion $osSelection.OSVersion -OSBuild $osSelection.OSBuild `
        -OSEdition "Enterprise" -OSActivation "Volume" `
        -SkipAutopilot -SkipODT -ZTI -Verbose |
    Tee-Object -FilePath "X:\OSDCloud\Logs\OSDCloud-Output.log"
    
# After Start-OSDCloud completes, verify OS files exist
    Write-Host "Verifying Windows installation..." -ForegroundColor Cyan
    if (Test-Path "C:\Windows\System32\winload.exe") {
        Write-Host "Windows files found on C: drive - installation appears successful" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Windows files not found on C: drive - installation may have failed" -ForegroundColor Red
        # Check where Windows might have been installed
        $possibleWindowsPartitions = Get-Volume | Where-Object { Test-Path "$($_.DriveLetter):\Windows\System32\winload.exe" -ErrorAction SilentlyContinue }
        if ($possibleWindowsPartitions) {
            foreach ($vol in $possibleWindowsPartitions) {
                Write-Host "Found Windows on drive $($vol.DriveLetter):" -ForegroundColor Yellow
            }
        } else {
            Write-Host "No Windows installation found on any volume" -ForegroundColor Red
        }
        Get-DiskDiagnostics
    }
}
catch {
    Write-Error "Error in OSDCloud process: $_"
    $_ | Out-File -FilePath "X:\OSDCloud\Logs\OSDCloud-Error.log" -Append
    throw
}
finally {
    Stop-Transcript
}
