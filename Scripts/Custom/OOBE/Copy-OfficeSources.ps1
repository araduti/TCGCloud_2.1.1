# Copy-OfficeSources.ps1 - Runs during OOBE before Office installation
Start-Transcript -Path "C:\Windows\Logs\Copy-OfficeSources.log" -Force

function Copy-OfficeSourcesToTemp {
    try {
        Write-Host "Starting Office sources copy process..."
        
        # Create the destination directory if it doesn't exist
        $destinationPath = "C:\Windows\Temp\OfficeSources"
        if (-not (Test-Path $destinationPath)) {
            Write-Host "Creating destination directory: $destinationPath"
            New-Item -Path $destinationPath -ItemType Directory -Force | Out-Null
        }
        
        # Find connected USB drives
        Write-Host "Searching for USB drives with Office sources..."
        $usbDrives = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }
        
        $sourceFound = $false
        
        foreach ($drive in $usbDrives) {
            $driveLetter = $drive.DriveLetter
            $officeSourcePath = "${driveLetter}:\OSDCloud\Office\OfficeSources"
            
            Write-Host "Checking for Office sources on drive $driveLetter..."
            
            if (Test-Path $officeSourcePath) {
                Write-Host "Found Office sources on drive $driveLetter"
                
                # Use robocopy for reliable copying
                Write-Host "Copying Office sources to $destinationPath..."
                $robocopyArgs = @(
                    $officeSourcePath,
                    $destinationPath,
                    "/E", "/R:3", "/W:5", "/J", "/NP", "/NFL", "/NDL"
                )
                
                $robocopyResult = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
                
                if ($robocopyResult.ExitCode -lt 8) {
                    Write-Host "Office sources copied successfully"
                    $sourceFound = $true
                    break
                }
                else {
                    Write-Host "Error copying Office sources (code: $($robocopyResult.ExitCode))"
                }
            }
        }
        
        if (-not $sourceFound) {
            Write-Host "No Office sources found on any USB drive"
            return $false
        }
        
        return $true
    }
    catch {
        Write-Host "Error copying Office sources: $($_.Exception.Message)"
        return $false
    }
}

# Execute the copy operation
$result = Copy-OfficeSourcesToTemp

if ($result) {
    Write-Host "Office sources prepared successfully for installation"
}
else {
    Write-Host "Failed to prepare Office sources"
}

Stop-Transcript 