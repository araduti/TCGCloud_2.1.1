function Update-TCGUSB {
    <#
    .SYNOPSIS
        Adds or updates the OS image on a TCGCloud USB drive.
    .DESCRIPTION
        Replaces Update-OSDCloudUSB. Locates an install.wim or install.esd
        from a mounted ISO or a local path, optionally exports a specific
        edition, and copies the image to the USB OSDCloud\OS directory.
    .PARAMETER OSName
        Friendly OS name used to select the correct image index (e.g.
        'Windows 11 24H2'). Used when the source WIM contains multiple indexes.
    .PARAMETER OSActivation
        Activation type filter: 'Volume' or 'Retail'. Defaults to 'Volume'.
    .PARAMETER ImagePath
        Explicit path to an install.wim, install.esd, or .iso file.
        When omitted the function searches for a mounted ISO or well-known
        download paths.
    .PARAMETER USBPath
        Root path of the USB data partition (e.g. 'E:').
        When omitted the function searches removable volumes labelled OSDCLOUD.
    .OUTPUTS
        [PSCustomObject] with Success [bool] and ImagePath [string].
    .EXAMPLE
        Update-TCGUSB -OSName 'Windows 11 24H2' -OSActivation Volume
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OSName = 'Windows 11 24H2',

        [Parameter()]
        [ValidateSet('Volume', 'Retail')]
        [string]$OSActivation = 'Volume',

        [Parameter()]
        [string]$ImagePath,

        [Parameter()]
        [string]$USBPath
    )

    # --- Locate USB target -------------------------------------------------------
    if (-not $USBPath) {
        try {
            $usbVolumes = Get-Volume -ErrorAction Stop | Where-Object {
                $_.DriveType -eq 'Removable' -and
                $_.FileSystemLabel -eq 'OSDCLOUD' -and
                $_.DriveLetter
            }
        }
        catch {
            $usbVolumes = $null
        }

        if ($usbVolumes -and $usbVolumes.Count -gt 0) {
            $USBPath = "$($usbVolumes[0].DriveLetter):"
        }
        else {
            # Fallback: any removable volume with enough space
            try {
                $usbVolumes = Get-Volume -ErrorAction Stop | Where-Object {
                    $_.DriveType -eq 'Removable' -and
                    $_.DriveLetter -and
                    $_.SizeRemaining -gt 4GB
                }
            }
            catch {
                $usbVolumes = $null
            }
            if ($usbVolumes) {
                $USBPath = "$($usbVolumes[0].DriveLetter):"
            }
            else {
                Write-TCGStatus 'No suitable USB volume found.' -Type Error
                return [PSCustomObject]@{ Success = $false; ImagePath = $null }
            }
        }
    }

    $osDir = Join-Path $USBPath 'OSDCloud\OS'
    if (-not (Test-Path $osDir)) {
        New-Item -Path $osDir -ItemType Directory -Force | Out-Null
    }

    # --- Locate source image -----------------------------------------------------
    $sourcePath = $null

    if ($ImagePath) {
        if (-not (Test-Path $ImagePath)) {
            Write-TCGStatus "Specified image path not found: $ImagePath" -Type Error
            return [PSCustomObject]@{ Success = $false; ImagePath = $null }
        }

        if ($ImagePath -match '\.iso$') {
            # Mount ISO and locate install.wim/esd inside
            $sourcePath = Mount-ISOAndFindImage -ISOPath $ImagePath
        }
        else {
            $sourcePath = $ImagePath
        }
    }
    else {
        # Search for mounted ISOs
        try {
            $isoVolumes = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter }
        }
        catch {
            $isoVolumes = @()
        }
        foreach ($vol in $isoVolumes) {
            $candidate = "$($vol.DriveLetter):\sources\install.wim"
            if (Test-Path $candidate) { $sourcePath = $candidate; break }
            $candidate = "$($vol.DriveLetter):\sources\install.esd"
            if (Test-Path $candidate) { $sourcePath = $candidate; break }
        }

        # Search well-known download locations
        if (-not $sourcePath) {
            $searchPaths = @(
                "$env:USERPROFILE\Downloads"
                "$env:TEMP"
                'C:\OSDCloud\OS'
            )
            foreach ($sp in $searchPaths) {
                if (Test-Path $sp) {
                    $found = Get-ChildItem -Path $sp -Include 'install.wim', 'install.esd' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($found) { $sourcePath = $found.FullName; break }
                }
            }
        }
    }

    if (-not $sourcePath) {
        Write-TCGStatus 'No OS image found. Provide -ImagePath or mount a Windows ISO.' -Type Error
        return [PSCustomObject]@{ Success = $false; ImagePath = $null }
    }

    Write-TCGStatus "Source image: $sourcePath" -Type Info

    # --- Determine image index by edition/name -----------------------------------
    $imageIndex = 1  # Default

    try {
        $wimInfo = & dism /Get-WimInfo /WimFile:"$sourcePath" 2>&1 | Out-String
        # Parse index entries looking for a matching name
        $indexPattern = 'Index\s*:\s*(\d+)'
        $namePattern  = 'Name\s*:\s*(.+)'

        $indexes = [regex]::Matches($wimInfo, $indexPattern)
        $names   = [regex]::Matches($wimInfo, $namePattern)

        for ($i = 0; $i -lt $indexes.Count; $i++) {
            $idxVal  = $indexes[$i].Groups[1].Value
            $nameVal = if ($i -lt $names.Count) { $names[$i].Groups[1].Value.Trim() } else { '' }
            if ($nameVal -match [regex]::Escape($OSName) -or $nameVal -match 'Enterprise') {
                $imageIndex = [int]$idxVal
                Write-TCGStatus "Matched image index $imageIndex : $nameVal" -Type Info
                break
            }
        }
    }
    catch {
        Write-TCGStatus "Could not parse WIM info, using index 1: $_" -Type Warning
    }

    # --- Export / copy to USB ----------------------------------------------------
    $destPath = Join-Path $osDir 'install.wim'

    try {
        if ($sourcePath -match '\.esd$') {
            # Convert ESD to WIM via DISM export
            Write-TCGStatus "Exporting image index $imageIndex from ESD to WIM..." -Type Info
            $exportResult = & dism /Export-Image /SourceImageFile:"$sourcePath" `
                /SourceIndex:$imageIndex /DestinationImageFile:"$destPath" `
                /Compress:Max 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-TCGStatus "DISM export failed: $exportResult" -Type Error
                return [PSCustomObject]@{ Success = $false; ImagePath = $null }
            }
        }
        else {
            # Straight file copy (or export specific index)
            Write-TCGStatus "Copying install.wim to USB..." -Type Info
            Copy-Item -Path $sourcePath -Destination $destPath -Force
        }

        Write-TCGStatus "OS image copied to: $destPath" -Type Success
        return [PSCustomObject]@{ Success = $true; ImagePath = $destPath }
    }
    catch {
        Write-TCGStatus "Failed to copy OS image: $_" -Type Error
        return [PSCustomObject]@{ Success = $false; ImagePath = $null }
    }
}

# ---- Private helper: mount ISO and locate install image -------------------------
function Mount-ISOAndFindImage {
    param([string]$ISOPath)

    try {
        $mountResult = Mount-DiskImage -ImagePath $ISOPath -PassThru -ErrorAction Stop
        $driveLetter = ($mountResult | Get-Volume).DriveLetter

        $candidates = @(
            "${driveLetter}:\sources\install.wim"
            "${driveLetter}:\sources\install.esd"
        )

        foreach ($c in $candidates) {
            if (Test-Path $c) { return $c }
        }

        Write-TCGStatus "No install.wim/esd found in ISO at $ISOPath" -Type Warning
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
        return $null
    }
    catch {
        Write-TCGStatus "Failed to mount ISO: $_" -Type Error
        return $null
    }
}
