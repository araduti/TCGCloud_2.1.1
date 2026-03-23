function New-TCGWorkspace {
    <#
    .SYNOPSIS
        Creates a TCGCloud deployment workspace directory structure.
    .DESCRIPTION
        Replaces New-OSDCloudWorkspace. Builds the required directory tree
        and optionally copies boot files from an existing TCGCloud template.
    .PARAMETER WorkspacePath
        Root path for the workspace. Required.
    .PARAMETER TemplateName
        Name of the template to copy from. Defaults to 'TCGCloud'.
    .OUTPUTS
        [string] Workspace path on success, $null on failure.
    .EXAMPLE
        $ws = New-TCGWorkspace -WorkspacePath 'D:\OSDCloud-Build'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [Parameter()]
        [string]$TemplateName = 'TCGCloud'
    )

    # --- Create directory structure ----------------------------------------------
    $dirs = @(
        'Media'
        'Media\OSDCloud'
        'Media\OSDCloud\OS'
        'Media\sources'
        'Media\boot'
        'Media\EFI\Boot'
        'Media\OSDCloud\Config\Scripts'
    )

    try {
        foreach ($dir in $dirs) {
            New-Item -Path (Join-Path $WorkspacePath $dir) -ItemType Directory -Force | Out-Null
        }
        Write-TCGStatus "Workspace directories created: $WorkspacePath" -Type Success
    }
    catch {
        Write-TCGStatus "Failed to create workspace directories: $_" -Type Error
        return $null
    }

    # --- Copy from template if available -----------------------------------------
    $templatePath = Get-TCGTemplate -Name $TemplateName
    if ($templatePath) {
        $sourceMedia = Join-Path $templatePath 'Media'
        $destMedia   = Join-Path $WorkspacePath  'Media'

        Write-TCGStatus "Copying template files from: $templatePath" -Type Info

        # Use robocopy when available (Windows), fall back to Copy-Item
        $robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
        if ($robocopy) {
            $roboArgs = @($sourceMedia, $destMedia, '/E', '/NFL', '/NDL', '/NJH', '/NJS')
            & robocopy @roboArgs | Out-Null
        }
        else {
            Copy-Item -Path "$sourceMedia\*" -Destination $destMedia -Recurse -Force
        }

        Write-TCGStatus 'Template files copied to workspace.' -Type Success
    }
    else {
        Write-TCGStatus "No template found for '$TemplateName'. Workspace created without boot files." -Type Warning
    }

    return $WorkspacePath
}
