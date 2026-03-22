# Utility functions for OSDCloud deployment

function Get-GraphToken {
    param(
        [string]$TenantId = $env:TCG_TENANT_ID,
        [string]$ClientId = $env:TCG_CLIENT_ID,
        [string]$ClientSecret = $env:TCG_CLIENT_SECRET
    )
    
    # Validate required credentials
    if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
        Write-Error "Graph API credentials not configured. Set TCG_TENANT_ID, TCG_CLIENT_ID, and TCG_CLIENT_SECRET environment variables."
        return $null
    }

    try {
        Write-Host "Attempting to get Graph API token..."
        [System.Net.ServicePointManager]::DnsRefreshTimeout = 0
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::UseNagleAlgorithm = $true
        
        $Addresses = [System.Net.Dns]::GetHostAddresses("login.microsoftonline.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1

        if (-not $Addresses) {
            Write-Error "Could not resolve login.microsoftonline.com"
            return $null
        }

        $LoginIP = $Addresses.IPAddressToString
        Write-Host "Using IP: $LoginIP"

        $TokenUrl = "https://$LoginIP/$TenantId/oauth2/v2.0/token"
        $TokenBody = @{
            Grant_Type    = "client_credentials"
            Scope         = "https://graph.microsoft.com/.default"
            Client_Id     = $ClientId
            Client_Secret = $ClientSecret
        }

        $TokenResponse = Invoke-RestMethod -Uri $TokenUrl `
            -Method POST -Body $TokenBody `
            -Headers @{ 'Host' = 'login.microsoftonline.com' } `
            -ErrorAction Stop
        
        Write-Host "Successfully obtained Graph API token"
        return $TokenResponse.access_token
    }
    catch {
        Write-Error "Failed to get Graph API token: $_"
        return $null
    }
}

function Test-AutopilotStatus {
    param(
        [string]$SerialNumber,
        [string]$Token
    )
    
    try {
        $GraphAddresses = [System.Net.Dns]::GetHostAddresses("graph.microsoft.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1

        if (-not $GraphAddresses) {
            Write-Error "Could not resolve graph.microsoft.com"
            return @{
                Success      = $false
                IsRegistered = $false
                Message      = "Could not connect to Graph API"
            }
        }

        $GraphIP = $GraphAddresses.IPAddressToString
        Write-Host "Using Graph IP: $GraphIP"
        
        $Uri = "https://$GraphIP/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        Write-Host "Full URI: $Uri"
        
        $Response = Invoke-RestMethod `
            -Uri $Uri `
            -Headers @{
            'Authorization' = "Bearer $Token"
            'Content-Type'  = 'application/json'
            'Host'          = 'graph.microsoft.com'
        } `
            -Method GET

        $Device = $Response.value | Where-Object { $_.serialNumber -eq $SerialNumber }
        
        if ($Device) {
            Write-Host "Found device"
            $Device | ConvertTo-Json -Depth 10 | Write-Host

            $ProfileStatus = if ($Device.deploymentProfileAssignmentDetailsSummary) {
                $Device.deploymentProfileAssignmentDetailsSummary
            }
            elseif ($Device.enrollmentState -and $Device.enrollmentState -ne "notContacted") {
                $Device.enrollmentState
            }
            elseif ($Device.deploymentProfileAssignedDateTime) {
                "Profile assigned on $($Device.deploymentProfileAssignedDateTime)"
            }
            else {
                "No profile assigned"
            }

            return @{
                Success      = $true
                IsRegistered = $true
                Message      = "Device is registered in Autopilot"
                GroupTag     = $Device.groupTag
                Profile      = $ProfileStatus
            }
        }
        else {
            return @{
                Success      = $true
                IsRegistered = $false
                Message      = "Device not found in Autopilot"
            }
        }
    }
    catch {
        Write-Host "Error checking Autopilot status: $_"
        return @{
            Success      = $false
            IsRegistered = $false
            Message      = "Failed to check Autopilot status: $($_.Exception.Message)"
        }
    }
}

function Test-UserExists {
    param(
        [string]$UserEmail,
        [string]$Token
    )
    
    try {
        $GraphAddresses = [System.Net.Dns]::GetHostAddresses("graph.microsoft.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1

        if (-not $GraphAddresses) {
            Write-Error "Could not resolve graph.microsoft.com"
            return @{
                Success           = $false
                Exists            = $false
                UserPrincipalName = $null
                DisplayName       = $null
            }
        }

        $GraphIP = $GraphAddresses.IPAddressToString
        Write-Host "Using Graph IP: $GraphIP"
        
        $Filter = "userPrincipalName eq '$UserEmail'"
        $EncodedFilter = [System.Web.HttpUtility]::UrlEncode($Filter)
        
        $Response = Invoke-RestMethod `
            -Uri "https://$GraphIP/v1.0/users?`$filter=$EncodedFilter" `
            -Headers @{
            'Authorization' = "Bearer $Token"
            'Content-Type'  = 'application/json'
            'Host'          = 'graph.microsoft.com'
        } `
            -Method GET

        if ($Response.value.Count -gt 0) {
            return @{
                Success           = $true
                Exists            = $true
                UserPrincipalName = $Response.value[0].userPrincipalName
                DisplayName       = $Response.value[0].displayName
            }
        }
        else {
            return @{
                Success           = $true
                Exists            = $false
                UserPrincipalName = $null
                DisplayName       = $null
            }
        }
    }
    catch {
        Write-Host "Error checking user: $($_.Exception.Message)"
        return @{
            Success           = $false
            Exists            = $false
            UserPrincipalName = $null
            DisplayName       = $null
        }
    }
} 