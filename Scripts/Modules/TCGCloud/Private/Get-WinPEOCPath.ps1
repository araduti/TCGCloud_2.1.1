function Get-WinPEOCPath {
    <#
    .SYNOPSIS
        Returns the path to WinPE optional components (OCs) from Windows ADK.
    .DESCRIPTION
        Internal helper that locates the WinPE optional component cabinet files
        needed for WiFi, .NET, and other WinPE features. Checks the registry
        for ADK install location, then validates the OC directory exists.
    .PARAMETER ADKPath
        Override for ADK root path. Auto-detected from registry when omitted.
    .PARAMETER Architecture
        Target architecture. Defaults to 'amd64'.
    .OUTPUTS
        [string] Path to the optional components directory, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ADKPath,

        [Parameter()]
        [string]$Architecture = 'amd64'
    )

    if (-not $ADKPath) {
        try {
            $regKey  = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
            $ADKPath = (Get-ItemProperty $regKey -ErrorAction Stop).KitsRoot10
        }
        catch {
            Write-TCGStatus 'Windows ADK not found in registry.' -Type Error
            return $null
        }
    }

    $ocPath = Join-Path $ADKPath "Assessment and Deployment Kit\Windows Preinstallation Environment\$Architecture\WinPE_OCs"
    if (-not (Test-Path $ocPath)) {
        Write-TCGStatus "WinPE optional components not found at: $ocPath" -Type Error
        return $null
    }

    return $ocPath
}
