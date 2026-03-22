# CustomDiskFunctions.ps1
# RAID-aware disk preparation functions for OSDCloud deployments

function Initialize-CustomDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$DetectRAID,
        
        [Parameter(Mandatory = $false)]
        [switch]$CreateMirror,
        
        [Parameter(Mandatory = $false)]
        [switch]$PreserveExistingData,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoRecoveryPartition
    )
    
    Write-Host "Starting custom disk initialization with RAID support..." -ForegroundColor Cyan
    
    # Variables to track disks
    $TargetDisk = $null
    $RaidConfig = $null
    $MirrorDisks = @()
    
    # First pass: detect existing RAID configurations
    if ($DetectRAID) {
        Write-Host "Checking for existing RAID configurations..." -ForegroundColor Yellow
        
        # Check for hardware RAID (will appear as a single disk)
        $RaidDisks = Get-Disk | Where-Object { 
            ($_.BusType -eq 'RAID') -or
            ($_.FriendlyName -match 'RAID') -or
            ($_.FriendlyName -match 'PERC') -or 
            ($_.FriendlyName -match 'MegaRAID') -or
            ($_.FriendlyName -match 'LSI') -or
            ($_.Model -match 'RAID')
        }
        
        if ($RaidDisks) {
            Write-Host "Found hardware RAID configuration" -ForegroundColor Green
            # Select the first RAID disk as our target
            $TargetDisk = $RaidDisks | Select-Object -First 1
        }
        else {
            # Check for Windows Storage Spaces (Software RAID)
            try {
                $StorageSpaces = Get-VirtualDisk -ErrorAction SilentlyContinue | 
                Where-Object { $_.ResiliencySettingName -eq 'Mirror' }
                
                if ($StorageSpaces) {
                    Write-Host "Found Windows Storage Spaces mirror configuration" -ForegroundColor Green
                    $RaidConfig = $StorageSpaces | Select-Object -First 1
                    
                    # Get the physical disk associated with this virtual disk
                    $TargetDisk = Get-Disk | Where-Object { 
                        $_.Number -eq ($RaidConfig | Get-Disk).Number 
                    }
                }
            }
            catch {
                Write-Host "Storage Spaces cmdlets not available, skipping software RAID detection" -ForegroundColor Yellow
            }
        }
    } 
    
    # If we still don't have a target disk, select the first available disk
    if (-not $TargetDisk) {
        Write-Host "No RAID configuration found, selecting primary disk" -ForegroundColor Yellow
        $TargetDisk = Get-Disk | Where-Object {     
            (-not $_.IsBoot) -and (-not $_.IsSystem) 
        } | Sort-Object Number | Select-Object -First 1
    }
    
    # Ensure the disk is ready
    if ($TargetDisk) {
        Write-Host "Using disk $($TargetDisk.Number) ($($TargetDisk.FriendlyName)) for OS installation" -ForegroundColor Green
        
        # If disk is offline, bring it online
        if ($TargetDisk.OperationalStatus -ne 'Online') {
            $TargetDisk | Set-Disk -IsOffline $false
        }
        
        # If disk is read-only, make it writable
        if ($TargetDisk.IsReadOnly) {
            $TargetDisk | Set-Disk -IsReadOnly $false
        }
        
        # If we're not preserving data, prepare the disk
        if (-not $PreserveExistingData) {
            # Initialize and partition the disk using OSDCloud exact approach
            Format-OSDisk -Disk $TargetDisk -NoRecoveryPartition:$NoRecoveryPartition
        }
        else {
            Write-Host "Preserving existing data. Skipping disk initialization." -ForegroundColor Yellow
        }
        
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        
        return $TargetDisk
    }
    else {
        Write-Host "No suitable disk found for OS installation" -ForegroundColor Red
        return $false
    }
}

function Format-OSDisk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        
        [Parameter()]
        [switch]$NoRecoveryPartition
    )
    
    Write-Host "Preparing disk $($Disk.Number) for Windows installation..." -ForegroundColor Cyan
    
    # Clear the disk
    Write-Host "Clearing disk and converting to GPT..." -ForegroundColor Yellow
    Clear-Disk -Number $Disk.Number -RemoveData -RemoveOEM -Confirm:$false
    
    # Convert to GPT
    Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
    
    # Create the Windows partition structure (exactly like OSDCloud)
    Write-Host "Creating partitions..." -ForegroundColor Yellow
    
    # Create System partition (ESP) - CRITICAL FOR BCDBOOT
    Write-Host "Creating EFI System Partition (ESP)..." -ForegroundColor Yellow
    $SystemPartition = New-Partition -DiskNumber $Disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
    
    # Format the System partition with proper flags
    Format-Volume -Partition $SystemPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    
    # Create MSR partition (Microsoft Reserved)
    Write-Host "Creating MSR partition..." -ForegroundColor Yellow
    New-Partition -DiskNumber $Disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    
    # Create Windows partition
    Write-Host "Creating Windows partition..." -ForegroundColor Yellow
    $WindowsPartition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
    
    # Format the Windows partition
    Format-Volume -Partition $WindowsPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    
    # Set the Windows partition as drive C:
    Write-Host "Setting Windows partition as C:..." -ForegroundColor Yellow
    $CurrentDriveLetter = $WindowsPartition.DriveLetter
    if ($CurrentDriveLetter -ne 'C') {
        # First check if C: is already in use
        $CDrive = Get-Volume -DriveLetter 'C' -ErrorAction SilentlyContinue
        if ($CDrive) {
            # Remove the drive letter from whatever is using C:
            $CPartition = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
            if ($CPartition) {
                $CPartition | Remove-PartitionAccessPath -AccessPath "C:\"
            }
        }
        Set-Partition -DiskNumber $Disk.Number -PartitionNumber $WindowsPartition.PartitionNumber -NewDriveLetter 'C'
    }
    
    # Explicitly run diskpart to set the ESP flag (extremely important for BCDBoot)
    Write-Host "Setting ESP flag on EFI System Partition..." -ForegroundColor Yellow
    $DiskpartCommands = @"
select disk $($Disk.Number)
select partition $($SystemPartition.PartitionNumber)
set id=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
set id="EFI System Partition"
gpt attributes=0x0000000000000000
exit
"@
    $DiskpartCommands | Out-File -FilePath "$env:TEMP\diskpart.txt" -Encoding ASCII
    Start-Process -FilePath "diskpart.exe" -ArgumentList "/s $env:TEMP\diskpart.txt" -Wait
    
    Write-Host "Disk preparation complete. Windows partition is C:, EFI System Partition is properly configured." -ForegroundColor Green
    
    # Return the Windows partition
    return Get-Partition -DriveLetter 'C'
}

# Add diagnostics function to help with troubleshooting
function Get-DiskDiagnostics {
    [CmdletBinding()]
    param()
    
    Write-Host "=== DISK DIAGNOSTICS ===" -ForegroundColor Yellow
    Write-Host "Listing all disks:" -ForegroundColor Cyan
    Get-Disk | Format-Table -AutoSize
    
    Write-Host "Listing all partitions:" -ForegroundColor Cyan
    Get-Partition | Format-Table -AutoSize
    
    Write-Host "Listing all volumes:" -ForegroundColor Cyan
    Get-Volume | Format-Table -AutoSize
    
    Write-Host "========================" -ForegroundColor Yellow
}

# Add this function to your script
function Register-EfiPartition {
    [CmdletBinding()]
    param()
    
    Write-Host "Registering EFI System Partition for boot configuration..." -ForegroundColor Cyan
    
    # Create a post-BCDBoot fix script that will run automatically after OSDCloud's BCDBoot fails
    $fixBootScript = @'
# Fix BCDBoot failures for Windows 11 24H2
Write-Host "===== Fixing BCDBoot for Windows 11 24H2 =====" -ForegroundColor Cyan

# Find EFI System Partition
$efiPartition = Get-Partition | Where-Object { 
    $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' 
} | Select-Object -First 1

if ($efiPartition) {
    # Assign a drive letter if needed
    $efiDriveLetter = $efiPartition.DriveLetter
    $needToRemoveLetter = $false
    
    if (-not $efiDriveLetter) {
        $efiDriveLetter = "S"
        Write-Host "Temporarily assigning drive letter $efiDriveLetter to EFI partition" -ForegroundColor Yellow
        $efiPartition | Set-Partition -NewDriveLetter $efiDriveLetter
        $needToRemoveLetter = $true
    } else {
        Write-Host "EFI partition already has drive letter $($efiDriveLetter):" -ForegroundColor Green
    }
    
    # Run BCDBoot with explicit system partition
    Write-Host "Running BCDBoot with explicit system partition..." -ForegroundColor Cyan
    $bcdBootCmd = "C:\Windows\System32\bcdboot.exe C:\Windows /s ${efiDriveLetter}: /f UEFI /v"
    Write-Host "Command: $bcdBootCmd" 
    
    $result = & C:\Windows\System32\bcdboot.exe C:\Windows /s "${efiDriveLetter}:" /f UEFI /v
    Write-Host $result
    
    if (Test-Path "${efiDriveLetter}:\EFI\Microsoft\Boot\BCD") {
        Write-Host "Successfully created boot files" -ForegroundColor Green
    } else {
        Write-Host "Failed to create boot files" -ForegroundColor Red
    }
    
    # Remove drive letter if we added it
    if ($needToRemoveLetter) {
        Write-Host "Removing temporary drive letter..." -ForegroundColor Yellow
        $efiPartition | Remove-PartitionAccessPath -AccessPath "${efiDriveLetter}:"
    }
} else {
    Write-Host "ERROR: Could not find EFI System Partition!" -ForegroundColor Red
}
'@

    # Save the script to a location that will be accessible after Windows is applied
    $scriptPath = "C:\OSDCloud\Scripts\Fix-BCDBoot.ps1"
    
    # Make sure the directory exists
    if (-not (Test-Path "C:\OSDCloud\Scripts")) {
        New-Item -Path "C:\OSDCloud\Scripts" -ItemType Directory -Force | Out-Null
    }
    
    # Write the script
    $fixBootScript | Out-File -FilePath $scriptPath -Encoding utf8 -Force
    
    Write-Host "Created BCDBoot fix script at $scriptPath" -ForegroundColor Green
    Write-Host "This script will run automatically after OSDCloud tries BCDBoot" -ForegroundColor Green
    
    # Find the EFI partition to report details
    $efiPartition = Get-Partition | Where-Object { 
        $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' 
    } | Select-Object -First 1
    
    if ($efiPartition) {
        Write-Host "Found EFI System Partition: Disk $($efiPartition.DiskNumber) Partition $($efiPartition.PartitionNumber)" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "ERROR: Could not find EFI System Partition!" -ForegroundColor Red
        return $false
    }
}