#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Network-based TCGCloud deployment — no USB drive required.
.DESCRIPTION
    Downloads WinPE boot media from a GitHub Release and configures the local
    machine to boot into WinPE for automated Windows deployment.

    The script will:
    1. Download boot.wim, boot.sdi, and the scripts package from GitHub
    2. Stage boot files on the local disk
    3. Create a one-time WinPE RAM-disk boot entry via bcdedit
    4. Reboot into WinPE where deployment continues automatically

    After WinPE boots, the standard TCGCloud flow takes over:
    WiFi connection → Autopilot check → OS deployment → post-install.
.PARAMETER GitHubRepo
    GitHub repository in "owner/repo" format.
    Default: read from deploy-config.json
.PARAMETER ReleaseTag
    GitHub Release tag to download from. Use "latest" for the most recent.
    Default: "latest"
.PARAMETER WorkingDirectory
    Local directory for staging boot files.
    Default: C:\TCGCloud
.PARAMETER CreateISO
    Instead of configuring a RAM-disk boot, create a bootable ISO file.
    Useful for Hyper-V testing or burning to disc.
.PARAMETER SkipReboot
    Stage boot files and configure the boot entry but do not reboot.
    Useful for testing or when you want to reboot manually.
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    .\Start-NetworkDeploy.ps1
    Downloads latest release and reboots into WinPE deployment.
.EXAMPLE
    .\Start-NetworkDeploy.ps1 -ReleaseTag "v2.1.1" -SkipReboot
    Downloads a specific release and stages boot without rebooting.
.EXAMPLE
    .\Start-NetworkDeploy.ps1 -CreateISO
    Creates a bootable ISO at C:\TCGCloud\TCGCloud-WinPE.iso instead of rebooting.
.NOTES
    Version: 1.0
    Requires: Internet access to reach github.com
    Created by: TCG
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $false)]
    [string]$ReleaseTag = "latest",

    [Parameter(Mandatory = $false)]
    [string]$WorkingDirectory,

    [Parameter(Mandatory = $false)]
    [switch]$CreateISO,

    [Parameter(Mandatory = $false)]
    [switch]$SkipReboot,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#region Initialization
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

# Load configuration
$configPath = Join-Path $PSScriptRoot "deploy-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
}
else {
    $config = $null
}

# Apply defaults from config, allowing parameter overrides
if (-not $GitHubRepo) {
    if ($config) {
        $GitHubRepo = "$($config.github.owner)/$($config.github.repo)"
    }
    else {
        $GitHubRepo = "araduti/TCGCloud_2.1.1"
    }
}
if ($ReleaseTag -eq "latest" -and $config -and $config.github.releaseTag -ne "latest") {
    $ReleaseTag = $config.github.releaseTag
}
if (-not $WorkingDirectory) {
    if ($config) {
        $WorkingDirectory = $config.paths.localStaging
    }
    else {
        $WorkingDirectory = "C:\TCGCloud"
    }
}

# Ensure working directory exists
if (-not (Test-Path $WorkingDirectory)) {
    New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null
}

$logsDir = Join-Path $WorkingDirectory "Logs"
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path (Join-Path $logsDir "NetworkDeploy_$(Get-Date -Format 'yyyyMMdd-HHmmss').log") -ErrorAction SilentlyContinue
#endregion

#region GitHub Download Functions
function Get-GitHubReleaseInfo {
    <#
    .SYNOPSIS
        Gets release information from GitHub API.
    #>
    param (
        [string]$Repo,
        [string]$Tag
    )

    if ($Tag -eq "latest") {
        $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    }
    else {
        $apiUrl = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    }

    Write-Status "Querying GitHub API: $apiUrl" -Type Info

    try {
        $headers = @{ 'User-Agent' = 'TCGCloud-Deploy/2.1.1' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        return $release
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Status "Release not found. Check that '$Tag' exists in $Repo" -Type Error
        }
        throw "Failed to get release info from GitHub: $_"
    }
}

function Get-ReleaseAsset {
    <#
    .SYNOPSIS
        Downloads a specific asset from a GitHub Release.
    #>
    param (
        [object]$Release,
        [string]$AssetName,
        [string]$DestinationPath
    )

    $asset = $Release.assets | Where-Object { $_.name -eq $AssetName }

    if (-not $asset) {
        return $false
    }

    $downloadUrl = $asset.browser_download_url
    $sizeMB = [math]::Round($asset.size / 1MB, 1)
    Write-Status "Downloading $AssetName ($sizeMB MB)..." -Type Info

    $destFile = Join-Path $DestinationPath $AssetName

    # Use BITS for large files, Invoke-WebRequest for small ones
    if ($asset.size -gt 10MB) {
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Start-BitsTransfer -Source $downloadUrl -Destination $destFile -DisplayName "Downloading $AssetName"
        }
        catch {
            Write-Status "BITS transfer failed, falling back to web download" -Type Warning
            Invoke-WebRequest -Uri $downloadUrl -OutFile $destFile -UseBasicParsing
        }
    }
    else {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $destFile -UseBasicParsing
    }

    if (Test-Path $destFile) {
        Write-Status "Downloaded: $destFile" -Type Success
        return $true
    }

    return $false
}

function Get-ScriptsFromRepo {
    <#
    .SYNOPSIS
        Downloads the Scripts directory from the repository as a zip archive.
        Used as fallback when scripts.zip is not in the release.
    #>
    param (
        [string]$Repo,
        [string]$Tag,
        [string]$DestinationPath
    )

    if ($Tag -eq "latest") {
        $zipUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"
    }
    else {
        $zipUrl = "https://github.com/$Repo/archive/refs/tags/$Tag.zip"
    }

    Write-Status "Downloading repository archive from GitHub..." -Type Info
    $tempZip = Join-Path $env:TEMP "tcgcloud-repo-$(Get-Random).zip"
    $tempExtract = Join-Path $env:TEMP "tcgcloud-repo-$(Get-Random)"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

        # Extract
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        # Find the Scripts directory inside the extracted archive
        $extractedRoot = Get-ChildItem $tempExtract | Select-Object -First 1
        $scriptsSource = Join-Path $extractedRoot.FullName "Scripts"

        if (Test-Path $scriptsSource) {
            $scriptsDestination = Join-Path $DestinationPath "Scripts"
            if (Test-Path $scriptsDestination) {
                Remove-Item $scriptsDestination -Recurse -Force
            }
            Copy-Item $scriptsSource $scriptsDestination -Recurse -Force
            Write-Status "Scripts extracted to: $scriptsDestination" -Type Success
            return $true
        }
        else {
            Write-Status "Scripts directory not found in repository archive" -Type Error
            return $false
        }
    }
    finally {
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region Boot Configuration Functions
function New-WinPEBootEntry {
    <#
    .SYNOPSIS
        Creates a one-time WinPE boot entry using bcdedit.
    .DESCRIPTION
        Configures a RAM-disk boot entry that loads boot.wim from the local disk.
        Uses bcdedit /bootsequence so it only boots into WinPE once.
    #>
    param (
        [string]$WimPath,
        [string]$SdiPath
    )

    Write-Status "Configuring WinPE boot entry..." -Type Info

    # Determine boot partition drive letter (usually C:)
    $bootDrive = Split-Path -Qualifier $WimPath

    # Calculate relative paths from the drive root
    $wimRelative = $WimPath.Substring(2)  # Strip drive letter e.g. \TCGCloud\boot.wim
    $sdiRelative = $SdiPath.Substring(2)

    # Ensure ramdisk options exist
    Write-Status "Setting up RAM disk options..." -Type Info
    $null = bcdedit /create "{ramdiskoptions}" /d "TCGCloud Ramdisk Options" 2>$null
    bcdedit /set "{ramdiskoptions}" ramdisksdidevice "partition=$bootDrive" | Out-Null
    bcdedit /set "{ramdiskoptions}" ramdisksdipath "$sdiRelative" | Out-Null

    # Create a new boot entry
    Write-Status "Creating WinPE boot entry..." -Type Info
    $output = bcdedit /create /d "TCGCloud WinPE" /application osloader 2>&1
    $guidMatch = [regex]::Match($output, '\{[0-9a-f-]+\}')

    if (-not $guidMatch.Success) {
        throw "Failed to create boot entry. bcdedit output: $output"
    }

    $guid = $guidMatch.Value
    Write-Status "Boot entry created: $guid" -Type Success

    # Configure the boot entry
    $bootWimPath = "[$bootDrive]$wimRelative"

    # Determine winload path based on firmware type
    $firmware = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue).PEFirmwareType
    if ($firmware -eq 2) {
        # UEFI
        $winloadPath = "\Windows\System32\boot\winload.efi"
    }
    else {
        # BIOS/Legacy
        $winloadPath = "\Windows\System32\boot\winload.exe"
    }

    bcdedit /set $guid device "ramdisk=$bootWimPath,{ramdiskoptions}" | Out-Null
    bcdedit /set $guid osdevice "ramdisk=$bootWimPath,{ramdiskoptions}" | Out-Null
    bcdedit /set $guid path $winloadPath | Out-Null
    bcdedit /set $guid systemroot "\Windows" | Out-Null
    bcdedit /set $guid winpe yes | Out-Null
    bcdedit /set $guid detecthal yes | Out-Null

    # Set as one-time boot (next boot only)
    bcdedit /bootsequence $guid | Out-Null

    Write-Status "WinPE configured as next boot target (one-time)" -Type Success
    return $guid
}

function Remove-WinPEBootEntry {
    <#
    .SYNOPSIS
        Removes a previously created WinPE boot entry.
    #>
    param ([string]$Guid)

    if ($Guid) {
        bcdedit /delete $Guid /f 2>$null | Out-Null
        Write-Status "Removed boot entry: $Guid" -Type Info
    }
}

function New-BootableISO {
    <#
    .SYNOPSIS
        Creates a bootable WinPE ISO from the staged boot files.
    #>
    param (
        [string]$StagingPath,
        [string]$OutputISO
    )

    Write-Status "Creating bootable ISO..." -Type Info

    # Look for oscdimg.exe from ADK
    $oscdimg = $null
    $adkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    foreach ($path in $adkPaths) {
        if (Test-Path $path) {
            $oscdimg = $path
            break
        }
    }

    if (-not $oscdimg) {
        Write-Status "oscdimg.exe not found. Install Windows ADK to create ISOs." -Type Error
        Write-Status "Alternatively, use a tool like mkisofs or ImgBurn with the staged files at: $StagingPath" -Type Info
        return $false
    }

    # Create ISO directory structure
    $isoRoot = Join-Path $env:TEMP "tcgcloud-iso-$(Get-Random)"
    New-Item -Path "$isoRoot\sources" -ItemType Directory -Force | Out-Null
    New-Item -Path "$isoRoot\Boot" -ItemType Directory -Force | Out-Null

    Copy-Item (Join-Path $StagingPath "boot.wim") "$isoRoot\sources\boot.wim" -Force
    Copy-Item (Join-Path $StagingPath "boot.sdi") "$isoRoot\Boot\boot.sdi" -Force

    # Find EFI boot files from ADK
    $etfsboot = Join-Path (Split-Path $oscdimg) "..\..\..\..\Windows Preinstallation Environment\amd64\Media\Boot\etfsboot.com"
    $efisys = Join-Path (Split-Path $oscdimg) "..\..\..\..\Windows Preinstallation Environment\amd64\Media\Boot\efisys_noprompt.bin"

    if ((Test-Path $etfsboot) -and (Test-Path $efisys)) {
        # Create UEFI + BIOS bootable ISO
        & $oscdimg -bootdata:"2#p0,e,b$etfsboot#pEF,e,b$efisys" -u1 -udfver102 "$isoRoot" "$OutputISO"
    }
    else {
        # Basic ISO without boot optimization
        & $oscdimg -n -b"$etfsboot" "$isoRoot" "$OutputISO"
    }

    Remove-Item $isoRoot -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $OutputISO) {
        $isoSizeMB = [math]::Round((Get-Item $OutputISO).Length / 1MB, 1)
        Write-Status "ISO created: $OutputISO ($isoSizeMB MB)" -Type Success
        return $true
    }
    else {
        Write-Status "Failed to create ISO" -Type Error
        return $false
    }
}
#endregion

#region Main Execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   TCGCloud Network Deployment v2.1.1   " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Resolve GitHub release
Write-Status "GitHub Repository: $GitHubRepo" -Type Info
Write-Status "Release Tag: $ReleaseTag" -Type Info
Write-Status "Working Directory: $WorkingDirectory" -Type Info
Write-Host ""

$release = $null
$hasBootWim = $false
$hasBootSdi = $false
$hasScriptsZip = $false

try {
    $release = Get-GitHubReleaseInfo -Repo $GitHubRepo -Tag $ReleaseTag
    Write-Status "Found release: $($release.tag_name) — $($release.name)" -Type Success

    # Check which assets are available
    $assetNames = $release.assets | ForEach-Object { $_.name }
    Write-Status "Available assets: $($assetNames -join ', ')" -Type Info
}
catch {
    Write-Status "Could not reach GitHub API: $_" -Type Warning
    Write-Status "Will attempt direct download from repository..." -Type Info
}

# Step 2: Download boot media and scripts
Write-Status "" -Type Info
Write-Host "--- Downloading Boot Media ---" -ForegroundColor Cyan

$wimFile = $config.bootMedia.wimFileName
$sdiFile = $config.bootMedia.sdiFileName
$scriptsZip = $config.bootMedia.scriptsPackage

# Download boot.wim
if ($release) {
    $hasBootWim = Get-ReleaseAsset -Release $release -AssetName $wimFile -DestinationPath $WorkingDirectory
    $hasBootSdi = Get-ReleaseAsset -Release $release -AssetName $sdiFile -DestinationPath $WorkingDirectory
    $hasScriptsZip = Get-ReleaseAsset -Release $release -AssetName $scriptsZip -DestinationPath $WorkingDirectory
}

if (-not $hasBootWim) {
    $localWim = Join-Path $WorkingDirectory $wimFile
    if (Test-Path $localWim) {
        Write-Status "Using existing local boot.wim: $localWim" -Type Info
        $hasBootWim = $true
    }
    else {
        Write-Status "boot.wim not found in release and not available locally." -Type Error
        Write-Status "" -Type Info
        Write-Status "To create boot.wim, run Build-BootMedia.ps1 on a machine with Windows ADK installed," -Type Info
        Write-Status "then upload it to a GitHub Release in $GitHubRepo." -Type Info
        Write-Status "" -Type Info
        Write-Status "Alternatively, place a boot.wim file at: $localWim" -Type Info
        throw "boot.wim is required for network deployment. See above for instructions."
    }
}

if (-not $hasBootSdi) {
    $localSdi = Join-Path $WorkingDirectory $sdiFile
    if (Test-Path $localSdi) {
        Write-Status "Using existing local boot.sdi: $localSdi" -Type Info
        $hasBootSdi = $true
    }
    else {
        # Try to find boot.sdi from ADK installation
        $adkSdiPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\Media\Boot\boot.sdi",
            "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\Media\Boot\boot.sdi"
        )
        foreach ($sdiPath in $adkSdiPaths) {
            if (Test-Path $sdiPath) {
                Copy-Item $sdiPath $localSdi -Force
                Write-Status "Copied boot.sdi from local ADK installation" -Type Success
                $hasBootSdi = $true
                break
            }
        }

        if (-not $hasBootSdi) {
            Write-Status "boot.sdi not found. It is required for RAM-disk boot." -Type Error
            Write-Status "Run Build-BootMedia.ps1 to generate it, or install Windows ADK." -Type Info
            throw "boot.sdi is required for network deployment."
        }
    }
}

# Step 3: Get TCGCloud scripts
Write-Host ""
Write-Host "--- Downloading Scripts ---" -ForegroundColor Cyan

$scriptsDir = Join-Path $WorkingDirectory "Scripts"

if ($hasScriptsZip) {
    # Extract the scripts package
    $zipPath = Join-Path $WorkingDirectory $scriptsZip
    Write-Status "Extracting scripts package..." -Type Info

    if (Test-Path $scriptsDir) {
        Remove-Item $scriptsDir -Recurse -Force
    }

    Expand-Archive -Path $zipPath -DestinationPath $WorkingDirectory -Force
    Write-Status "Scripts extracted" -Type Success
}
else {
    # Fall back to downloading from the repository
    Write-Status "Scripts package not in release, downloading from repository..." -Type Info
    $downloaded = Get-ScriptsFromRepo -Repo $GitHubRepo -Tag $ReleaseTag -DestinationPath $WorkingDirectory

    if (-not $downloaded) {
        # Check if scripts already exist locally
        if (Test-Path $scriptsDir) {
            Write-Status "Using existing local scripts at: $scriptsDir" -Type Warning
        }
        else {
            throw "Failed to download TCGCloud scripts. Check your internet connection and repository URL."
        }
    }
}

# Verify scripts are present
$requiredScripts = @(
    "init.ps1",
    "StartNet\_init.ps1",
    "StartNet\Show-OSDCloudOverlay.ps1"
)

foreach ($script in $requiredScripts) {
    $scriptPath = Join-Path $scriptsDir $script
    if (-not (Test-Path $scriptPath)) {
        Write-Status "Missing required script: $script" -Type Warning
    }
}

# Step 4: Copy deploy-config.json alongside scripts for WinPE access
if (Test-Path $configPath) {
    Copy-Item $configPath (Join-Path $WorkingDirectory "deploy-config.json") -Force
}

# Step 5: Create ISO or configure boot entry
Write-Host ""
$wimPath = Join-Path $WorkingDirectory $wimFile
$sdiPath = Join-Path $WorkingDirectory $sdiFile

if ($CreateISO) {
    Write-Host "--- Creating Bootable ISO ---" -ForegroundColor Cyan
    $isoPath = Join-Path $WorkingDirectory "TCGCloud-WinPE.iso"
    $result = New-BootableISO -StagingPath $WorkingDirectory -OutputISO $isoPath

    if ($result) {
        Write-Host ""
        Write-Status "ISO created successfully!" -Type Success
        Write-Status "File: $isoPath" -Type Info
        Write-Status "You can:" -Type Info
        Write-Status "  • Mount in Hyper-V as a virtual DVD" -Type Info
        Write-Status "  • Burn to a disc" -Type Info
        Write-Status "  • Use Rufus or similar to write to USB" -Type Info
    }
}
else {
    Write-Host "--- Configuring WinPE Boot ---" -ForegroundColor Cyan

    if (-not $Force) {
        Write-Host ""
        Write-Host "This will configure your machine to boot into WinPE on next restart." -ForegroundColor Yellow
        Write-Host "The boot entry is one-time only — if you don't reboot, nothing changes." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Continue? (Y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Status "Cancelled by user" -Type Warning
            Stop-Transcript -ErrorAction SilentlyContinue
            exit 0
        }
    }

    $bootGuid = New-WinPEBootEntry -WimPath $wimPath -SdiPath $sdiPath

    # Save the GUID so we can clean up later if needed
    $bootGuid | Out-File -FilePath (Join-Path $WorkingDirectory "boot-entry-guid.txt") -Force

    Write-Host ""
    Write-Status "Boot configuration complete!" -Type Success
    Write-Host ""
    Write-Host "  Boot Entry:  $bootGuid" -ForegroundColor White
    Write-Host "  Boot WIM:    $wimPath" -ForegroundColor White
    Write-Host "  Scripts:     $scriptsDir" -ForegroundColor White
    Write-Host ""

    if (-not $SkipReboot) {
        Write-Host "The system will reboot into TCGCloud WinPE in 10 seconds..." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C to cancel the reboot (boot entry will remain for manual reboot)." -ForegroundColor Yellow
        Write-Host ""

        for ($i = 10; $i -gt 0; $i--) {
            Write-Host "`rRebooting in $i seconds... " -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }

        Write-Host ""
        Stop-Transcript -ErrorAction SilentlyContinue
        Restart-Computer -Force
    }
    else {
        Write-Status "Reboot skipped (use -SkipReboot:$false or restart manually)" -Type Info
        Write-Status "To reboot manually: Restart-Computer -Force" -Type Info
        Write-Status "To remove the boot entry: bcdedit /delete $bootGuid /f" -Type Info
    }
}

Stop-Transcript -ErrorAction SilentlyContinue
#endregion
