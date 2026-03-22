# TCGUtility.psm1
# Shared utility functions for TCG Cloud deployment scripts

# Import the logging module
$loggingModulePath = Join-Path $PSScriptRoot "TCGLogging.psm1"
if (Test-Path $loggingModulePath) {
    Import-Module $loggingModulePath -Force
}

# API Connection functions
function Get-GraphToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [string]$tenantId = "27288bd1-5edf-4fd9-b1c9-49e2ab191c9c",
        
        [Parameter(Mandatory = $false)]
        [string]$clientId = "fd553d63-358d-4ad1-bffc-ae93d4173d1e",
        
        [Parameter(Mandatory = $false)]
        [string]$clientSecret = "kPe8Q~3td4OfgOM6kEi70orSdpjJB60IMIi~paVD "
    )
    
    # Create a log file if one wasn't provided
    if (-not $LogFile) {
        $LogFile = "X:\OSDCloud\Logs\TCGUtility.log"
        if (-not (Test-Path "X:\OSDCloud\Logs")) {
            New-Item -Path "X:\OSDCloud\Logs" -ItemType Directory -Force | Out-Null
        }
    }
    
    try {
        # Log the attempt
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Attempting to get Graph API token..." -LogFile $LogFile
        }
        else {
            Write-Host "Attempting to get Graph API token..." -ForegroundColor Cyan
        }
        
        # Configure network settings
        [System.Net.ServicePointManager]::DnsRefreshTimeout = 0
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::UseNagleAlgorithm = $true
        
        # Get IP addresses for login.microsoftonline.com
        $addresses = [System.Net.Dns]::GetHostAddresses("login.microsoftonline.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1
        
        if (-not $addresses) {
            $errorMsg = "Could not resolve login.microsoftonline.com"
            if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
                Write-TCGError -Message $errorMsg -LogFile $LogFile
            }
            else {
                Write-Error $errorMsg
            }
            return $null
        }
        
        $loginIP = $addresses.IPAddressToString
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Using login IP: $loginIP" -LogFile $LogFile
        }
        else {
            Write-Host "Using login IP: $loginIP" -ForegroundColor Cyan
        }
        
        # Build token request
        $tokenUrl = "https://$loginIP/$tenantId/oauth2/v2.0/token"
        $tokenBody = @{
            Grant_Type    = "client_credentials"
            Scope         = "https://graph.microsoft.com/.default"
            Client_Id     = $clientId
            Client_Secret = $clientSecret
        }
        
        # Request the token
        $tokenResponse = Invoke-RestMethod -Uri $tokenUrl `
            -Method POST -Body $tokenBody `
            -Headers @{ 'Host' = 'login.microsoftonline.com' } `
            -ErrorAction Stop
        
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Successfully obtained Graph API token" -LogFile $LogFile
        }
        else {
            Write-Host "Successfully obtained Graph API token" -ForegroundColor Green
        }
        
        return $tokenResponse.access_token
    }
    catch {
        if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
            Write-TCGError -Message "Failed to get Graph API token" -LogFile $LogFile -ErrorRecord $_
        }
        else {
            Write-Error "Failed to get Graph API token: $_"
        }
        return $null
    }
}

function Test-AutopilotStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$serialNumber,
        
        [Parameter(Mandatory = $true)]
        [string]$token,
        
        [Parameter(Mandatory = $false)]
        [string]$LogFile
    )
    
    # Create a log file if one wasn't provided
    if (-not $LogFile) {
        $LogFile = "X:\OSDCloud\Logs\TCGUtility.log"
        if (-not (Test-Path "X:\OSDCloud\Logs")) {
            New-Item -Path "X:\OSDCloud\Logs" -ItemType Directory -Force | Out-Null
        }
    }
    
    try {
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Checking Autopilot status for device $serialNumber" -LogFile $LogFile
        }
        else {
            Write-Host "Checking Autopilot status for device $serialNumber" -ForegroundColor Cyan
        }
        
        # Resolve Graph API endpoint
        $graphAddresses = [System.Net.Dns]::GetHostAddresses("graph.microsoft.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1
        
        if (-not $graphAddresses) {
            $errorMsg = "Could not resolve graph.microsoft.com"
            if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
                Write-TCGError -Message $errorMsg -LogFile $LogFile
            }
            else {
                Write-Error $errorMsg
            }
            return @{ Success = $false; IsRegistered = $false; Message = "Could not connect to Graph API" }
        }
        
        $graphIP = $graphAddresses.IPAddressToString
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Using Graph IP: $graphIP" -LogFile $LogFile
        }
        else {
            Write-Host "Using Graph IP: $graphIP" -ForegroundColor Cyan
        }
        
        # Build URI for Autopilot devices
        $uri = "https://$graphIP/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        
        # Query Graph API
        $response = Invoke-RestMethod -Uri $uri `
            -Headers @{ 
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
            'Host'          = 'graph.microsoft.com'
        } `
            -Method GET
        
        # Check if device is registered
        $device = $response.value | Where-Object { $_.serialNumber -eq $serialNumber }
        
        if ($device) {
            if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
                Write-TCGInfo -Message "Device found in Autopilot" -LogFile $LogFile
                Write-TCGDebug -Message ($device | ConvertTo-Json -Depth 3) -LogFile $LogFile
            }
            else {
                Write-Host "Device found in Autopilot" -ForegroundColor Green
            }
            
            # Determine profile status
            $profileStatus = if ($device.deploymentProfileAssignmentDetailsSummary) {
                $device.deploymentProfileAssignmentDetailsSummary
            }
            elseif ($device.enrollmentState -and $device.enrollmentState -ne "notContacted") {
                $device.enrollmentState
            }
            elseif ($device.deploymentProfileAssignedDateTime) {
                "Profile assigned on $($device.deploymentProfileAssignedDateTime)"
            }
            else {
                "No profile assigned"
            }
            
            return @{
                Success      = $true
                IsRegistered = $true
                Message      = "Device is registered in Autopilot"
                GroupTag     = $device.groupTag
                Profile      = $profileStatus
            }
        }
        else {
            if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
                Write-TCGInfo -Message "Device not found in Autopilot" -LogFile $LogFile
            }
            else {
                Write-Host "Device not found in Autopilot" -ForegroundColor Yellow
            }
            
            return @{
                Success      = $true
                IsRegistered = $false
                Message      = "Device not found in Autopilot"
            }
        }
    }
    catch {
        if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
            Write-TCGError -Message "Error checking Autopilot status" -LogFile $LogFile -ErrorRecord $_
        }
        else {
            Write-Error "Error checking Autopilot status: $_"
        }
        
        return @{
            Success      = $false
            IsRegistered = $false
            Message      = "Failed to check Autopilot status: $($_.Exception.Message)"
        }
    }
}

function Test-UserExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$userEmail,
        
        [Parameter(Mandatory = $true)]
        [string]$token,
        
        [Parameter(Mandatory = $false)]
        [string]$LogFile
    )
    
    # Create a log file if one wasn't provided
    if (-not $LogFile) {
        $LogFile = "X:\OSDCloud\Logs\TCGUtility.log"
        if (-not (Test-Path "X:\OSDCloud\Logs")) {
            New-Item -Path "X:\OSDCloud\Logs" -ItemType Directory -Force | Out-Null
        }
    }
    
    try {
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Checking if user exists: $userEmail" -LogFile $LogFile
        }
        else {
            Write-Host "Checking if user exists: $userEmail" -ForegroundColor Cyan
        }
        
        # Resolve Graph API endpoint
        $graphAddresses = [System.Net.Dns]::GetHostAddresses("graph.microsoft.com") | 
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
        Select-Object -First 1
        
        if (-not $graphAddresses) {
            $errorMsg = "Could not resolve graph.microsoft.com"
            if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
                Write-TCGError -Message $errorMsg -LogFile $LogFile
            }
            else {
                Write-Error $errorMsg
            }
            return @{
                Success           = $false
                Exists            = $false
                UserPrincipalName = $null
                DisplayName       = $null
            }
        }
        
        $graphIP = $graphAddresses.IPAddressToString
        if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
            Write-TCGInfo -Message "Using Graph IP: $graphIP" -LogFile $LogFile
        }
        else {
            Write-Host "Using Graph IP: $graphIP" -ForegroundColor Cyan
        }
        
        # Build filter and query
        $filter = "userPrincipalName eq '$userEmail'"
        $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
        
        # Query Graph API
        $response = Invoke-RestMethod `
            -Uri "https://$graphIP/v1.0/users?`$filter=$encodedFilter" `
            -Headers @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
            'Host'          = 'graph.microsoft.com'
        } `
            -Method GET
        
        # Check if user exists
        if ($response.value.Count -gt 0) {
            if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
                Write-TCGInfo -Message "User found: $($response.value[0].displayName)" -LogFile $LogFile
            }
            else {
                Write-Host "User found: $($response.value[0].displayName)" -ForegroundColor Green
            }
            
            return @{
                Success           = $true
                Exists            = $true
                UserPrincipalName = $response.value[0].userPrincipalName
                DisplayName       = $response.value[0].displayName
            }
        }
        else {
            if (Get-Command -Name Write-TCGInfo -ErrorAction SilentlyContinue) {
                Write-TCGInfo -Message "User not found: $userEmail" -LogFile $LogFile
            }
            else {
                Write-Host "User not found: $userEmail" -ForegroundColor Yellow
            }
            
            return @{
                Success           = $true
                Exists            = $false
                UserPrincipalName = $null
                DisplayName       = $null
            }
        }
    }
    catch {
        if (Get-Command -Name Write-TCGError -ErrorAction SilentlyContinue) {
            Write-TCGError -Message "Error checking user existence" -LogFile $LogFile -ErrorRecord $_
        }
        else {
            Write-Error "Error checking user existence: $_"
        }
        
        return @{
            Success           = $false
            Exists            = $false
            UserPrincipalName = $null
            DisplayName       = $null
        }
    }
}

# Export functions for use in other scripts
Export-ModuleMember -Function Get-GraphToken, Test-AutopilotStatus, Test-UserExists 