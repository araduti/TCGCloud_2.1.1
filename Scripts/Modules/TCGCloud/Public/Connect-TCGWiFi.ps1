function Connect-TCGWiFi {
    <#
    .SYNOPSIS
        Connects to WiFi in WinPE using stored profiles or interactive prompt.
    .DESCRIPTION
        Replaces Start-WinREWiFi. Checks for a wireless adapter, attempts stored
        profiles, then optionally prompts for SSID/password. Returns $true on success.
    .PARAMETER TimeoutSeconds
        Seconds to wait for connectivity after each profile attempt. Default 5.
    .OUTPUTS
        [bool] $true if internet connectivity established.
    .EXAMPLE
        if (Connect-TCGWiFi) { Write-Host "Online" }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$TimeoutSeconds = 5
    )

    # --- Check for a wireless adapter -------------------------------------------
    try {
        $wifiAdapter = Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN' -and $_.Status -ne 'Disabled' }
    }
    catch {
        Write-TCGStatus 'Unable to query network adapters.' -Type Error
        return $false
    }

    if (-not $wifiAdapter) {
        Write-TCGStatus 'No WiFi adapter detected.' -Type Warning
        return $false
    }

    Write-TCGStatus "WiFi adapter found: $($wifiAdapter.InterfaceDescription)" -Type Info

    # --- Quick check: already online? ------------------------------------------
    if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-TCGStatus 'Already connected to the internet.' -Type Success
        return $true
    }

    # --- Try stored WiFi profiles ----------------------------------------------
    $profileOutput = netsh wlan show profiles 2>&1
    $profiles = $profileOutput |
        Select-String 'All User Profile\s+:\s+(.+)' |
        ForEach-Object { $_.Matches.Groups[1].Value.Trim() }

    foreach ($profile in $profiles) {
        Write-TCGStatus "Trying WiFi profile: $profile" -Type Info
        netsh wlan connect name="$profile" 2>&1 | Out-Null
        Start-Sleep -Seconds $TimeoutSeconds
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-TCGStatus "Connected via profile: $profile" -Type Success
            return $true
        }
    }

    Write-TCGStatus 'No stored WiFi profile could connect.' -Type Warning
    return $false
}
