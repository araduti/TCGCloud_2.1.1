# Copy-OfficeSources.ps1 for SetupComplete
# This script runs in the full Windows environment during first boot

# Start transcript
Start-Transcript -Path "$env:WINDIR\Logs\OfficeCopy-SetupComplete.log" -Force

Write-Host "Starting Office sources copy process..." -ForegroundColor Cyan

# Create target directory
$targetDir = "C:\Windows\Temp\OfficeSources"
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Write-Host "Created directory: $targetDir" -ForegroundColor Green
}

# Find USB drive with OSDCloud folder
$usbDrive = $null
$drives = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }

foreach ($drive in $drives) {
    $driveLetter = $drive.DriveLetter
    $officeSourcePath = "${driveLetter}:\OSDCloud\Office"
    
    if (Test-Path $officeSourcePath) {
        $usbDrive = $drive
        Write-Host "Found Office sources on drive $driveLetter`: $officeSourcePath" -ForegroundColor Green
        
        # Copy Office sources
        Write-Host "Copying Office sources to $targetDir..." -ForegroundColor Cyan
        
        try {
            # First check if there's enough space
            $officeSize = (Get-ChildItem -Path $officeSourcePath -Recurse | Measure-Object -Property Length -Sum).Sum / 1GB
            $freeSpace = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB
            
            Write-Host "Office size: $($officeSize.ToString('0.00')) GB, Free space on C:: $($freeSpace.ToString('0.00')) GB" -ForegroundColor Yellow
            
            if ($freeSpace -lt ($officeSize * 1.5)) {
                Write-Host "Warning: Limited free space on C: drive. Office sources may not fit." -ForegroundColor Yellow
            }
            
            # Copy files
            Copy-Item -Path "$officeSourcePath\*" -Destination $targetDir -Recurse -Force
            
            # Verify files were copied
            $copiedFiles = Get-ChildItem -Path $targetDir -Recurse
            if ($copiedFiles.Count -gt 0) {
                $copiedSize = ($copiedFiles | Measure-Object -Property Length -Sum).Sum / 1MB
                Write-Host "Successfully copied Office sources: $($copiedFiles.Count) files ($($copiedSize.ToString('0.00')) MB)" -ForegroundColor Green
                
                # Copy language file if it exists
                $languageFile = Join-Path $officeSourcePath "language.txt"
                if (Test-Path $languageFile) {
                    $language = Get-Content $languageFile -Raw
                    $language | Out-File -FilePath (Join-Path $targetDir "language.txt") -Force
                    Write-Host "Language preference copied: $language" -ForegroundColor Green
                }
            }
            else {
                Write-Host "Error: No files were copied to $targetDir" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "Error copying Office sources: $_" -ForegroundColor Red
        }
        
        break
    }
}

if (-not $usbDrive) {
    Write-Host "No USB drive with Office sources found" -ForegroundColor Yellow
}

Write-Host "Office source files copied successfully." -ForegroundColor Green
Stop-Transcript 