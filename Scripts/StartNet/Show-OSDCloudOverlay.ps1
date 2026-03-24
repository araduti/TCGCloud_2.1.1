# Import utility functions
. "$PSScriptRoot\Utils.ps1"

$script:Window = $null
$script:ExitButton = $null
$script:Timer = $null
$script:HeaderText = $null
$script:StatusText = $null
$script:IsJobRunning = $false
$script:Process = $null
$script:TechnicalViewEnabled = $false
$script:TechLogBuffer = $null
$script:HighVerbosity = $false
$script:TechBufferSize = $null
$script:StatusPatterns = $null

function Initialize-StatusPatterns {
    # Load and cache status patterns from JSON file
    try {
        $patternsPath = Join-Path $PSScriptRoot "StatusPatterns.json"
        if (-not (Test-Path $patternsPath)) {
            Write-Host "Status patterns file not found at: $patternsPath" -ForegroundColor Yellow
            return $false
        }

        $patternsJson = Get-Content -Path $patternsPath -Raw | ConvertFrom-Json
        
        # Convert JSON patterns to PowerShell objects for better performance
        $script:StatusPatterns = $patternsJson.patterns | ForEach-Object {
            @{
                Category = $_.category
                Pattern = $_.pattern
                Message = $_.message
            }
        }
        
        Write-Host "Loaded $(($script:StatusPatterns).Count) status patterns" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error loading status patterns: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-UserFriendlyMessage {
    param(
        [string]$LogLine
    )
    
    # Initialize patterns if not already loaded
    if (-not $script:StatusPatterns) {
        if (-not (Initialize-StatusPatterns)) {
            # If patterns can't be loaded, return the raw log line
            return $LogLine
        }
    }
    
    foreach ($pattern in $script:StatusPatterns) {
        if ($LogLine -match $pattern.Pattern) {
            # Use the PowerShell string expansion system to handle replacements
            return $ExecutionContext.InvokeCommand.ExpandString($pattern.Message)
        }
    }
    
    # If no pattern matches, return the original line
    return $LogLine
}

function Get-WallpaperPath {
    $ScriptPath = $PSScriptRoot
    $WallpaperPath = Join-Path $ScriptPath "..\Custom\wallpaper.jpg"
    
    # Convert to URI format
    $Uri = [System.Uri]::new($WallpaperPath)
    return $Uri.AbsoluteUri
}

function Test-FormValidation {
    param(
        [object]$Country,
        [object]$Persona,
        [object]$Language
    )

    # Initialize return object
    $Result = @{
        IsValid = $true
        Message = ""
    }

    # Check required selections
    if (-not $Country.SelectedItem) {
        $Result.IsValid = $false
        $Result.Message = "Please select a country"
        return $Result
    }

    if (-not $Persona.SelectedItem) {
        $Result.IsValid = $false
        $Result.Message = "Please select a persona"
        return $Result
    }

    if (-not $Language.SelectedItem) {
        $Result.IsValid = $false
        $Result.Message = "Please select a language"
        return $Result
    }

    return $Result
}

function Update-Status {
    param(
        [string]$Header,
        [string]$Status,
        [string]$RawLogLine = ""
    )
    
    $script:Window.Dispatcher.Invoke([Action] {
        Write-Host "Updating status - Header: $Header, Status: $Status"
        $script:HeaderText.Text = $Header
        
        if ($script:TechnicalViewEnabled) {
            # In technical view mode, we want to show more technical information
            if ($RawLogLine -and $RawLogLine.Trim() -ne "") {
                # Store the technical log lines in a buffer
                if (-not $script:TechLogBuffer) {
                    $script:TechLogBuffer = New-Object System.Collections.ArrayList
                }
                
                # If buffer size is not set, use a default of 25 lines
                if (-not $script:TechBufferSize) {
                    $script:TechBufferSize = 25
                }
                
                # Add timestamp to log entry and format it
                $timestamp = Get-Date -Format "HH:mm:ss.fff"
                $formattedLogLine = "[$timestamp] $RawLogLine"
                
                # Add to the buffer
                $null = $script:TechLogBuffer.Add($formattedLogLine)
                
                # Keep only the last N entries based on buffer size
                if ($script:TechLogBuffer.Count -gt $script:TechBufferSize) {
                    $script:TechLogBuffer.RemoveAt(0)
                }
                
                # Display all buffered log entries
                $script:StatusText.Text = $script:TechLogBuffer -join "`n"
            } else {
                # If no raw log line, use the status but prefix it
                $script:StatusText.Text = "[PROCESSED] $Status"
            }
        } else {
            # For standard view, if we have a raw log line, try to get a user-friendly message
            if ($RawLogLine -and $RawLogLine.Trim() -ne "") {
                $friendlyMessage = Get-UserFriendlyMessage -LogLine $RawLogLine
                $script:StatusText.Text = $friendlyMessage
            } else {
                # If no raw log line, use the provided status
                $script:StatusText.Text = $Status
            }
        }
    }, [System.Windows.Threading.DispatcherPriority]::Normal)
}

function Update-TechnicalInfo {
    # This function collects technical system information and updates the display
    # when in technical view mode
    
    try {
        if (-not $script:TechnicalViewEnabled) {
            return
        }
        
        # Create a buffer for technical information
        $techInfo = New-Object System.Collections.ArrayList
        
        # Add a header and current timestamp
        $null = $techInfo.Add("=== TECHNICAL INFORMATION ===")
        $null = $techInfo.Add("Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')")
        $null = $techInfo.Add("Buffer Size: $script:TechBufferSize lines (+ / - to change)")
        
        # Add OS selection information if available
        $osSelectionPath = "X:\OSDCloud\Config\Scripts\Custom\os-selection.json"
        if (Test-Path $osSelectionPath) {
            $osSelection = Get-Content $osSelectionPath | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($osSelection) {
                $null = $techInfo.Add("Selected OS: $($osSelection.OSVersion) $($osSelection.OSBuild)")
            }
        }
        
        # Get current running processes (limited to relevant ones)
        $processes = Get-Process | Where-Object { 
            $_.Name -match "powershell|cmd|wpeutil|osdcloud|diskpart|dism|setup" 
        } | Select-Object -First 10
        
        $null = $techInfo.Add("Running Processes:")
        foreach ($proc in $processes) {
            $null = $techInfo.Add("  - $($proc.Name) (PID: $($proc.Id), CPU: $($proc.CPU.ToString('0.00'))s)")
        }
        
        # Add memory information
        $memoryInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($memoryInfo) {
            $totalMB = [math]::Round($memoryInfo.TotalVisibleMemorySize / 1024)
            $freeMB = [math]::Round($memoryInfo.FreePhysicalMemory / 1024)
            $usedMB = $totalMB - $freeMB
            $percentUsed = [math]::Round(($usedMB / $totalMB) * 100)
            
            $null = $techInfo.Add("Memory: $usedMB MB used of $totalMB MB ($percentUsed%)")
        }
        
        # Add OS version info
        $null = $techInfo.Add("Operating System: Windows PE for OSDCloud")
        
        # Add disk information
        $disks = Get-Disk -ErrorAction SilentlyContinue | Select-Object -First 3
        if ($disks) {
            $null = $techInfo.Add("Disk Information:")
            foreach ($disk in $disks) {
                $sizeGB = [math]::Round($disk.Size / 1GB, 1)
                $null = $techInfo.Add("  - Disk $($disk.Number): $($disk.FriendlyName) ($sizeGB GB)")
            }
        }
        
        # Add network information
        $network = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 2
        if ($network) {
            $null = $techInfo.Add("Network Adapters:")
            foreach ($adapter in $network) {
                $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | 
                           Where-Object { $_.AddressFamily -eq 'IPv4' } | 
                           Select-Object -First 1
                
                $ipAddress = if ($ipConfig) { $ipConfig.IPAddress } else { "No IP" }
                $null = $techInfo.Add("  - $($adapter.Name): $ipAddress (Speed: $($adapter.LinkSpeed))")
            }
        }
        
        # Add a separator
        $null = $techInfo.Add("================================")
        
        # Update the display with this information if technical view is enabled
        # Only do this if there's no active log data being shown
        if ($script:TechLogBuffer.Count -eq 0) {
            $script:Window.Dispatcher.Invoke([Action] {
                $script:StatusText.Text = $techInfo -join "`n"
            }, [System.Windows.Threading.DispatcherPriority]::Normal)
        }
        else {
            # Add the tech info to the existing log buffer
            $script:TechLogBuffer.AddRange($techInfo)
            
            # Keep only the last N entries based on buffer size
            while ($script:TechLogBuffer.Count -gt $script:TechBufferSize) {
                $script:TechLogBuffer.RemoveAt(0)
            }
            
            $script:Window.Dispatcher.Invoke([Action] {
                $script:StatusText.Text = $script:TechLogBuffer -join "`n"
            }, [System.Windows.Threading.DispatcherPriority]::Normal)
        }
    }
    catch {
        Write-Host "Error updating technical info: $($_.Exception.Message)"
    }
}

function Start-DeploymentWithMonitor {
    # Launch Invoke-OSDCloudDeployment.ps1 in a hidden PowerShell process and
    # monitor its transcript log with a WPF DispatcherTimer, updating the UI
    # as each log line arrives.  Both the registered-device and the
    # unregistered-device (post-Autopilot) code paths use this shared helper.
    $ScriptBlock = Get-Content -Path "X:\OSDCloud\Config\Scripts\StartNet\Invoke-OSDCloudDeployment.ps1" -Raw
    $OsdBytes    = [System.Text.Encoding]::Unicode.GetBytes($ScriptBlock)
    $OsdEncoded  = [Convert]::ToBase64String($OsdBytes)
    $script:Process = Start-Process powershell.exe `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $OsdEncoded `
        -WindowStyle Hidden -PassThru

    $script:OsdLastCount = 0
    $OsdTimer = New-Object System.Windows.Threading.DispatcherTimer
    $OsdTimer.Interval = [TimeSpan]::FromSeconds(1)
    $OsdTimer.Add_Tick({
        try {
            $OsdLogPath = "X:\OSDCloud\Logs\TCGCloud-Transcript.log"
            if (Test-Path $OsdLogPath) {
                $AllOSDLines = Get-Content $OsdLogPath -ErrorAction SilentlyContinue
                if ($AllOSDLines -and $AllOSDLines.Count -gt $script:OsdLastCount) {
                    $NewLines = $AllOSDLines[$script:OsdLastCount..($AllOSDLines.Count - 1)]
                    $script:OsdLastCount = $AllOSDLines.Count

                    foreach ($Line in $NewLines) {
                        # Technical view - show all non-empty raw log lines
                        if ($script:TechnicalViewEnabled) {
                            if ($Line.Trim() -ne "") {
                                Update-Status "TECHNICAL VIEW" "Raw OSDCloud Log" $Line
                            }
                            # Continue to next line to avoid processing through the status map
                            continue
                        }

                        # Check for completion markers
                        if ($Line -match "OSDCloud Finished|TCGCloud Finished") {
                            Write-Host "TCGCloud installation complete, initiating reboot..."
                            Update-Status "Installation Complete" "Rebooting..."
                            # Wait a few seconds to show the status
                            Start-Sleep -Seconds 3
                            # Initiate reboot
                            Start-Process wpeutil reboot
                            return
                        }

                        # Standard view - process through status map
                        $MessageUpdated = $false
                        foreach ($Rule in $script:StatusPatterns) {
                            if ($Line -match $Rule.Pattern) {
                                $Msg = $ExecutionContext.InvokeCommand.ExpandString($Rule.Message)
                                Update-Status "Setting up your device" $Msg $Line
                                $MessageUpdated = $true
                                break
                            }
                        }
                    }
                }
            }

            # Also check if the process has exited
            if ($script:Process.HasExited) {
                $exitCode = $script:Process.ExitCode
                Write-Host "TCGCloud deployment process exited with code: $exitCode"
                if ($exitCode -eq 0) {
                    Update-Status "Installation Complete" "Rebooting..."
                } else {
                    Update-Status "Installation Failed" ""
                }
                # Wait a few seconds to show the status
                Start-Sleep -Seconds 3
                # Initiate reboot
                Start-Process wpeutil reboot
                return
            }
        }
        catch {
            Write-Host "Error in OSDCloud timer tick: $($_.Exception.Message)"
        }
    })
    $OsdTimer.Start()
}

function Show-OSDCloudOverlay {
    [CmdletBinding()]
    param()

    try {
        # Load required assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # Load XAML from file
        $XamlPath = Join-Path $PSScriptRoot "OSDCloudOverlay.xaml"
        if (-not (Test-Path $XamlPath)) {
            throw "XAML file not found at: $XamlPath"
        }
        [xml]$Xaml = Get-Content -Path $XamlPath -Raw

        # Add a technical view button if it doesn't exist in the XAML
        $TechnicalButtonNode = $Xaml.SelectSingleNode("//Button[@Name='TechnicalViewButton']")
        if (-not $TechnicalButtonNode) {
            Write-Host "Adding Technical View button to XAML"
            
            # Get the root Grid
            $RootGrid = $Xaml.SelectSingleNode("//Grid")
            if ($RootGrid) {
                # Create a new button element
                $ButtonElement = $Xaml.CreateElement("Button")
                $ButtonElement.SetAttribute("Name", "TechnicalViewButton")
                $ButtonElement.SetAttribute("Content", "Technical View")
                $ButtonElement.SetAttribute("Width", "120")
                $ButtonElement.SetAttribute("Height", "30")
                $ButtonElement.SetAttribute("HorizontalAlignment", "Right")
                $ButtonElement.SetAttribute("VerticalAlignment", "Bottom")
                $ButtonElement.SetAttribute("Margin", "0,0,10,10")
                $ButtonElement.SetAttribute("Background", "#333333")
                $ButtonElement.SetAttribute("Foreground", "White")
                $ButtonElement.SetAttribute("BorderBrush", "#666666")
                
                # Add the button to the root Grid
                $RootGrid.AppendChild($ButtonElement)
            }
        }

        # Create window
        $Reader = [System.Xml.XmlNodeReader]::New($Xaml)
        $script:Window = [System.Windows.Markup.XamlReader]::Load($Reader)
        
        # Get controls
        $script:ExitButton = $script:Window.FindName("ExitButton")
        $script:progressGrid = $script:Window.FindName("ProgressGrid")
        $script:selectionPanel = $script:Window.FindName("SelectionPanel")
        $script:countrySelector = $script:Window.FindName("CountrySelector")
        $script:personaSelector = $script:Window.FindName("PersonaSelector")
        $script:languageSelector = $script:Window.FindName("LanguageSelector")
        $script:continueButton = $script:Window.FindName("ContinueButton")
        $script:HeaderText = $script:Window.FindName("HeaderText")
        $script:StatusText = $script:Window.FindName("StatusText")
        $script:backgroundImage = $script:Window.FindName("BackgroundImage")
        $script:technicalViewButton = $script:Window.FindName("TechnicalViewButton")

        # Set up the Technical View button
        if ($script:technicalViewButton) {
            Write-Host "Setting up Technical View button"
            $script:technicalViewButton.Add_Click({
                $script:TechnicalViewEnabled = -not $script:TechnicalViewEnabled
                if ($script:TechnicalViewEnabled) {
                    $script:technicalViewButton.Content = "User View"
                    $script:StatusText.TextWrapping = "Wrap"
                    $script:StatusText.VerticalAlignment = "Top"
                    $script:TechLogBuffer = New-Object System.Collections.ArrayList
                    $script:TechBufferSize = 25  # Set default buffer size
                    Update-Status "TECHNICAL VIEW" "Showing raw log output for troubleshooting"
                    Write-Host "Technical view enabled via button"
                    
                    # Set high verbosity flag
                    $script:HighVerbosity = $true
                    
                    # Adjust font size for technical view
                    $script:StatusText.FontSize = 14
                    
                    # Make text monospaced for technical view
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
                    
                    # Start a timer to update technical info
                    $script:TechInfoTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:TechInfoTimer.Interval = [TimeSpan]::FromSeconds(10)
                    $script:TechInfoTimer.Add_Tick({ Update-TechnicalInfo })
                    $script:TechInfoTimer.Start()
                    
                    # Run it once immediately
                    Update-TechnicalInfo
                } else {
                    $script:technicalViewButton.Content = "Technical View"
                    $script:StatusText.TextWrapping = "NoWrap"
                    $script:StatusText.VerticalAlignment = "Center"
                    $script:TechLogBuffer = $null
                    $script:HighVerbosity = $false
                    $script:StatusText.FontSize = 24
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Semibold")
                    
                    # Stop the technical info timer
                    if ($script:TechInfoTimer) {
                        $script:TechInfoTimer.Stop()
                    }
                    
                    Update-Status "Setting up your device" "Returning to user-friendly view"
                    Write-Host "Technical view disabled via button"
                }
            })
        }
        else {
            Write-Host "Technical View button not found in XAML" -ForegroundColor Yellow
        }

        # Hide the selection form for now
        $script:selectionPanel.Visibility = 'Collapsed'

        # Build full path to the prereq script
        $PrereqPath = Join-Path $PSScriptRoot "Invoke-Prereq.ps1"
        if (-not (Test-Path $PrereqPath)) {
            throw "Invoke-Prereq.ps1 not found at: $PrereqPath"
        }

        # Start it in a separate PowerShell process
        $PrereqProcess = Start-Process powershell.exe `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PrereqPath `
            -WindowStyle Hidden -PassThru
        $PrereqTimer = New-Object System.Windows.Threading.DispatcherTimer
        $PrereqTimer.Interval = [TimeSpan]::FromSeconds(1)
        $PrereqLogPath = "X:\OSDCloud\Logs\Prereq-Transcript.log"
        $PrereqLastCount = 0
        # Declare a variable to lock in the final status
        $script:FinalStatusSet = $false

        $PrereqTimer.Add_Tick({
                # If final status is already set, exit immediately.
                if ($script:FinalStatusSet) { return }

                try {
                    # Check if the prereq process has exited.
                    if ($PrereqProcess.HasExited) {
                        # Stop the timer immediately.
                        $PrereqTimer.Stop()
            
                        # Read the transcript one final time.
                        $FinalMarker = ""
                        if (Test-Path $PrereqLogPath) {
                            $AllLines = Get-Content $PrereqLogPath -ErrorAction SilentlyContinue
                            # Filter out blank lines.
                            $NonEmptyLines = $AllLines | Where-Object { $_.Trim() -ne "" }
                            # Look for a line that begins with "FINAL_RESULT:"
                            foreach ($Line in $NonEmptyLines) {
                                if ($Line -match "^FINAL_RESULT:") {
                                    $FinalMarker = $Line.Trim()
                                    break
                                }
                            }
                        }
                        Write-Host "DEBUG: Final marker: $FinalMarker ($($PrereqProcess.ExitCode))"
            
                        # Lock in the final status.
                        $script:FinalStatusSet = $true

                        # Update the UI based on the final marker.
                        if ($FinalMarker -match "^FINAL_RESULT:\s*Registered in Autopilot") {
                            # If registered, hide the form and start automated deployment
                            Write-Host "DEBUG: Device is registered in Autopilot"
                            Update-Status "Device Registered" "This device is registered in Autopilot. Starting installation..."
                            $script:selectionPanel.Visibility = "Collapsed"
                            $script:progressGrid.Visibility = "Visible"
                            
                            # Get the token and check Autopilot status to get the GroupTag
                            $token = Get-GraphToken
                            if ($token) {
                                # Token acquired successfully, continue with Autopilot status check
                                $serialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber
                                $AutopilotStatus = Test-AutopilotStatus -serialNumber $serialNumber -token $token
                                
                                if ($AutopilotStatus.Success -and $AutopilotStatus.IsRegistered -and $AutopilotStatus.GroupTag) {
                                    # Continue with OSDCloud setup for registered device
                                    Write-Host "DEBUG: Starting OSDCloud installation for registered device with GroupTag: $($AutopilotStatus.GroupTag)"
                                    
                                    # Extract country and persona from GroupTag (format: COUNTRY-PERSONA)
                                    $groupTagParts = $AutopilotStatus.GroupTag -split '-'
                                    $country = $groupTagParts[0]
                                    $persona = $groupTagParts[1]
                                    
                                    # Detect language from OS files or GroupTag
                                    $detectedLanguage = "en-us" # Default fallback
                                    
                                    # First check if we have an OS selection file with language info
                                    $osSelectionPath = "X:\OSDCloud\Config\Scripts\Custom\os-selection.json"
                                    if (Test-Path $osSelectionPath) {
                                        $osSelection = Get-Content $osSelectionPath | ConvertFrom-Json -ErrorAction SilentlyContinue
                                        if ($osSelection -and $osSelection.OSLanguage) {
                                            $detectedLanguage = $osSelection.OSLanguage
                                            Write-Host "DEBUG: Using language from OS selection: $detectedLanguage" -ForegroundColor Green
                                        }
                                    }
                                    
                                    # Next, try to detect from OS files on USB
                                    if ($detectedLanguage -eq "en-us") {
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
                                                        Write-Host "DEBUG: Found OS file for language detection: $osFileName" -ForegroundColor Green
                                                        
                                                        # Look for language code in the filename
                                                        if ($osFileName -match "_(sv-se|sv|swedish)") {
                                                            $detectedLanguage = "sv-se"
                                                            Write-Host "DEBUG: Detected Swedish language from OS file" -ForegroundColor Green
                                                        }
                                                        elseif ($osFileName -match "_(de-de|de|german)") {
                                                            $detectedLanguage = "de-de"
                                                            Write-Host "DEBUG: Detected German language from OS file" -ForegroundColor Green
                                                        }
                                                        elseif ($osFileName -match "_(fr-fr|fr|french)") {
                                                            $detectedLanguage = "fr-fr"
                                                            Write-Host "DEBUG: Detected French language from OS file" -ForegroundColor Green
                                                        }
                                                        elseif ($osFileName -match "_(es-es|es|spanish)") {
                                                            $detectedLanguage = "es-es"
                                                            Write-Host "DEBUG: Detected Spanish language from OS file" -ForegroundColor Green
                                                        }
                                                        elseif ($osFileName -match "_(en-us|en|english)") {
                                                            $detectedLanguage = "en-us"
                                                            Write-Host "DEBUG: Detected English language from OS file" -ForegroundColor Green
                                                        }
                                                        break
                                                    }
                                                }
                                            }
                                        }
                                        catch {
                                            Write-Host "DEBUG: Error detecting language from OS files: $_" -ForegroundColor Yellow
                                        }
                                    }
                                    
                                    # Third, try to infer from country if we still have default
                                    if ($detectedLanguage -eq "en-us") {
                                        # Map country codes to language codes
                                        $countryToLanguage = @{
                                            "SE" = "sv-se"
                                            "SWE" = "sv-se"
                                            "DE" = "de-de"
                                            "GER" = "de-de"
                                            "FR" = "fr-fr"
                                            "FRA" = "fr-fr"
                                            "ES" = "es-es"
                                            "ESP" = "es-es"
                                            "US" = "en-us"
                                            "UK" = "en-gb"
                                            "GB" = "en-gb"
                                            "ENG" = "en-us"
                                        }
                                        
                                        if ($countryToLanguage.ContainsKey($country.ToUpper())) {
                                            $detectedLanguage = $countryToLanguage[$country.ToUpper()]
                                            Write-Host "DEBUG: Inferred language from country: $country -> $detectedLanguage" -ForegroundColor Green
                                        }
                                    }
                                    
                                    Write-Host "DEBUG: Using language: $detectedLanguage" -ForegroundColor Cyan
                                    
                                    # Create JSON selection file with values from GroupTag
                                    $selections = @{
                                        Country = $country
                                        Persona = $persona
                                        Language = $detectedLanguage
                                    }
                                    
                                    # Save selections for OSDCloud process
                                    $selectionsPath = "X:\OSDCloud\Config\Scripts\Custom\osd-selections.json"
                                    New-Item -Path (Split-Path $selectionsPath) -ItemType Directory -Force -ErrorAction SilentlyContinue
                                    $selections | ConvertTo-Json | Set-Content -Path $selectionsPath -Force
                                    
                                    # Start OSDCloud process (shared deployment script) and monitor its log
                                    Start-DeploymentWithMonitor
                                } else {
                                    Write-Host "Failed to get Autopilot status or GroupTag"
                                    Update-Status "Error" "Failed to get device information"
                                    $script:ExitButton.Visibility = "Visible"
                                }
                            } else {
                                Write-Host "Failed to get Graph token"
                                Update-Status "Error" "Failed to connect to Microsoft services"
                                $script:ExitButton.Visibility = "Visible"
                            }
                        }
                        elseif ($FinalMarker -match "^FINAL_RESULT:\s*Not registered in Autopilot" -or $PrereqProcess.ExitCode -eq 2) {
                            # CRITICAL FIX: Explicitly handle the Not Registered condition
                            Write-Host "DEBUG: Device not registered in Autopilot, showing registration form (Exit code: $($PrereqProcess.ExitCode))" -ForegroundColor Yellow
                            Update-Status "Device Setup" "Please select options to register this device"
                            
                            # Set default values for the selection form
                            try {
                                # Don't pre-select any options - clear all selections
                                if ($script:countrySelector) {
                                    $script:countrySelector.SelectedIndex = -1
                                    Write-Host "DEBUG: Cleared country selection - user must select" -ForegroundColor Green
                                }
                                
                                if ($script:personaSelector) {
                                    $script:personaSelector.SelectedIndex = -1
                                    Write-Host "DEBUG: Cleared persona selection - user must select" -ForegroundColor Green
                                }
                                
                                if ($script:languageSelector) {
                                    $script:languageSelector.SelectedIndex = -1
                                    Write-Host "DEBUG: Cleared language selection - user must select" -ForegroundColor Green
                                }
                                
                                # Ensure the continue button starts disabled
                                if ($script:continueButton) {
                                    $script:continueButton.IsEnabled = $false
                                    Write-Host "DEBUG: Disabled continue button until selections are made" -ForegroundColor Green
                                }
                                
                                # Add event handlers for selection changed to enable/disable continue button
                                $selectionChangedHandler = {
                                    # Enable continue button only if all selections are made
                                    $enableButton = ($script:countrySelector.SelectedIndex -ge 0) -and 
                                                    ($script:personaSelector.SelectedIndex -ge 0) -and
                                                    ($script:languageSelector.SelectedIndex -ge 0)
                                    
                                    $script:continueButton.IsEnabled = $enableButton
                                }
                                
                                # Attach the handler to all selectors
                                $script:countrySelector.add_SelectionChanged($selectionChangedHandler)
                                $script:personaSelector.add_SelectionChanged($selectionChangedHandler)
                                $script:languageSelector.add_SelectionChanged($selectionChangedHandler)
                            }
                            catch {
                                Write-Host "ERROR setting default selections: $_" -ForegroundColor Red
                            }
                            
                            # Force UI update to ensure form is visible
                            $script:Window.Dispatcher.Invoke([Action] {
                                # First ensure selections are present
                                if ($script:countrySelector.SelectedIndex -lt 0 -and $script:countrySelector.Items.Count -gt 0) {
                                    $script:countrySelector.SelectedIndex = 0
                                }
                                if ($script:personaSelector.SelectedIndex -lt 0 -and $script:personaSelector.Items.Count -gt 0) {
                                    $script:personaSelector.SelectedIndex = 0
                                }
                                if ($script:languageSelector.SelectedIndex -lt 0 -and $script:languageSelector.Items.Count -gt 0) {
                                    $script:languageSelector.SelectedIndex = 0
                                }
                                
                                # Make form elements visible with highest priority
                                $script:selectionPanel.Visibility = "Visible"
                                $script:progressGrid.Visibility = "Collapsed"
                                $script:continueButton.IsEnabled = $true
                                
                                Write-Host "DEBUG: Set selection panel visible and enabled continue button" -ForegroundColor Green
                            }, [System.Windows.Threading.DispatcherPriority]::Send)
                        }
                        elseif ($FinalMarker -match "^FINAL_RESULT:\s*Could not get Graph token") {
                            Write-Host "DEBUG: Failed to get Graph token"
                            Update-Status "Connection Error" "Unable to connect to Microsoft services"
                            $script:ExitButton.Visibility = "Visible"
                        }
                        else {
                            Write-Host "DEBUG: Unknown final result: $FinalMarker"
                            Update-Status "Setup Failed" "Unknown error occurred"
                            $script:ExitButton.Visibility = "Visible"
                        }
                        return
                    }

                    # Monitor log file for status updates while process is running
                    if (Test-Path $PrereqLogPath) {
                        $AllLines = Get-Content $PrereqLogPath -ErrorAction SilentlyContinue
                        if ($AllLines -and $AllLines.Count -gt $PrereqLastCount) {
                            $NewLines = $AllLines[$PrereqLastCount..($AllLines.Count - 1)]
                            $PrereqLastCount = $AllLines.Count
                            
                            foreach ($Line in $NewLines) {
                                if ($Line -match "^Status:\s*(.+)$") {
                                    Update-Status "Setting up your device" $matches[1] $Line
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Host "Error in prereq timer tick: $($_.Exception.Message)"
                    if ($PrereqProcess -and -not $PrereqProcess.HasExited) {
                        Stop-Process -Id $PrereqProcess.Id -Force -ErrorAction SilentlyContinue
                    }
                    $PrereqTimer.Stop()
                    Update-Status "Error" $_.Exception.Message
                    $script:ExitButton.Visibility = "Visible"
                }
            })

        $PrereqTimer.Start()
    
        $script:continueButton.Add_Click({
                try {
                    if ($script:IsJobRunning) {
                        Write-Host "Installation already in progress"
                        return
                    }

                    # Store selections and update UI
                    $selections = @{
                        Country  = $script:countrySelector.SelectedItem.Tag
                        Persona  = $script:personaSelector.SelectedItem.Tag
                        Language = $script:languageSelector.SelectedItem.Tag
                    }

                    $script:continueButton.IsEnabled = $false
                    $script:selectionPanel.Visibility = "Collapsed"
                    $script:progressGrid.Visibility = "Visible"
                    Update-Status "Registering device" "Starting Autopilot registration"

                    # Create log directory
                    $logDir = "X:\OSDCloud\Logs"
                    New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue

                    # Save selections
                    $selectionsPath = "X:\OSDCloud\Config\Scripts\Custom\osd-selections.json"
                    New-Item -Path (Split-Path $selectionsPath) -ItemType Directory -Force -ErrorAction SilentlyContinue
                    $selections | ConvertTo-Json | Set-Content -Path $selectionsPath -Force

                    $script:IsJobRunning = $true

                    # Build path to Invoke-ImportAutopilot.ps1
                    $importAutopilotPath = Join-Path $PSScriptRoot "Invoke-ImportAutopilot.ps1"
                    if (-not (Test-Path $importAutopilotPath)) {
                        throw "Invoke-ImportAutopilot.ps1 not found at: $importAutopilotPath"
                    }

                    # Create script block for Autopilot registration
                    $AutopilotScriptBlock = @"
                        `$ErrorActionPreference = 'Stop'
                        Start-Transcript -Path "X:\OSDCloud\Logs\Autopilot-Transcript.log" -Force

                        try {
                            # Read selections
                            `$selections = Get-Content "$selectionsPath" | ConvertFrom-Json
                            Write-Host "Status: Processing registration with selections: Country=`$(`$selections.Country), Persona=`$(`$selections.Persona)"

                            # Import the Autopilot script
                            . "$importAutopilotPath"

                            # Create GroupTag from selections
                            `$GroupTag = "`$(`$selections.Country)-`$(`$selections.Persona)"
                            Write-Host "Status: Using GroupTag: `$GroupTag"

                            # Run the import process with the selections
                            `$result = Import-AutopilotDevice -GroupTag `$GroupTag -UserEmail `$selections.Email
                            
                            if (`$result.Success) {
                                Write-Host "FINAL_RESULT: Registered in Autopilot with GroupTag `$GroupTag"
                                exit 0
                            } else {
                                Write-Host "FINAL_RESULT: Failed to register - `$(`$result.Message)"
                                exit 1
                            }
                        }
                        catch {
                            Write-Host "FINAL_RESULT: Error during registration - `$(`$_.Exception.Message)"
                            Write-Error `$_
                            exit 1
                        }
                        finally {
                            Stop-Transcript
                        }
"@

                    # Convert script block to encoded command
                    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($AutopilotScriptBlock)
                    $EncodedCommand = [Convert]::ToBase64String($Bytes)

                    # Start Autopilot registration process
                    $script:AutopilotProcess = Start-Process powershell.exe `
                        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $EncodedCommand `
                        -WindowStyle Hidden -PassThru

                    # Create timer to monitor Autopilot registration
                    $script:AutopilotTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:AutopilotTimer.Interval = [TimeSpan]::FromSeconds(1)
                    $script:AutopilotLogPath = "X:\OSDCloud\Logs\Autopilot-Transcript.log"
                    $script:AutopilotLastCount = 0

                    $script:AutopilotTimer.Add_Tick({
                            try {
                                # Check if the Autopilot process has exited
                                if ($script:AutopilotProcess.HasExited) {
                                    $script:AutopilotTimer.Stop()
                                    
                                    # Sleep an extra second to ensure logs are written
                                    Start-Sleep -Seconds 1

                                    # Read the final result from the transcript
                                    $FinalResult = ""
                                    if (Test-Path $script:AutopilotLogPath) {
                                        $AllLogLines = Get-Content $script:AutopilotLogPath -ErrorAction SilentlyContinue
                                        # Get any lines containing "FINAL_RESULT:"
                                        $FinalResult = $AllLogLines | Where-Object { $_ -match "^FINAL_RESULT:" } | Select-Object -Last 1
                                        
                                        # In technical view, display the entire log one last time
                                        if ($script:TechnicalViewEnabled -and $AllLogLines) {
                                            # Just display the last line as a final status update
                                            $lastContentLine = ($AllLogLines | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
                                            if ($lastContentLine) {
                                                Update-Status "TECHNICAL VIEW" "Autopilot Process Completed" $lastContentLine
                                            }
                                        }
                                    }

                                    if ($script:AutopilotProcess.ExitCode -eq 0 -and $FinalResult -match "Registered in Autopilot") {
                                        Write-Host "Autopilot registration successful, starting OSDCloud..."
                                        Update-Status "Setting up your device" "Starting installation..."
                                        
                                        # Start OSDCloud process (shared deployment script) and monitor its log
                                        Start-DeploymentWithMonitor
                                    }
                                    else {
                                        $errorMessage = if ($FinalResult -match "^FINAL_RESULT:\s*(.+)$") {
                                            $matches[1]
                                        }
                                        else {
                                            "Registration failed with exit code: $($script:AutopilotProcess.ExitCode)"
                                        }
                                        Write-Host "Autopilot registration failed: $errorMessage"
                                        Update-Status "Registration Failed" $errorMessage
                                        $script:ExitButton.Visibility = "Visible"
                                        $script:IsJobRunning = $false
                                    }
                                }
                                else {
                                    # Monitor Autopilot registration progress while process is running
                                    if (Test-Path $script:AutopilotLogPath) {
                                        $AllLines = Get-Content $script:AutopilotLogPath -ErrorAction SilentlyContinue
                                        if ($AllLines -and $AllLines.Count -gt $script:AutopilotLastCount) {
                                            $NewLines = $AllLines[$script:AutopilotLastCount..($AllLines.Count - 1)]
                                            $script:AutopilotLastCount = $AllLines.Count
                                    
                                            foreach ($Line in $NewLines) {
                                                # Technical view - always show raw log output when enabled
                                                if ($script:TechnicalViewEnabled) {
                                                    if ($Line.Trim() -ne "") {
                                                        Update-Status "TECHNICAL VIEW" "Autopilot Registration" $Line
                                                    }
                                                    continue  # Skip standard processing when in technical view
                                                }
                                                
                                                # Standard view - process status updates
                                                if ($Line -match "^Status:\s*(.+)$") {
                                                    Update-Status "Registering device" $matches[1] $Line
                                                }
                                                elseif ($Line -match "GroupTag: (.+)") {
                                                    Update-Status "Registering device" "Setting group tag: $($matches[1])" $Line
                                                }
                                                elseif ($Line -match "Get-WindowsAutopilotInfo") {
                                                    Update-Status "Registering device" "Collecting hardware information" $Line
                                                }
                                                elseif ($Line -match "Register-AutopilotDevice") {
                                                    Update-Status "Registering device" "Sending information to Autopilot service" $Line
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Host "Error in Autopilot timer tick: $($_.Exception.Message)"
                                if ($script:AutopilotProcess -and -not $script:AutopilotProcess.HasExited) {
                                    Stop-Process -Id $script:AutopilotProcess.Id -Force -ErrorAction SilentlyContinue
                                }
                                $script:AutopilotTimer.Stop()
                                Update-Status "Error" "Registration failed: $($_.Exception.Message)"
                                $script:ExitButton.Visibility = "Visible"
                                $script:IsJobRunning = $false
                            }
                        })

                    $script:AutopilotTimer.Start()
                }
                catch {
                    Write-Host "Error: $($_.Exception.Message)"
                    Write-Host $_.ScriptStackTrace
                    Update-Status "Error" $_.Exception.Message
                    $script:ExitButton.Visibility = "Visible"
                    $script:continueButton.IsEnabled = $true
                    $script:IsJobRunning = $false
                }
            })

        # Exit button handler
        $script:ExitButton.Add_Click({
            $script:Window.Close()
            })

        # Keep trying the keyboard handler but add more debugging
        $script:Window.Add_KeyDown({
            param($sender, $e)
        
            $keyPressed = $e.Key.ToString()
            Write-Host "Key pressed: $keyPressed (Key code: $([int]$e.Key))"
        
            if ($keyPressed -eq "F10" -or $keyPressed -eq "System.Windows.Input.Key.F10") {
                Write-Host "F10 pressed - toggling technical view..."
                # Toggle technical view
                $script:TechnicalViewEnabled = -not $script:TechnicalViewEnabled
                
                if ($script:TechnicalViewEnabled) {
                    $script:StatusText.TextWrapping = "Wrap"
                    $script:StatusText.VerticalAlignment = "Top"
                    $script:TechLogBuffer = New-Object System.Collections.ArrayList
                    $script:HighVerbosity = $true
                    $script:TechBufferSize = 25  # Default buffer size
                    $script:StatusText.FontSize = 14
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
                    
                    # Start a timer to update technical info
                    $script:TechInfoTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:TechInfoTimer.Interval = [TimeSpan]::FromSeconds(10)
                    $script:TechInfoTimer.Add_Tick({ Update-TechnicalInfo })
                    $script:TechInfoTimer.Start()
                    
                    # Run it once immediately
                    Update-TechnicalInfo
                    
                    Update-Status "TECHNICAL VIEW" "Showing raw log output for troubleshooting"
                    
                    # Update button text if it exists
                    if ($script:technicalViewButton) {
                        $script:technicalViewButton.Content = "User View"
                    }
                    
                    Write-Host "Technical view enabled via F10 key"
                } else {
                    $script:StatusText.TextWrapping = "NoWrap"
                    $script:StatusText.VerticalAlignment = "Center"
                    $script:TechLogBuffer = $null
                    $script:HighVerbosity = $false
                    $script:StatusText.FontSize = 24
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Semibold")
                    
                    # Stop the technical info timer
                    if ($script:TechInfoTimer) {
                        $script:TechInfoTimer.Stop()
                    }
                    
                    Update-Status "Setting up your device" "Returning to user-friendly view"
                    
                    # Update button text if it exists
                    if ($script:technicalViewButton) {
                        $script:technicalViewButton.Content = "Technical View"
                    }
                    
                    Write-Host "Technical view disabled via F10 key"
                }
            }
            elseif ($keyPressed -eq "T") {
                # Alternative keyboard shortcut - just press 'T'
                Write-Host "T key pressed - toggling technical view..."
                $script:TechnicalViewEnabled = -not $script:TechnicalViewEnabled
                
                if ($script:TechnicalViewEnabled) {
                    $script:StatusText.TextWrapping = "Wrap"
                    $script:StatusText.VerticalAlignment = "Top"
                    $script:TechLogBuffer = New-Object System.Collections.ArrayList
                    $script:HighVerbosity = $true
                    $script:TechBufferSize = 25  # Default buffer size
                    $script:StatusText.FontSize = 14
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
                    
                    # Start a timer to update technical info
                    $script:TechInfoTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:TechInfoTimer.Interval = [TimeSpan]::FromSeconds(10)
                    $script:TechInfoTimer.Add_Tick({ Update-TechnicalInfo })
                    $script:TechInfoTimer.Start()
                    
                    # Run it once immediately
                    Update-TechnicalInfo
                    
                    Update-Status "TECHNICAL VIEW" "Showing raw log output for troubleshooting"
                    
                    # Update button text if it exists
                    if ($script:technicalViewButton) {
                        $script:technicalViewButton.Content = "User View"
                    }
                    
                    Write-Host "Technical view enabled via T key"
                } else {
                    $script:StatusText.TextWrapping = "NoWrap"
                    $script:StatusText.VerticalAlignment = "Center"
                    $script:TechLogBuffer = $null
                    $script:HighVerbosity = $false
                    $script:StatusText.FontSize = 24
                    $script:StatusText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Semibold")
                    
                    # Stop the technical info timer
                    if ($script:TechInfoTimer) {
                        $script:TechInfoTimer.Stop()
                    }
                    
                    Update-Status "Setting up your device" "Returning to user-friendly view"
                    
                    # Update button text if it exists
                    if ($script:technicalViewButton) {
                        $script:technicalViewButton.Content = "Technical View"
                    }
                    
                    Write-Host "Technical view disabled via T key"
                }
            }
            # Add buffer size adjustment shortcuts
            elseif ($script:TechnicalViewEnabled -and $keyPressed -eq "Add") {
                # Increase buffer size with + key
                if (-not $script:TechBufferSize) { $script:TechBufferSize = 25 }
                $script:TechBufferSize += 10
                if ($script:TechBufferSize -gt 100) { $script:TechBufferSize = 100 }  # Max 100 lines
                Update-Status "TECHNICAL VIEW" "Increased buffer size to $($script:TechBufferSize) lines"
                Write-Host "Buffer size increased to $($script:TechBufferSize)"
            }
            elseif ($script:TechnicalViewEnabled -and $keyPressed -eq "Subtract") {
                # Decrease buffer size with - key
                if (-not $script:TechBufferSize) { $script:TechBufferSize = 25 }
                $script:TechBufferSize -= 10
                if ($script:TechBufferSize -lt 5) { $script:TechBufferSize = 5 }  # Min 5 lines
                Update-Status "TECHNICAL VIEW" "Decreased buffer size to $($script:TechBufferSize) lines"
                Write-Host "Buffer size decreased to $($script:TechBufferSize)"
            }
            elseif ($script:TechnicalViewEnabled -and $keyPressed -eq "D1") {
                # Quick shortcut: Set to 10 lines with 1 key
                $script:TechBufferSize = 10
                Update-Status "TECHNICAL VIEW" "Buffer size set to 10 lines"
            }
            elseif ($script:TechnicalViewEnabled -and $keyPressed -eq "D3") {
                # Quick shortcut: Set to 30 lines with 3 key
                $script:TechBufferSize = 30
                Update-Status "TECHNICAL VIEW" "Buffer size set to 30 lines"
            }
            elseif ($script:TechnicalViewEnabled -and $keyPressed -eq "D5") {
                # Quick shortcut: Set to 50 lines with 5 key
                $script:TechBufferSize = 50
                Update-Status "TECHNICAL VIEW" "Buffer size set to 50 lines"
            }
            elseif ($keyPressed -eq "F12") {
                Write-Host "F12 pressed - forcing exit..."
                Stop-Process -Id $PID -Force
            }
            elseif ($keyPressed -eq "Escape") {
                Write-Host "ESC pressed - closing window..."
                
                # Stop the timer first
                if ($script:Timer) {
                    Write-Host "Stopping timer..."
                    $script:Timer.Stop()
                }
                
                # Kill the OSDCloud process if it's running
                if ($script:Process -and -not $script:Process.HasExited) {
                    Write-Host "Stopping OSDCloud process..."
                    Stop-Process -Id $script:Process.Id -Force -ErrorAction SilentlyContinue
                }
                
                # Finally close the window
                $script:Window.Close()
            }
        })

        # Load background image
        try {
            $ImagePath = Join-Path $PSScriptRoot "..\Custom\wallpaper.jpg"
            if (Test-Path $ImagePath) {
                $ImageStream = [System.IO.File]::OpenRead($ImagePath)
                $Bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $Bitmap.BeginInit()
                $Bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $Bitmap.StreamSource = $ImageStream
                $Bitmap.EndInit()
                $Bitmap.Freeze()
                $ImageStream.Close()
                $ImageStream.Dispose()
                
                $script:BackgroundImage.ImageSource = $Bitmap
            }
            
            # Load logo image
            $LogoPath = Join-Path $PSScriptRoot "..\Custom\thomas-logo.png"
            if (Test-Path $LogoPath) {
                $LogoStream = [System.IO.File]::OpenRead($LogoPath)
                $LogoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $LogoBitmap.BeginInit()
                $LogoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $LogoBitmap.StreamSource = $LogoStream
                $LogoBitmap.EndInit()
                $LogoBitmap.Freeze()
                $LogoStream.Close()
                $LogoStream.Dispose()
                
                $script:LogoImage = $script:Window.FindName("LogoImage")
                $script:LogoImage.Source = $LogoBitmap
            }
            else {
                Write-Host "Logo image not found at: $LogoPath" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Failed to load images: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Show window
        $script:Window.ShowDialog()
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        throw
    }
}

# Start the overlay
try {
    # Initialize status patterns
    if (-not (Initialize-StatusPatterns)) {
        Write-Host "Warning: Unable to load status patterns from JSON file, using fallback messages" -ForegroundColor Yellow
    }
    else {
        Write-Host "Successfully loaded status patterns from JSON file" -ForegroundColor Green
    }
    
    Show-OSDCloudOverlay
}
catch {
    Write-Host "Failed to start overlay: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Read-Host "Press Enter to continue..."
}