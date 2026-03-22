Start-Transcript -Path "$env:SystemRoot\Logs\SetupComplete-WindowsUpdates.log" -Force

# Import OSD Module if needed
try {
    Import-Module OSD -ErrorAction Stop
}
catch {
    Write-Output "Warning: OSD module not available. Some functions may not work."
}

# Define Windows Update Driver function if not already defined
function Start-WindowsUpdateDriver {
    param()
    
    Write-Output "Starting Windows Update Driver detection at $(Get-Date)"
    try {
        # Check if Get-WindowsDriver exists
        if (Get-Command -Name Get-WindowsDriver -ErrorAction SilentlyContinue) {
            Write-Output "Scanning for driver updates..."
            
            # Search for missing drivers
            $missingDrivers = Get-WindowsDriver -Online -All | Where-Object { $_.DriverStatus -eq "Missing" }
            
            if ($missingDrivers) {
                Write-Output "Found $($missingDrivers.Count) missing drivers"
                
                # Try to update drivers through Windows Update
                try {
                    Write-Output "Searching Windows Update for drivers..."
                    
                    # Use different methods depending on available cmdlets
                    if (Get-Command -Name Install-WindowsUpdate -ErrorAction SilentlyContinue) {
                        # Use OSD module approach if available
                        Install-WindowsUpdate -UpdateCategory Driver -AcceptAll
                    }
                    elseif (Get-Command -Name Start-WUScan -ErrorAction SilentlyContinue) {
                        # PSWindowsUpdate module approach
                        Start-WUScan -SearchCriteria "IsInstalled=0 AND Type='Driver'" -AcceptAll -Install
                    }
                    else {
                        # Fallback to basic Windows Update approach
                        Write-Output "No specialized Windows Update cmdlets found, using basic approach"
                        (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 AND Type='Driver'").Updates | ForEach-Object {
                            Write-Output "Found driver: $($_.Title)"
                        }
                    }
                }
                catch {
                    Write-Output "Error searching Windows Update: $_"
                }
            }
            else {
                Write-Output "No missing drivers detected"
            }
        }
        else {
            Write-Output "Get-WindowsDriver command not available on this system"
        }
    }
    catch {
        Write-Output "Error in Start-WindowsUpdateDriver: $_"
    }
    
    Write-Output "Completed Windows Update Driver detection at $(Get-Date)"
}

Write-Output "Running Windows Update Drivers Function [Start-WindowsUpdateDriver] | Time: $($(Get-Date).ToString("hh:mm:ss"))"
Start-WindowsUpdateDriver
Write-Output "Completed Section [Start-WindowsUpdateDriver] | Time: $($(Get-Date).ToString("hh:mm:ss"))"
Write-Output "-------------------------------------------------------------"

Write-Output "Running Windows OS Updates | Time: $($(Get-Date).ToString("hh:mm:ss"))"
try {
    # Try using Windows Update API directly
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    Write-Output "Searching for updates..."
    $searchResult = $updateSearcher.Search("IsInstalled=0")
    
    if ($searchResult.Updates.Count -gt 0) {
        Write-Output "Found $($searchResult.Updates.Count) updates to install"
        $updatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $searchResult.Updates) {
            Write-Output "Adding update: $($update.Title)"
            $updatesToDownload.Add($update) | Out-Null
        }
        
        # Download updates
        Write-Output "Downloading updates..."
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $updatesToDownload
        $downloader.Download() | Out-Null
        
        # Install updates
        Write-Output "Installing updates..."
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $updatesToDownload
        $installResult = $installer.Install()
        
        Write-Output "Update installation completed with result code: $($installResult.ResultCode)"
        Write-Output "Reboot required: $($installResult.RebootRequired)"

        # Add automatic reboot if required
        if ($installResult.RebootRequired) {
            Write-Output "Updates require a reboot - initiating restart..."
            Stop-Transcript
            # Give the transcript a moment to complete
            Start-Sleep -Seconds 2
            # Restart the computer
            Restart-Computer -Force
        }
    } else {
        Write-Output "No updates found to install"
    }
} catch {
    Write-Output "Error during Windows Update: $_"
}
Write-Output "Completed Windows OS Updates | Time: $($(Get-Date).ToString("hh:mm:ss"))"

Stop-Transcript