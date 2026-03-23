function Invoke-DismOperation {
    <#
    .SYNOPSIS
        Runs a DISM command against a mounted image.
    .DESCRIPTION
        Internal helper that executes a DISM servicing command and returns
        success/failure with output.
    .PARAMETER MountPath
        Mount directory of the offline image.
    .PARAMETER Arguments
        Additional DISM arguments (e.g. '/Add-Driver /Driver:...').
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Output [string].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $dismArgs = @("/Image:`"$MountPath`"") + $Arguments
    Write-TCGStatus "Running DISM: $($dismArgs -join ' ')" -Type Info

    $output = & dism @dismArgs 2>&1 | Out-String
    $success = $LASTEXITCODE -eq 0

    if (-not $success) {
        Write-TCGStatus "DISM operation failed (exit code $LASTEXITCODE)" -Type Error
    }

    return [PSCustomObject]@{
        Success = $success
        Output  = $output
    }
}
