#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Builds WinPE boot media with embedded TCGCloud scripts for deployment.
.DESCRIPTION
    Creates a customized WinPE boot.wim from the Windows ADK with:
    - WiFi and networking support
    - PowerShell support
    - Custom wallpaper and branding
    - Embedded TCGCloud deployment scripts
    - Optional driver injection

    Outputs boot.wim, boot.sdi, and a scripts.zip package suitable for
    uploading to a GitHub Release. Optionally creates a bootable ISO.

    This script must be run on a machine with Windows ADK and the WinPE
    add-on installed.
.PARAMETER OutputPath
    Directory for output files. Default: .\Output
.PARAMETER EmbedScripts
    Embed TCGCloud scripts directly into boot.wim so they are available
    immediately when WinPE boots (no network download needed).
    Default: $true
.PARAMETER CreateISO
    Also create a bootable ISO file.
.PARAMETER DriverPaths
    Additional driver directories to inject into the WinPE image.
.PARAMETER Wallpaper
    Custom wallpaper to set in the WinPE environment.
    Default: Scripts\Custom\wallpaper.jpg
.PARAMETER SkipCleanup
    Keep temporary mount directories for debugging.
.EXAMPLE
    .\Build-BootMedia.ps1
    Builds boot.wim with embedded scripts in the .\Output directory.
.EXAMPLE
    .\Build-BootMedia.ps1 -CreateISO -OutputPath D:\Release
    Builds boot.wim and creates a bootable ISO in D:\Release.
.EXAMPLE
    .\Build-BootMedia.ps1 -DriverPaths "C:\Drivers\WiFi","C:\Drivers\Storage"
    Builds boot.wim with additional drivers injected.
.NOTES
    Version: 1.0
    Requires: Windows ADK with WinPE add-on
    Created by: TCG
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $PSScriptRoot "Output"),

    [Parameter(Mandatory = $false)]
    [bool]$EmbedScripts = $true,

    [Parameter(Mandatory = $false)]
    [switch]$CreateISO,

    [Parameter(Mandatory = $false)]
    [string[]]$DriverPaths,

    [Parameter(Mandatory = $false)]
    [string]$Wallpaper,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

#region Utility Functions
function Write-Status {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $icon = switch ($Type) {
        'Info'    { '[*]' }
        'Success' { '[+]' }
        'Warning' { '[!]' }
        'Error'   { '[x]' }
    }
    $color = switch ($Type) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    Write-Host "$icon $Message" -ForegroundColor $color
}

function Write-TaskHeader {
    param ([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    Write-Host ("=" * ($Title.Length + 8)) -ForegroundColor DarkGray
}
#endregion

#region ADK Detection
function Get-ADKPaths {
    <#
    .SYNOPSIS
        Detects Windows ADK and WinPE installation paths.
    #>

    $adkRoot = $null

    # Check registry for ADK installation
    $regPaths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots",
        "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots"
    )

    foreach ($regPath in $regPaths) {
        try {
            $kitsRoot = (Get-ItemProperty -Path $regPath -ErrorAction Stop).KitsRoot10
            if ($kitsRoot -and (Test-Path $kitsRoot)) {
                $adkRoot = $kitsRoot
                break
            }
        }
        catch { }
    }

    if (-not $adkRoot) {
        # Fallback to known paths
        $knownPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10",
            "${env:ProgramFiles}\Windows Kits\10"
        )
        foreach ($path in $knownPaths) {
            if (Test-Path $path) {
                $adkRoot = $path
                break
            }
        }
    }

    if (-not $adkRoot) {
        return $null
    }

    $deployToolsPath = Join-Path $adkRoot "Assessment and Deployment Kit\Deployment Tools"
    $winpePath = Join-Path $adkRoot "Assessment and Deployment Kit\Windows Preinstallation Environment"

    return @{
        Root         = $adkRoot
        DeployTools  = $deployToolsPath
        WinPE        = $winpePath
        CopypePath   = Join-Path $deployToolsPath "amd64\copype.cmd" -ErrorAction SilentlyContinue
        DismPath     = Join-Path $deployToolsPath "amd64\DISM\dism.exe"
        OscdimgPath  = Join-Path $deployToolsPath "amd64\Oscdimg\oscdimg.exe"
        WinPEOCs     = Join-Path $winpePath "amd64\WinPE_OCs"
        BootSdi      = Join-Path $winpePath "amd64\Media\Boot\boot.sdi"
        EtfsBoot     = Join-Path $deployToolsPath "amd64\Oscdimg\etfsboot.com"
        EfiSys       = Join-Path $deployToolsPath "amd64\Oscdimg\efisys_noprompt.bin"
    }
}
#endregion

#region WIM Operations
function New-BaseWinPE {
    <#
    .SYNOPSIS
        Creates a base WinPE directory using copype.cmd from ADK.
    #>
    param (
        [hashtable]$ADK,
        [string]$DestinationPath
    )

    $copype = Join-Path $ADK.DeployTools "amd64\copype.cmd"

    if (-not (Test-Path $copype)) {
        # Manual copype equivalent
        Write-Status "copype.cmd not found, creating WinPE manually..." -Type Warning

        $winpeMedia = Join-Path $ADK.WinPE "amd64\Media"
        $winpeBoot = Join-Path $ADK.WinPE "amd64\en-us\winpe.wim"

        if (-not (Test-Path $winpeBoot)) {
            throw "WinPE add-on not found. Install the Windows PE add-on for the ADK."
        }

        New-Item -Path "$DestinationPath\media\sources" -ItemType Directory -Force | Out-Null
        New-Item -Path "$DestinationPath\mount" -ItemType Directory -Force | Out-Null

        Copy-Item "$winpeMedia\*" "$DestinationPath\media\" -Recurse -Force
        Copy-Item $winpeBoot "$DestinationPath\media\sources\boot.wim" -Force

        return $true
    }

    # Set up ADK environment
    $env:WinPERoot = $ADK.WinPE
    $env:OSCDImgRoot = Split-Path $ADK.OscdimgPath

    Write-Status "Running copype.cmd amd64..." -Type Info
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$copype`" amd64 `"$DestinationPath`"" `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "copype-stdout.log") `
        -RedirectStandardError (Join-Path $env:TEMP "copype-stderr.log")

    if ($process.ExitCode -ne 0) {
        $stderr = Get-Content (Join-Path $env:TEMP "copype-stderr.log") -Raw -ErrorAction SilentlyContinue
        throw "copype.cmd failed with exit code $($process.ExitCode): $stderr"
    }

    return $true
}

function Edit-WinPEImage {
    <#
    .SYNOPSIS
        Mounts a WinPE boot.wim and customizes it with drivers, scripts,
        packages, and branding.
    #>
    param (
        [string]$WimPath,
        [string]$MountPath,
        [hashtable]$ADK,
        [string[]]$Drivers,
        [string]$WallpaperFile,
        [string]$ScriptsPath,
        [bool]$AddWiFi = $true,
        [bool]$Embed = $true
    )

    Write-TaskHeader "Customizing WinPE Image"

    # Mount the WIM
    Write-Status "Mounting boot.wim..." -Type Info
    if (-not (Test-Path $MountPath)) {
        New-Item $MountPath -ItemType Directory -Force | Out-Null
    }
    dism /Mount-Wim /WimFile:"$WimPath" /Index:1 /MountDir:"$MountPath" | Out-Null
    Write-Status "Image mounted at: $MountPath" -Type Success

    try {
        # Add PowerShell support packages
        $ocsPath = $ADK.WinPEOCs
        if (Test-Path $ocsPath) {
            Write-Status "Adding PowerShell and scripting support..." -Type Info

            $packages = @(
                "WinPE-WMI.cab",
                "en-us\WinPE-WMI_en-us.cab",
                "WinPE-NetFx.cab",
                "en-us\WinPE-NetFx_en-us.cab",
                "WinPE-Scripting.cab",
                "en-us\WinPE-Scripting_en-us.cab",
                "WinPE-PowerShell.cab",
                "en-us\WinPE-PowerShell_en-us.cab",
                "WinPE-DismCmdlets.cab",
                "en-us\WinPE-DismCmdlets_en-us.cab",
                "WinPE-SecureBootCmdlets.cab",
                "WinPE-StorageWMI.cab",
                "en-us\WinPE-StorageWMI_en-us.cab"
            )

            foreach ($pkg in $packages) {
                $pkgPath = Join-Path $ocsPath $pkg
                if (Test-Path $pkgPath) {
                    dism /Image:"$MountPath" /Add-Package /PackagePath:"$pkgPath" 2>$null | Out-Null
                }
            }
            Write-Status "PowerShell packages added" -Type Success
        }

        # Add WiFi support packages
        if ($AddWiFi -and (Test-Path $ocsPath)) {
            Write-Status "Adding WiFi and networking support..." -Type Info

            $wifiPackages = @(
                "WinPE-Dot3Svc.cab",
                "en-us\WinPE-Dot3Svc_en-us.cab"
            )

            foreach ($pkg in $wifiPackages) {
                $pkgPath = Join-Path $ocsPath $pkg
                if (Test-Path $pkgPath) {
                    dism /Image:"$MountPath" /Add-Package /PackagePath:"$pkgPath" 2>$null | Out-Null
                }
            }
            Write-Status "WiFi packages added" -Type Success
        }

        # Inject drivers
        if ($Drivers) {
            Write-Status "Injecting drivers..." -Type Info
            foreach ($driverPath in $Drivers) {
                if (Test-Path $driverPath) {
                    dism /Image:"$MountPath" /Add-Driver /Driver:"$driverPath" /Recurse /ForceUnsigned 2>$null | Out-Null
                    Write-Status "  Added drivers from: $driverPath" -Type Success
                }
                else {
                    Write-Status "  Driver path not found: $driverPath" -Type Warning
                }
            }
        }

        # Set wallpaper
        if ($WallpaperFile -and (Test-Path $WallpaperFile)) {
            Write-Status "Setting custom wallpaper..." -Type Info
            $winpeWallpaper = Join-Path $MountPath "Windows\System32\winpe.jpg"
            Copy-Item $WallpaperFile $winpeWallpaper -Force
            Write-Status "Wallpaper set" -Type Success
        }

        # Embed TCGCloud scripts into the WIM
        if ($Embed -and $ScriptsPath -and (Test-Path $ScriptsPath)) {
            Write-Status "Embedding TCGCloud scripts into WinPE image..." -Type Info

            $destScripts = Join-Path $MountPath "OSDCloud\Config\Scripts"
            New-Item -Path $destScripts -ItemType Directory -Force | Out-Null

            Copy-Item "$ScriptsPath\*" $destScripts -Recurse -Force

            # Also create the logs directory
            New-Item -Path (Join-Path $MountPath "OSDCloud\Logs") -ItemType Directory -Force | Out-Null

            Write-Status "Scripts embedded at: X:\OSDCloud\Config\Scripts\" -Type Success
        }

        # Embed deploy-config.json for network download fallback
        $configFile = Join-Path $PSScriptRoot "deploy-config.json"
        if (Test-Path $configFile) {
            $destConfig = Join-Path $MountPath "OSDCloud\Config"
            New-Item -Path $destConfig -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            Copy-Item $configFile (Join-Path $destConfig "deploy-config.json") -Force
            Write-Status "Deploy configuration embedded" -Type Success
        }

        # Create custom startnet.cmd
        Write-Status "Configuring WinPE startup (startnet.cmd)..." -Type Info

        $startnetPath = Join-Path $MountPath "Windows\System32\startnet.cmd"
        $startnetContent = @"
@echo off
wpeinit
echo.
echo ============================================
echo    TCGCloud WinPE Deployment Environment
echo ============================================
echo.

REM Launch TCGCloud deployment
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\OSDCloud\Config\Scripts\init.ps1

REM If init.ps1 doesn't exist, try the network bootstrap
if not exist X:\OSDCloud\Config\Scripts\init.ps1 (
    echo Scripts not found locally, attempting network bootstrap...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "& { Start-Sleep -Seconds 5; wpeinit; Start-Sleep -Seconds 10; " ^
        "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/$($config.github.owner)/$($config.github.repo)/main/Scripts/StartNet/_init.ps1' " ^
        "-OutFile 'X:\bootstrap.ps1' -UseBasicParsing; & X:\bootstrap.ps1 }"
)
"@
        Set-Content -Path $startnetPath -Value $startnetContent -Force -Encoding ASCII
        Write-Status "startnet.cmd configured" -Type Success
    }
    catch {
        Write-Status "Error during customization: $_" -Type Error
        Write-Status "Discarding changes and unmounting..." -Type Warning
        dism /Unmount-Wim /MountDir:"$MountPath" /Discard | Out-Null
        throw
    }

    # Unmount and commit
    Write-Status "Committing changes and unmounting WIM..." -Type Info
    dism /Unmount-Wim /MountDir:"$MountPath" /Commit | Out-Null
    Write-Status "WinPE image customized successfully" -Type Success
}
#endregion

#region Main Execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   TCGCloud Boot Media Builder v2.1.1   " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Load config
$configPath = Join-Path $PSScriptRoot "deploy-config.json"
$config = $null
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
}
else {
    $config = @{
        github = @{
            owner = "araduti"
            repo  = "TCGCloud_2.1.1"
        }
    }
}

# Step 1: Detect ADK
Write-TaskHeader "Detecting Windows ADK"

$adk = Get-ADKPaths

if (-not $adk) {
    Write-Status "Windows ADK not found!" -Type Error
    Write-Status "" -Type Info
    Write-Status "Install Windows ADK from:" -Type Info
    Write-Status "  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -Type Info
    Write-Status "" -Type Info
    Write-Status "Also install the WinPE add-on:" -Type Info
    Write-Status "  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install#install-winpe" -Type Info
    throw "Windows ADK is required to build boot media."
}

Write-Status "ADK found at: $($adk.Root)" -Type Success

# Check for WinPE add-on
$winpeWim = Join-Path $adk.WinPE "amd64\en-us\winpe.wim"
if (-not (Test-Path $winpeWim)) {
    Write-Status "WinPE add-on not found!" -Type Error
    Write-Status "Install the Windows PE add-on for the ADK." -Type Info
    throw "WinPE add-on is required."
}
Write-Status "WinPE add-on found" -Type Success

# Step 2: Create output directory
New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

$tempDir = Join-Path $env:TEMP "TCGCloud-Build-$(Get-Random)"
$peDir = Join-Path $tempDir "WinPE"
$mountDir = Join-Path $tempDir "Mount"

New-Item $tempDir -ItemType Directory -Force | Out-Null

try {
    # Step 3: Create base WinPE
    Write-TaskHeader "Creating Base WinPE"
    New-BaseWinPE -ADK $adk -DestinationPath $peDir
    Write-Status "Base WinPE created" -Type Success

    $bootWim = Join-Path $peDir "media\sources\boot.wim"
    if (-not (Test-Path $bootWim)) {
        throw "boot.wim not found after copype. Expected at: $bootWim"
    }

    # Step 4: Customize WinPE
    $scriptsPath = Join-Path $PSScriptRoot "Scripts"
    if (-not (Test-Path $scriptsPath)) {
        Write-Status "Scripts directory not found at $scriptsPath" -Type Warning
        $EmbedScripts = $false
    }

    # Resolve wallpaper
    if (-not $Wallpaper) {
        $Wallpaper = Join-Path $PSScriptRoot "Scripts\Custom\wallpaper.jpg"
    }

    Edit-WinPEImage -WimPath $bootWim `
        -MountPath $mountDir `
        -ADK $adk `
        -Drivers $DriverPaths `
        -WallpaperFile $Wallpaper `
        -ScriptsPath $scriptsPath `
        -AddWiFi $true `
        -Embed $EmbedScripts

    # Step 5: Copy output files
    Write-TaskHeader "Packaging Output"

    # Copy boot.wim
    $outputWim = Join-Path $OutputPath "boot.wim"
    Copy-Item $bootWim $outputWim -Force
    $wimSize = [math]::Round((Get-Item $outputWim).Length / 1MB, 1)
    Write-Status "boot.wim ($wimSize MB) → $outputWim" -Type Success

    # Copy boot.sdi
    $outputSdi = Join-Path $OutputPath "boot.sdi"
    if (Test-Path $adk.BootSdi) {
        Copy-Item $adk.BootSdi $outputSdi -Force
        Write-Status "boot.sdi → $outputSdi" -Type Success
    }
    else {
        Write-Status "boot.sdi not found in ADK. RAM-disk boot will need it from another source." -Type Warning
    }

    # Package scripts as zip
    if (Test-Path $scriptsPath) {
        $outputZip = Join-Path $OutputPath "tcgcloud-scripts.zip"
        if (Test-Path $outputZip) { Remove-Item $outputZip -Force }

        # Create a temp directory with the expected structure
        $zipStaging = Join-Path $tempDir "zip-staging"
        New-Item -Path (Join-Path $zipStaging "Scripts") -ItemType Directory -Force | Out-Null
        Copy-Item "$scriptsPath\*" (Join-Path $zipStaging "Scripts") -Recurse -Force

        # Also include deploy-config.json
        $configFile = Join-Path $PSScriptRoot "deploy-config.json"
        if (Test-Path $configFile) {
            Copy-Item $configFile $zipStaging -Force
        }

        Compress-Archive -Path "$zipStaging\*" -DestinationPath $outputZip -Force
        $zipSize = [math]::Round((Get-Item $outputZip).Length / 1MB, 1)
        Write-Status "tcgcloud-scripts.zip ($zipSize MB) → $outputZip" -Type Success

        Remove-Item $zipStaging -Recurse -Force
    }

    # Step 6: Create ISO (optional)
    if ($CreateISO) {
        Write-TaskHeader "Creating Bootable ISO"

        $isoPath = Join-Path $OutputPath "TCGCloud-WinPE.iso"
        $isoMedia = Join-Path $peDir "media"

        if ((Test-Path $adk.OscdimgPath) -and (Test-Path $adk.EtfsBoot)) {
            $oscdimg = $adk.OscdimgPath
            $etfs = $adk.EtfsBoot
            $efisys = $adk.EfiSys

            if (Test-Path $efisys) {
                # UEFI + BIOS bootable
                & $oscdimg -bootdata:"2#p0,e,b`"$etfs`"#pEF,e,b`"$efisys`"" -u1 -udfver102 "$isoMedia" "$isoPath"
            }
            else {
                # BIOS only
                & $oscdimg -n "-b$etfs" "$isoMedia" "$isoPath"
            }

            if (Test-Path $isoPath) {
                $isoSize = [math]::Round((Get-Item $isoPath).Length / 1MB, 1)
                Write-Status "TCGCloud-WinPE.iso ($isoSize MB) → $isoPath" -Type Success
            }
            else {
                Write-Status "ISO creation failed" -Type Error
            }
        }
        else {
            Write-Status "oscdimg.exe not found in ADK, skipping ISO creation" -Type Warning
        }
    }

    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   Build Complete!                       " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Status "Output directory: $OutputPath" -Type Success
    Write-Host ""

    Get-ChildItem $OutputPath | ForEach-Object {
        $sizeMB = [math]::Round($_.Length / 1MB, 1)
        Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Upload these files to a GitHub Release in your repository" -ForegroundColor White
    Write-Host "  2. Run Start-NetworkDeploy.ps1 on target machines to deploy" -ForegroundColor White
    Write-Host "  3. Or use the ISO directly with Hyper-V or a physical disc" -ForegroundColor White
    Write-Host ""
}
finally {
    # Cleanup
    if (-not $SkipCleanup) {
        # Make sure nothing is still mounted
        dism /Cleanup-Wim 2>$null | Out-Null
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Status "Temporary files preserved at: $tempDir" -Type Info
    }
}
#endregion
