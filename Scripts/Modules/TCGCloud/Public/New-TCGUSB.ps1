function New-TCGUSB {
    <#
    .SYNOPSIS
        Formats a USB drive and copies the TCGCloud workspace to it.
    .DESCRIPTION
        Replaces New-OSDCloudUSB. Detects USB drives, prompts for confirmation,
        formats the selected disk with a GPT layout (FAT32 boot + NTFS data),
        and copies workspace files to the USB.
    .PARAMETER WorkspacePath
        Path to the TCGCloud workspace (created by New-TCGWorkspace).
    .PARAMETER DiskNumber
        Specific disk number to format. If omitted, the user is prompted to
        select from available USB drives.
    .PARAMETER Force
        Skip the confirmation prompt (use for automation / ZTI).
    .OUTPUTS
        [PSCustomObject] with DriveLetter and Success properties.
    .EXAMPLE
        New-TCGUSB -WorkspacePath 'D:\OSDCloud-Build'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [Parameter()]
        [int]$DiskNumber = -1,

        [Parameter()]
        [switch]$Force
    )

    # --- Validate workspace ------------------------------------------------------
    if (-not (Test-Path $WorkspacePath)) {
        Write-TCGStatus "Workspace path not found: $WorkspacePath" -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    $mediaPath = Join-Path $WorkspacePath 'Media'
    if (-not (Test-Path $mediaPath)) {
        Write-TCGStatus "Workspace has no Media directory: $mediaPath" -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    # --- Select USB disk ---------------------------------------------------------
    if ($DiskNumber -lt 0) {
        $usbDisks = Get-Disk | Where-Object {
            $_.BusType -eq 'USB' -and
            $_.Size -ge 8GB -and
            $_.Size -le 256GB -and
            $_.OperationalStatus -eq 'Online'
        }

        if (-not $usbDisks -or $usbDisks.Count -eq 0) {
            Write-TCGStatus 'No suitable USB drives found (8 GB–256 GB, Online).' -Type Error
            return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
        }

        Write-Host "`n--- Available USB Drives ---" -ForegroundColor Cyan
        $usbDisks | ForEach-Object {
            $sizeGB = [math]::Round($_.Size / 1GB, 1)
            Write-Host "  Disk $($_.Number): $($_.FriendlyName) ($sizeGB GB)" -ForegroundColor White
        }

        if ($usbDisks.Count -eq 1) {
            $DiskNumber = $usbDisks[0].Number
            Write-TCGStatus "Auto-selected Disk $DiskNumber (only USB drive found)." -Type Info
        }
        else {
            $DiskNumber = Read-Host "`nEnter disk number"
            if ($DiskNumber -notin $usbDisks.Number) {
                Write-TCGStatus "Disk $DiskNumber is not in the list of USB drives." -Type Error
                return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
            }
        }
    }

    # --- Confirmation ------------------------------------------------------------
    $selectedDisk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $selectedDisk) {
        Write-TCGStatus "Disk $DiskNumber not found." -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    if ($selectedDisk.BusType -ne 'USB') {
        Write-TCGStatus "Disk $DiskNumber is not a USB drive (BusType: $($selectedDisk.BusType)). Aborting for safety." -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    if (-not $Force -and -not $PSCmdlet.ShouldProcess(
            "Disk $DiskNumber ($($selectedDisk.FriendlyName))",
            'ERASE ALL DATA and create TCGCloud boot media')) {
        Write-TCGStatus 'Operation cancelled by user.' -Type Warning
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    # --- Format with diskpart (GPT: FAT32 boot + NTFS data) ----------------------
    Write-TCGStatus "Formatting Disk $DiskNumber..." -Type Info

    $diskpartScript = @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=512
format fs=fat32 quick label="BOOT"
assign
create partition primary
format fs=ntfs quick label="OSDCLOUD"
assign
"@

    $dpFile = Join-Path $env:TEMP "tcgusb-diskpart-$(Get-Random).txt"
    try {
        $diskpartScript | Set-Content $dpFile -Force
        $dpOutput = & diskpart /s "$dpFile" 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            Write-TCGStatus "diskpart failed (exit code $LASTEXITCODE): $dpOutput" -Type Error
            return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
        }

        Write-TCGStatus 'Disk formatted successfully.' -Type Success
    }
    catch {
        Write-TCGStatus "Disk formatting error: $_" -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }
    finally {
        Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
    }

    # --- Determine assigned drive letters ----------------------------------------
    Start-Sleep -Seconds 2  # Allow Windows to assign drive letters

    $partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter }

    $bootPartition = $partitions | Where-Object { $_.Type -eq 'System' -or $_.Size -le 600MB } | Select-Object -First 1
    $dataPartition = $partitions | Where-Object { $_.Type -ne 'System' -and $_.Size -gt 600MB } | Select-Object -First 1

    if (-not $dataPartition -or -not $dataPartition.DriveLetter) {
        Write-TCGStatus 'Could not determine data partition drive letter.' -Type Error
        return [PSCustomObject]@{ Success = $false; DriveLetter = $null }
    }

    $dataDrive = "$($dataPartition.DriveLetter):"

    # --- Copy workspace to USB ---------------------------------------------------
    Write-TCGStatus "Copying workspace files to $dataDrive ..." -Type Info

    $robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
    if ($robocopy) {
        & robocopy "$mediaPath" "$dataDrive\" /E /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
        # robocopy exit codes 0-7 are success
        if ($LASTEXITCODE -gt 7) {
            Write-TCGStatus "robocopy failed (exit code $LASTEXITCODE)." -Type Error
            return [PSCustomObject]@{ Success = $false; DriveLetter = $dataPartition.DriveLetter }
        }
    }
    else {
        Copy-Item -Path "$mediaPath\*" -Destination "$dataDrive\" -Recurse -Force
    }

    Write-TCGStatus "USB boot media created on $dataDrive" -Type Success
    return [PSCustomObject]@{
        Success     = $true
        DriveLetter = $dataPartition.DriveLetter
    }
}
