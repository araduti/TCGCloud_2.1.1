function New-TCGTemplate {
    <#
    .SYNOPSIS
        Creates a new TCGCloud WinPE template from Windows ADK.
    .DESCRIPTION
        Replaces New-OSDCloudTemplate. Detects the Windows ADK installation,
        runs copype.cmd to create a base WinPE image, and copies boot files
        into the template directory under ProgramData\TCGCloud\Templates.
    .PARAMETER Name
        Template name. Defaults to 'TCGCloud'.
    .PARAMETER ADKPath
        Override for ADK root path. Auto-detected from registry when omitted.
    .OUTPUTS
        [string] Template directory path on success, $null on failure.
    .EXAMPLE
        $path = New-TCGTemplate
        if ($path) { Write-Host "Template created at: $path" }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name = 'TCGCloud',

        [Parameter()]
        [string]$ADKPath
    )

    # --- Detect ADK installation -------------------------------------------------
    if (-not $ADKPath) {
        try {
            $regKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
            $adkRoot = (Get-ItemProperty $regKey -ErrorAction Stop).KitsRoot10
        }
        catch {
            Write-TCGStatus 'Windows ADK not found in registry. Install ADK or provide -ADKPath.' -Type Error
            return $null
        }
    }
    else {
        $adkRoot = $ADKPath
    }

    $copype = Join-Path $adkRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment\copype.cmd'
    if (-not (Test-Path $copype)) {
        Write-TCGStatus "copype.cmd not found at: $copype" -Type Error
        return $null
    }

    # --- Create base WinPE via copype.cmd ----------------------------------------
    $tempPE = Join-Path $env:TEMP "TCGCloud-PE-$(Get-Random)"
    Write-TCGStatus "Creating base WinPE in: $tempPE" -Type Info

    try {
        $copyResult = & cmd /c "`"$copype`" amd64 `"$tempPE`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-TCGStatus "copype.cmd failed (exit code $LASTEXITCODE): $copyResult" -Type Error
            return $null
        }
    }
    catch {
        Write-TCGStatus "Failed to run copype.cmd: $_" -Type Error
        return $null
    }

    # --- Build template directory (Windows-only; ProgramData is always set) -----
    $programData  = $env:ProgramData
    if (-not $programData) {
        Write-TCGStatus 'ProgramData environment variable not set. This function requires Windows.' -Type Error
        return $null
    }
    $templatePath = Join-Path $programData "TCGCloud\Templates\$Name"

    try {
        New-Item -Path (Join-Path $templatePath 'Media\sources')  -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $templatePath 'Media\EFI\Boot') -ItemType Directory -Force | Out-Null

        Copy-Item -Path "$tempPE\media\*" -Destination (Join-Path $templatePath 'Media') -Recurse -Force
        Copy-Item -Path "$tempPE\fwfiles\*" -Destination (Join-Path $templatePath 'Media\EFI\Boot') -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-TCGStatus "Failed to populate template: $_" -Type Error
        return $null
    }
    finally {
        if (Test-Path $tempPE) {
            Remove-Item $tempPE -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-TCGStatus "Template created: $templatePath" -Type Success
    return $templatePath
}
