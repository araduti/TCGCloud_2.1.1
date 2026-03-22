function Get-TCGTemplate {
    <#
    .SYNOPSIS
        Returns the path to an existing TCGCloud WinPE template, or $null if none exists.
    .DESCRIPTION
        Replaces Get-OSDCloudTemplate. Looks for a boot.wim inside the named template
        directory under ProgramData\TCGCloud\Templates.
    .PARAMETER Name
        Template name. Defaults to 'TCGCloud'.
    .OUTPUTS
        [string] Template directory path, or $null.
    .EXAMPLE
        $path = Get-TCGTemplate
        if ($path) { Write-Host "Template at: $path" }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name = 'TCGCloud'
    )

    $programData   = $env:ProgramData
    if (-not $programData) { $programData = '/tmp' }
    $templateRoot  = Join-Path $programData 'TCGCloud\Templates'
    $templatePath  = Join-Path $templateRoot $Name
    $bootWim       = Join-Path $templatePath 'Media\sources\boot.wim'

    if (Test-Path $bootWim) {
        Write-TCGStatus "Template found: $templatePath" -Type Success
        return $templatePath
    }

    Write-TCGStatus "No template found at: $templatePath" -Type Warning
    return $null
}
