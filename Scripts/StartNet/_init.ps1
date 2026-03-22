# Detect boot mode: USB (OSD module available) or Network (RAM-disk boot)
$script:BootMode = "USB"
$script:ScriptsRoot = $PSScriptRoot  # Default: scripts alongside this file

# Try to import OSD module (available in USB boot via OSDCloud)
Write-Host "Status: Importing OSD Module" -ForegroundColor Cyan
try {
    Import-Module OSD -ErrorAction Stop
    Write-Host "Status: OSD Module loaded (USB boot mode)" -ForegroundColor Green
}
catch {
    Write-Host "Status: OSD Module not available — using network boot mode" -ForegroundColor Yellow
    $script:BootMode = "Network"
}

# Check if TCGCloud scripts are present; if not, download from GitHub
$overlayCheck = Join-Path $PSScriptRoot "Show-OSDCloudOverlay.ps1"
if (-not (Test-Path $overlayCheck)) {
    Write-Host "Status: Scripts not found locally, attempting network download..." -ForegroundColor Yellow
    $script:BootMode = "Network"

    # Load deploy-config.json if available
    $deployConfig = $null
    $configLocations = @(
        "X:\OSDCloud\Config\deploy-config.json",
        "X:\deploy-config.json"
    )
    foreach ($cfgPath in $configLocations) {
        if (Test-Path $cfgPath) {
            $deployConfig = Get-Content $cfgPath -Raw | ConvertFrom-Json
            break
        }
    }

    if ($deployConfig) {
        $owner = $deployConfig.github.owner
        $repo = $deployConfig.github.repo
        $tag = $deployConfig.github.releaseTag
    }
    else {
        $owner = "araduti"
        $repo = "TCGCloud_2.1.1"
        $tag = "latest"
    }

    $scriptsZip = $null
    $destDir = "X:\OSDCloud\Config\Scripts"

    # Try downloading scripts package from GitHub Release
    try {
        if ($tag -eq "latest") {
            $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
        }
        else {
            $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
        }

        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'TCGCloud' } -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq "tcgcloud-scripts.zip" }

        if ($asset) {
            $scriptsZip = "X:\tcgcloud-scripts.zip"
            Write-Host "Status: Downloading scripts from GitHub Release..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $scriptsZip -UseBasicParsing
        }
    }
    catch {
        Write-Host "Status: Could not reach GitHub API, trying direct repository download..." -ForegroundColor Yellow
    }

    # Fallback: download repo archive
    if (-not $scriptsZip -or -not (Test-Path $scriptsZip)) {
        try {
            $zipUrl = "https://github.com/$owner/$repo/archive/refs/heads/main.zip"
            $repoZip = "X:\tcgcloud-repo.zip"
            Write-Host "Status: Downloading repository archive..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $zipUrl -OutFile $repoZip -UseBasicParsing

            $extractDir = "X:\tcgcloud-extract"
            Expand-Archive -Path $repoZip -DestinationPath $extractDir -Force
            $repoRoot = Get-ChildItem $extractDir | Select-Object -First 1
            $srcScripts = Join-Path $repoRoot.FullName "Scripts"

            if (Test-Path $srcScripts) {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                Copy-Item "$srcScripts\*" $destDir -Recurse -Force
                Write-Host "Status: Scripts downloaded and extracted" -ForegroundColor Green
            }

            Remove-Item $repoZip -Force -ErrorAction SilentlyContinue
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "Error: Failed to download scripts from GitHub: $_" -ForegroundColor Red
            Write-Host "Error: Cannot continue without deployment scripts" -ForegroundColor Red
            exit
        }
    }
    else {
        # Extract the scripts zip
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $scriptsZip -DestinationPath "X:\OSDCloud\Config" -Force
        Remove-Item $scriptsZip -Force -ErrorAction SilentlyContinue
        Write-Host "Status: Scripts extracted from release package" -ForegroundColor Green
    }

    # Update scripts root to the downloaded location
    $script:ScriptsRoot = Join-Path $destDir "StartNet"
}

# Start WiFi connection
Write-Host "Status: Starting WiFi connection" -ForegroundColor Cyan
if ($script:BootMode -eq "USB") {
    try {
        Start-WinREWiFi -WirelessConnect -ErrorAction Stop
    }
    catch {
        Write-Host "Error: Failed to start WiFi connection" -ForegroundColor Red
        exit
    }
}
else {
    # Network boot: WiFi may already be connected, or use netsh
    try {
        # Check if already connected (ping is more reliable than Test-Connection in WinPE)
        $pingCheck = ping.exe -n 1 -w 2000 8.8.8.8 2>$null
        if ($pingCheck -match "TTL=|ttl=") {
            Write-Host "Status: Network already connected" -ForegroundColor Green
        }
        else {
            # Try to connect via stored WiFi profiles
            # Parse netsh XML output for locale-independent profile names
            $connected = $false
            try {
                $profileXml = [xml](netsh wlan show profiles 2>$null | Out-String)
                # Fallback: try text parsing for profile names (works in WinPE English locale)
                $profiles = netsh wlan show profiles 2>$null |
                    Select-String ":\s+(.+)$" |
                    ForEach-Object { $_.Matches.Groups[1].Value.Trim() }
            }
            catch {
                $profiles = @()
            }

            foreach ($profile in $profiles) {
                netsh wlan connect name="$profile" 2>$null | Out-Null
                Start-Sleep -Seconds 5
                $retryPing = ping.exe -n 1 -w 2000 8.8.8.8 2>$null
                if ($retryPing -match "TTL=|ttl=") {
                    Write-Host "Status: Connected to WiFi profile: $profile" -ForegroundColor Green
                    $connected = $true
                    break
                }
            }
            if (-not $connected) {
                Write-Host "Warning: Could not connect to WiFi automatically. Ethernet may be required." -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "Warning: WiFi setup encountered an error: $_" -ForegroundColor Yellow
    }
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
        $overlayScript = Join-Path $script:ScriptsRoot "Show-OSDCloudOverlay.ps1"
        if (-not (Test-Path $overlayScript)) {
            # Fallback to PSScriptRoot
            $overlayScript = Join-Path $PSScriptRoot "Show-OSDCloudOverlay.ps1"
        }
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