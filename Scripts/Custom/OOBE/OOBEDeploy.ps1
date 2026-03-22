# OOBEDeploy.ps1 - Runs during OOBE
Start-Transcript -Path "C:\Windows\Logs\OOBE-WindowsUpdate.log" -Force

# Add TLS 1.2 support to fix connection issues
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Step-oobeUpdateDrivers {
    [CmdletBinding()]
    param ()
    if ($env:UserName -eq 'defaultuser0') {
        Write-Host -ForegroundColor Cyan 'Updating Windows Drivers'
        if (!(Get-Module PSWindowsUpdate -ListAvailable -ErrorAction Ignore)) {
            try {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module PSWindowsUpdate -Force
                Import-Module PSWindowsUpdate -Force
            }
            catch {
                Write-Warning "Unable to install PSWindowsUpdate Driver Updates: $_"
            }
        }
        if (Get-Module PSWindowsUpdate -ListAvailable -ErrorAction Ignore) {
            Start-Process PowerShell.exe -ArgumentList "-Command Install-WindowsUpdate -UpdateType Driver -AcceptAll -IgnoreReboot" -Wait
        }
    }
}

function Step-oobeUpdateWindows {
    [CmdletBinding()]
    param ()
    if ($env:UserName -eq 'defaultuser0') {
        Write-Host -ForegroundColor Cyan 'Updating Windows'
        if (!(Get-Module PSWindowsUpdate -ListAvailable)) {
            try {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module PSWindowsUpdate -Force
                Import-Module PSWindowsUpdate -Force
            }
            catch {
                Write-Warning "Unable to install PSWindowsUpdate Windows Updates: $_"
            }
        }
        if (Get-Module PSWindowsUpdate -ListAvailable -ErrorAction Ignore) {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null
            Start-Process PowerShell.exe -ArgumentList "-Command Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -NotTitle 'Preview' -NotKBArticleID 'KB890830','KB5005463','KB4481252'" -Wait
        }
    }
}

function Install-StoreApps {
    [CmdletBinding()]
    param ()
    if ($env:UserName -eq 'defaultuser0') {
        Write-Host -ForegroundColor Cyan 'Installing Store Apps using winget'
        
        # Install Azure VPN Client
        try {
            Write-Host -ForegroundColor DarkCyan 'Installing Azure VPN Client'
            Start-Process -FilePath "winget" -ArgumentList "install --id 9NP355QT2SQB --accept-source-agreements --accept-package-agreements" -Wait -NoNewWindow
            Write-Host -ForegroundColor Green 'Azure VPN Client installation completed'
        }
        catch {
            Write-Warning "Unable to install Azure VPN Client: $_"
        }
    }
}

# Wait for network connectivity
$networkReady = $false
$maxAttempts = 12  # 2 minutes total
for ($i = 0; $i -lt $maxAttempts; $i++) {
    Write-Host "Checking network connectivity ($($i+1) of $maxAttempts)"
    if (Test-Connection 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        $networkReady = $true
        Write-Host "Network connectivity established!"
        break
    }
    Write-Host "Waiting 10 seconds for network..."
    Start-Sleep -Seconds 10
}

if ($networkReady) {
    # Run updates first
    Step-oobeUpdateDrivers
    Step-oobeUpdateWindows
    
    # Then install Store apps
    Install-StoreApps
}
else {
    Write-Warning "Network connectivity could not be established. Updates and app installations will not be performed."
    
    # Create a scheduled task to try again later
    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -File '$PSCommandPath'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable
    
    Register-ScheduledTask -TaskName "RetryOOBEUpdatesAndApps" -Action $action -Trigger $trigger -Settings $settings -Force
}

Stop-Transcript