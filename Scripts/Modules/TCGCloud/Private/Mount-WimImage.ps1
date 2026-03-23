function Mount-WimImage {
    <#
    .SYNOPSIS
        Mounts a WIM image to a directory using DISM.
    .DESCRIPTION
        Internal helper that wraps DISM mount/unmount operations with proper
        error handling and cleanup.
    .PARAMETER WimPath
        Path to the .wim file.
    .PARAMETER MountPath
        Directory to mount the image to. Created if it does not exist.
    .PARAMETER Index
        Image index inside the WIM. Defaults to 1.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WimPath,

        [Parameter(Mandatory)]
        [string]$MountPath,

        [Parameter()]
        [int]$Index = 1
    )

    if (-not (Test-Path $WimPath)) {
        Write-TCGStatus "WIM file not found: $WimPath" -Type Error
        return $false
    }

    if (-not (Test-Path $MountPath)) {
        New-Item -Path $MountPath -ItemType Directory -Force | Out-Null
    }

    Write-TCGStatus "Mounting WIM index $Index from: $WimPath" -Type Info
    $result = & dism /Mount-Wim /WimFile:"$WimPath" /Index:$Index /MountDir:"$MountPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-TCGStatus "DISM mount failed (exit code $LASTEXITCODE): $result" -Type Error
        return $false
    }

    Write-TCGStatus "WIM mounted to: $MountPath" -Type Success
    return $true
}
