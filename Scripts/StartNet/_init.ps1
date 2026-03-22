# Import the OSD module
Write-Host "Status: Importing OSD Module" -ForegroundColor Cyan
try {
    Import-Module OSD -ErrorAction Stop
}
catch {
    Write-Host "Error: Failed to import OSD Module" -ForegroundColor Red
    exit
}

# Start WiFi connection first
Write-Host "Status: Starting WiFi connection" -ForegroundColor Cyan
try {
    Start-WinREWiFi -WirelessConnect -ErrorAction Stop
}
catch {
    Write-Host "Error: Failed to start WiFi connection" -ForegroundColor Red
    exit
}

# Confirm network connection
Write-Host "Status: Confirming network connection" -ForegroundColor Cyan
try {
    $pingResult = ping.exe -n 1 google.com
    if ($pingResult -match "TTL=") {
        Write-Host "Status: Network is ready" -ForegroundColor Green
        
        # OS Selection with timeout
        Write-Host "Please select the Windows version to install:" -ForegroundColor Cyan
        Write-Host "1: Windows 11 (Latest)" -ForegroundColor White
        Write-Host "2: Windows 10 (Latest)" -ForegroundColor White
        Write-Host ""
        Write-Host "Windows 11 will be selected automatically in 15 seconds..." -ForegroundColor Yellow
        
        $osChoice = $null
        $timeoutSeconds = 15
        $startTime = Get-Date
        $timedOut = $false
        
        # Create timeout logic with countdown
        while ($osChoice -ne "1" -and $osChoice -ne "2" -and -not $timedOut) {
            # Show countdown
            $elapsedSeconds = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
            $remainingSeconds = $timeoutSeconds - $elapsedSeconds
            
            if ($remainingSeconds -le 0) {
                $timedOut = $true
                Write-Host "`rTimeout reached! Windows 11 selected automatically.                 " -ForegroundColor Yellow
                $osChoice = "1"  # Default to Windows 11
                break
            }
            
            # Check if key is available in buffer
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).KeyChar.ToString()
                if ($key -eq "1" -or $key -eq "2") {
                    $osChoice = $key
                    Write-Host "`rYou selected: $osChoice                                         " -ForegroundColor Green
                    break
                }
                else {
                    Write-Host "`rInvalid selection. Please enter 1 for Windows 11 or 2 for Windows 10. ($remainingSeconds seconds left)   " -ForegroundColor Yellow -NoNewline
                }
            }
            else {
                # Update countdown
                Write-Host "`rPlease select (1 or 2) - Windows 11 will be selected in $remainingSeconds seconds..." -ForegroundColor Yellow -NoNewline
                Start-Sleep -Milliseconds 500
            }
        }
        
        # Clear the line
        Write-Host ""
        
        # Map selection to OS version and build
        if ($osChoice -eq "1") {
            $osVersion = "Windows 11"
            $osBuild = "24H2"
            Write-Host "Selected: Windows 11 24H2" -ForegroundColor Green
        } else {
            $osVersion = "Windows 10"
            $osBuild = "22H2"
            Write-Host "Selected: Windows 10 22H2" -ForegroundColor Green
        }
        
        # Detect language from OS files
        $detectedLanguage = "en-us" # Default fallback
        
        try {
            $osFiles = $null
            $drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' }
            
            foreach ($drive in $drives) {
                $driveLetter = $drive.DriveLetter
                $osPath = "${driveLetter}:\OSDCloud\OS"
                
                if (Test-Path $osPath) {
                    $osFiles = Get-ChildItem -Path $osPath -Include "*.esd", "*.wim", "*.iso" -Recurse -ErrorAction SilentlyContinue
                    if ($osFiles -and $osFiles.Count -gt 0) {
                        $osFileName = $osFiles[0].Name
                        Write-Host "Found OS file for language detection: $osFileName" -ForegroundColor Green
                        
                        # Look for language code in the filename - check full locale codes first
                        if ($osFileName -match "_de-de\b") {
                            $detectedLanguage = "de-de"
                            Write-Host "Detected German language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_sv-se\b") {
                            $detectedLanguage = "sv-se"
                            Write-Host "Detected Swedish language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_fr-fr\b") {
                            $detectedLanguage = "fr-fr"
                            Write-Host "Detected French language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_es-es\b") {
                            $detectedLanguage = "es-es"
                            Write-Host "Detected Spanish language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_en-us\b") {
                            $detectedLanguage = "en-us"
                            Write-Host "Detected English language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_german\b") {
                            $detectedLanguage = "de-de"
                            Write-Host "Detected German language from OS file" -ForegroundColor Green
                        }
                        elseif ($osFileName -match "_swedish\b") {
                            $detectedLanguage = "sv-se"
                            Write-Host "Detected Swedish language from OS file" -ForegroundColor Green
                        }
                        break
                    }
                }
            }
        }
        catch {
            Write-Host "Error detecting language from OS files: $_" -ForegroundColor Yellow
        }
        
        Write-Host "Using language: $detectedLanguage" -ForegroundColor Cyan
        
        # Save OS selection for the overlay script
        $osSelection = @{
            OSVersion = $osVersion
            OSBuild = $osBuild
            OSLanguage = $detectedLanguage
        }
        
        # Ensure directory exists
        $selectionDir = "X:\OSDCloud\Config\Scripts\Custom"
        if (-not (Test-Path $selectionDir)) {
            New-Item -Path $selectionDir -ItemType Directory -Force | Out-Null
        }
        
        # Save selection to file
        $osSelection | ConvertTo-Json | Set-Content -Path "X:\OSDCloud\Config\Scripts\Custom\os-selection.json" -Force
        
        # Launch the overlay UI script
        $overlayScript = Join-Path $PSScriptRoot "Show-OSDCloudOverlay.ps1"
        Write-Host "Launching OSDCloud Overlay from: $overlayScript" -ForegroundColor Green
        & $overlayScript
    }
    else {
        Write-Host "Error: Network connection failed" -ForegroundColor Red
    }
}
catch {
    Write-Host "Error: Network test failed" -ForegroundColor Red
}