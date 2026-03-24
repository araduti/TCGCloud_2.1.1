Start-Transcript -Path "$env:SystemRoot\Logs\SetupComplete-WindowsUpdates.log" -Force

# Load TCGCloud module for on-demand, vendor-specific driver installation
$tcgModulePath = 'C:\OSDCloud\Config\Scripts\Modules\TCGCloud\TCGCloud.psd1'
if (Test-Path $tcgModulePath) {
    Import-Module $tcgModulePath -Force -ErrorAction SilentlyContinue
}

Write-Output "Running vendor-specific driver updates [Invoke-TCGDriverUpdate] | Time: $($(Get-Date).ToString("hh:mm:ss"))"
if (Get-Command -Name Invoke-TCGDriverUpdate -ErrorAction SilentlyContinue) {
    $driverResult = Invoke-TCGDriverUpdate -Force -LogPath "$env:SystemRoot\Logs\SetupComplete-WindowsUpdates.log"
    Write-Output "Driver update result: Provider=$($driverResult.Provider), Success=$($driverResult.Success), Message=$($driverResult.Message)"
}
else {
    Write-Output "Invoke-TCGDriverUpdate not available — skipping vendor driver update"
}
Write-Output "Completed Section [Invoke-TCGDriverUpdate] | Time: $($(Get-Date).ToString("hh:mm:ss"))"
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