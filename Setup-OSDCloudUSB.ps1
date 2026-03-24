#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Creates a TCGCloud USB drive with Windows ADK, WinPE, and optional Office deployment.
.DESCRIPTION
    This script automates the creation of a TCGCloud USB drive by:
    - Installing Windows ADK and WinPE components if needed
    - Creating a TCGCloud template and workspace (using the native TCGCloud module)
    - Adding custom scripts and configuration
    - Formatting and preparing a USB drive
    - Adding Windows installation media
    - Adding Office deployment files
.PARAMETER WorkingDirectory
    The directory where all working files will be stored
    Default: C:\TCG-OSDCloud
.PARAMETER OSName
    Specific Windows OS to install (optional)
.PARAMETER OSLanguage
    Language code for OS installation (default: en-us)
.PARAMETER NoOS
    Skip OS installation if specified
.NOTES
    Version: 2.0
    Created by: TCG
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$WorkingDirectory = "C:\TCG-OSDCloud",
    
    [Parameter(Mandatory = $false)]
    [string]$OSName,
    
    [Parameter(Mandatory = $false)]
    [string]$OSLanguage = "en-us",
    
    [Parameter(Mandatory = $false)]
    [switch]$NoOS
)

#region Script Initialization
# Initialize script configuration
$script:Config = @{
    Paths  = @{
        Working  = $WorkingDirectory
        Logs     = Join-Path $WorkingDirectory "Logs"
        Media    = Join-Path $WorkingDirectory "Media"
        ISOs     = Join-Path $WorkingDirectory "ISOs"
        Sources  = Join-Path $WorkingDirectory "Sources"
        Temp     = Join-Path $WorkingDirectory "Temp"
        Template = Join-Path $WorkingDirectory "Template"
    }
    ADK    = @{
        Version = "10.1.25398.1"
        URLs    = @{
            ADK   = "https://osdcloud1.blob.core.windows.net/adk/Windows_InsiderPreview_ADK_en-us_26100.iso"
            WinPE = "https://osdcloud1.blob.core.windows.net/adk/Windows_Preinstallation_Environment_en-us_26100.iso"
        }
        Hashes  = @{
            ADK   = "D67308D386E37169B0A357CCBF2FDED1A362DBD9550322EA866C439BD83F995D"
            WinPE = "C1688BF226FACE0F36D37282B7C276B3A8288856F8AE9D33518B5D9B445657FD"
        }
    }
    Office = @{
        ODTUrl = "https://download.microsoft.com/download/2/7/A/27AF1BE6-DD20-4CB4-B154-EBAB8A7D4A7E/officedeploymenttool_16501-20196.exe"
    }
}

# Start transcript logging
$transcriptPath = Join-Path $script:Config.Paths.Logs "Setup-OSDCloudUSB_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
New-Item -ItemType Directory -Path $script:Config.Paths.Logs -Force -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path $transcriptPath -ErrorAction SilentlyContinue

# Set output encoding for proper display of Unicode characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#endregion

#region Utility Functions
function Write-Status {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $icon = switch ($Type) {
        'Info' { "[*]" }
        'Success' { "[+]" }
        'Warning' { "[!]" }
        'Error' { "[x]" }
    }
    $color = switch ($Type) {
        'Info' { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
    }
    Write-Host "$icon $Message" -ForegroundColor $color
}

function Write-TaskHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    Write-Host ("=" * ($Title.Length + 8)) -ForegroundColor DarkGray
}

function Convert-ToTaskHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Line
    )
    
    process {
        if ($Line -match "^={10,}") {
            # This is a header divider line, output as is
            Write-Host $Line -ForegroundColor DarkGray
        } 
        elseif ($Line -match "^\d{4}-\d{2}-\d{2}") {
            # This looks like a date, might be a header title
            Write-Host $Line -ForegroundColor Cyan
        }
        else {
            # Regular line, output as is
            Write-Host $Line
        }
    }
}

function New-RequiredDirectory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Status "Cannot create directory: Path is empty" -Type Error
        return $false
    }
    
    if (-not (Test-Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            Write-Status "Created directory: $Path" -Type Success
            return $true
        }
        catch {
            Write-Status "Failed to create directory: $Path - $_" -Type Error
            return $false
        }
    }
    return $true
}

function Initialize-Environment {
    [CmdletBinding()]
    param()
    
    $pathsCreated = $true
    foreach ($path in $script:Config.Paths.Values) {
        if (-not (New-RequiredDirectory -Path $path)) {
            $pathsCreated = $false
        }
    }
    return $pathsCreated
}

function Test-FileHash {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash
    )
    
    if (-not (Test-Path $FilePath)) { return $false }
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash -eq $ExpectedHash
    }
    catch {
        Write-Status "Failed to verify file hash: $_" -Type Warning
        return $false
    }
}

function Get-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        
        [Parameter(Mandatory = $true)]
        [string]$Description,
        
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$RetryWaitSeconds = 5
    )
    
    try {
        Write-Status "Downloading $Description..." -Type Info
        
        # Create destination directory if it doesn't exist
        $destDir = Split-Path -Parent $Destination
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        
        # Try BITS transfer with retry logic
        for ($i = 1; $i -le $RetryCount; $i++) {
            try {
                $job = Start-BitsTransfer -Source $Url -Destination $Destination `
                    -DisplayName $Description -Description "TCGCloud Download" `
                    -RetryInterval 60 -RetryTimeout 3600 -ErrorAction Stop -Asynchronous
                
                while ($job.JobState -in @('Transferring', 'Connecting')) {
                    $progress = [math]::Round(($job.BytesTransferred / $job.BytesTotal) * 100, 2)
                    $transferred = [math]::Round($job.BytesTransferred / 1MB, 2)
                    $total = [math]::Round($job.BytesTotal / 1MB, 2)
                    Write-Progress -Activity "Downloading $Description" `
                        -Status "$transferred MB / $total MB ($progress%)" `
                        -PercentComplete $progress
                    Start-Sleep -Milliseconds 500
                }
                
                Complete-BitsTransfer -BitsJob $job
                Write-Progress -Activity "Downloading $Description" -Completed
                return $true
            }
            catch {
                if ($job) {
                    Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                }
                if ($i -lt $RetryCount) {
                    Write-Status "Download attempt $i failed, retrying in $RetryWaitSeconds seconds..." -Type Warning
                    Start-Sleep -Seconds $RetryWaitSeconds
                }
                else { throw }
            }
        }
    }
    catch {
        Write-Status "Download failed after $RetryCount attempts: $_" -Type Error
        return $false
    }
}

function Mount-IsoAndCopySetup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$IsoPath,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        
        [Parameter(Mandatory = $true)]
        [string]$SetupFileName
    )
    
    try {
        # Ensure any existing mount is removed
        Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | 
        Where-Object { $_.Attached } | 
        ForEach-Object { Dismount-DiskImage -ImagePath $_.ImagePath }
        
        # Mount ISO
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $driveLetter = ($mountResult | Get-Volume).DriveLetter
        $setupPath = "${driveLetter}:\$SetupFileName"
        
        if (-not (Test-Path $setupPath)) {
            throw "Setup file not found in ISO at: $setupPath"
        }
        
        # Ensure destination directory exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
        
        # Copy setup file
        Copy-Item -Path $setupPath -Destination (Join-Path $DestinationPath $SetupFileName) -Force
        Write-Status "Copied $SetupFileName from ISO to $DestinationPath" -Type Success
        
        return $true
    }
    catch {
        Write-Status "Failed to copy setup file from ISO: $_" -Type Error
        return $false
    }
    finally {
        # Always try to dismount ISO
        try {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        }
        catch {
            Write-Status "Warning: Failed to dismount ISO: $_" -Type Warning
        }
    }
}

function Extract-LanguageCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$OSFileName
    )
    
    # Default to en-us if we can't extract
    $defaultLang = "en-us"
    
    try {
        Write-Status "Extracting language from filename: $OSFileName" -Type Info
        
        # Look for standard language pattern in filename
        if ($OSFileName -match "_([a-z]{2}-[a-z]{2})\.") {
            return $Matches[1].ToLower()
        }
        
        if ($OSFileName -match "_([a-z]{2}-[a-z]{2})_") {
            return $Matches[1].ToLower()
        }
        
        # Check for specific patterns at the end of the filename
        if ($OSFileName -match "_([a-z]{2}-[a-z]{2})\.esd$") {
            return $Matches[1].ToLower()
        }
        
        # More detailed check for specific languages
        $languagePatterns = @{
            "sv-se" = "_sv-se|_sve_|_swedish_"
            "en-us" = "_en-us|_enu_|_english_"
            "de-de" = "_de-de|_deu_|_german_"
            "pl-pl" = "_pl-pl|_plk_|_polish_"
        }
        
        foreach ($lang in $languagePatterns.Keys) {
            $pattern = $languagePatterns[$lang]
            if ($OSFileName -match $pattern) {
                Write-Status "Matched language pattern for $lang" -Type Info
                return $lang
            }
        }
        
        # If no match found, return default
        Write-Status "No language pattern matched, using default: $defaultLang" -Type Warning
        return $defaultLang
    }
    catch {
        Write-Status "Error extracting language code: $_" -Type Warning
        return $defaultLang
    }
}
#endregion

#region Core Functions
function Install-Prerequisites {
    [CmdletBinding()]
    param()
    
    try {
        # Load the TCGCloud module from the Scripts directory bundled with this script
        $tcgModulePath = Join-Path $PSScriptRoot 'Scripts\Modules\TCGCloud\TCGCloud.psd1'
        if (Test-Path $tcgModulePath) {
            Import-Module $tcgModulePath -Force -ErrorAction Stop
            Write-Status "TCGCloud module loaded from: $tcgModulePath" -Type Success
        }
        else {
            Write-Status "TCGCloud module not found at: $tcgModulePath" -Type Error
            return $false
        }

        return $true
    }
    catch {
        Write-Status "Failed to load prerequisites: $_" -Type Error
        return $false
    }
}

function Get-AdkVersion {
    <#
    .SYNOPSIS
        Gets the installed Windows ADK version
    .DESCRIPTION
        Checks the registry for installed Windows ADK components and returns version information
    .NOTES
        Returns $null if not found
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Check the primary ADK registry path
        $adkRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots"
        
        if (-not (Test-Path $adkRegistryPath)) {
            Write-Status "Windows ADK registry path not found: $adkRegistryPath" -Type Warning
            
            # Check alternative path for older ADK versions
            $altPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
            if (Test-Path $altPath) {
                $adkRegistryPath = $altPath
                Write-Status "Found alternative ADK registry path: $adkRegistryPath" -Type Info
            }
            else {
                return $null
            }
        }
        
        # Get the ADK installation path
        $adkInstallPath = Get-ItemProperty -Path $adkRegistryPath -Name "KitsRoot10" -ErrorAction SilentlyContinue
        
        if (-not $adkInstallPath) {
            Write-Status "Windows ADK installation path not found in registry" -Type Warning
            return $null
        }
        
        $adkPath = $adkInstallPath.KitsRoot10
        Write-Status "Windows ADK path: $adkPath" -Type Info
        
        # Check if Assessment and Deployment Kit folder exists
        if (-not (Test-Path "$adkPath\Assessment and Deployment Kit")) {
            Write-Status "Windows ADK folder structure not found" -Type Warning
            return $null
        }
        
        # Check for Windows PE files to confirm installation
        $winPEPath = "$adkPath\Assessment and Deployment Kit\Windows Preinstallation Environment"
        if (Test-Path $winPEPath) {
            # Try to get version from product.ini file
            $productFile = "$adkPath\Assessment and Deployment Kit\product.ini"
            if (Test-Path $productFile) {
                $versionInfo = Get-Content $productFile | Where-Object { $_ -like "Version=*" }
                if ($versionInfo) {
                    $version = ($versionInfo -split "=")[1].Trim()
                    return $version
                }
            }
            
            # Return a generic version if we can't find the exact one but ADK is installed
            return "Installed" 
        }
        
        return $null
    }
    catch {
        Write-Status "Error checking Windows ADK: $_" -Type Error
        return $null
    }
}

function Remove-Adk {
    [CmdletBinding()]
    param()
    
    Write-Status "Removing existing ADK installation..." -Type Info
    
    try {
        # Find existing ADK uninstaller
        $uninstallKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
        Where-Object { $_.DisplayName -like "*Windows Assessment and Deployment Kit*" }
        
        if ($uninstallKey) {
            $uninstallString = $uninstallKey.UninstallString
            if ($uninstallString) {
                # Extract the uninstall command
                if ($uninstallString -match '"([^"]+)"(.*)') {
                    $uninstallExe = $Matches[1]
                    $uninstallArgs = $Matches[2] + " /quiet"
                    
                    Write-Status "Running ADK uninstaller..." -Type Info
                    $process = Start-Process -FilePath $uninstallExe -ArgumentList $uninstallArgs -Wait -PassThru
                    
                    if ($process.ExitCode -eq 0) {
                        Write-Status "ADK uninstalled successfully" -Type Success
                        return $true
                    }
                    else {
                        Write-Status "ADK uninstallation exited with code: $($process.ExitCode)" -Type Warning
                    }
                }
            }
        }
        
        # If we got here, we couldn't find the uninstaller or it failed
        Write-Status "Could not find or run ADK uninstaller, attempting manual cleanup..." -Type Warning
        
        # Try to manually remove ADK directories
        $adkPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit",
            "${env:ProgramFiles(x86)}\Windows Kits\10\ADK"
        )
        
        foreach ($path in $adkPaths) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Removed $path" -Type Info
            }
        }
        
        return $true
    }
    catch {
        Write-Status "Error removing ADK: $_" -Type Error
        return $false
    }
}

function Get-AdkSetupFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$WorkingDir,
        
        [Parameter(Mandatory = $false)]
        [string]$AdkIsoUrl = $script:Config.ADK.URLs.ADK,
        
        [Parameter(Mandatory = $false)]
        [string]$WinPEIsoUrl = $script:Config.ADK.URLs.WinPE
    )
    
    try {
        # Define paths
        $adkIsoPath = Join-Path $script:Config.Paths.ISOs "adk.iso"
        $winpeIsoPath = Join-Path $script:Config.Paths.ISOs "winpe.iso"
        
        # Ensure ISOs directory exists
        New-RequiredDirectory -Path $script:Config.Paths.ISOs | Out-Null
        
        # Download and verify ADK ISO
        $adkDownloadNeeded = $true
        if (Test-Path $adkIsoPath) {
            Write-Status "Found existing Windows ADK ISO, verifying..." -Type Info
            if (Test-FileHash -FilePath $adkIsoPath -ExpectedHash $script:Config.ADK.Hashes.ADK) {
                Write-Status "Windows ADK ISO verified successfully" -Type Success
                $adkDownloadNeeded = $false
            }
            else {
                Write-Status "Windows ADK ISO verification failed, will download again" -Type Warning
                Remove-Item -Path $adkIsoPath -Force -ErrorAction SilentlyContinue
            }
        }
        
        if ($adkDownloadNeeded) {
            if (-not (Get-File -Url $AdkIsoUrl -Destination $adkIsoPath -Description "Windows ADK ISO")) {
                throw "Failed to download Windows ADK ISO"
            }
            
            # Verify downloaded file
            if (-not (Test-FileHash -FilePath $adkIsoPath -ExpectedHash $script:Config.ADK.Hashes.ADK)) {
                Remove-Item -Path $adkIsoPath -Force -ErrorAction SilentlyContinue
                throw "Downloaded Windows ADK ISO failed hash verification"
            }
            
            Write-Status "Windows ADK ISO downloaded and verified successfully" -Type Success
        }
        
        # Download and verify WinPE ISO
        $winpeDownloadNeeded = $true
        if (Test-Path $winpeIsoPath) {
            Write-Status "Found existing Windows PE Add-on ISO, verifying..." -Type Info
            if (Test-FileHash -FilePath $winpeIsoPath -ExpectedHash $script:Config.ADK.Hashes.WinPE) {
                Write-Status "Windows PE Add-on ISO verified successfully" -Type Success
                $winpeDownloadNeeded = $false
            }
            else {
                Write-Status "Windows PE Add-on ISO verification failed, will download again" -Type Warning
                Remove-Item -Path $winpeIsoPath -Force -ErrorAction SilentlyContinue
            }
        }
        
        if ($winpeDownloadNeeded) {
            if (-not (Get-File -Url $WinPEIsoUrl -Destination $winpeIsoPath -Description "Windows PE Add-on ISO")) {
                throw "Failed to download Windows PE Add-on ISO"
            }
            
            # Verify downloaded file
            if (-not (Test-FileHash -FilePath $winpeIsoPath -ExpectedHash $script:Config.ADK.Hashes.WinPE)) {
                Remove-Item -Path $winpeIsoPath -Force -ErrorAction SilentlyContinue
                throw "Downloaded Windows PE Add-on ISO failed hash verification"
            }
            
            Write-Status "Windows PE Add-on ISO downloaded and verified successfully" -Type Success
        }
        
        return $true
    }
    catch {
        Write-Status "Failed to prepare ADK setup files: $_" -Type Error
        return $false
    }
}

function Install-ADKComponents {
    [CmdletBinding()]
    param()
    
    try {
        # Check for existing ADK installation
        $currentAdk = Get-AdkVersion
        $targetVersion = [version]$script:Config.ADK.Version
        
        if ($currentAdk.Installed) {
            if (-not $currentAdk.WinPEInstalled) {
                Write-Status "ADK installed but WinPE add-on missing, will install WinPE only" -Type Warning
                return Install-WinPEOnly
            }
            elseif ($currentAdk.Version -and $currentAdk.Version -lt $targetVersion) {
                Write-Status "ADK version $($currentAdk.Version) is older than target version $targetVersion, will reinstall" -Type Warning
                Remove-Adk
            }
            else {
                Write-Status "Using existing Windows ADK installation" -Type Success
                return $true
            }
        }
        
        # If we got here, we need to download and install ADK
        Write-Status "Preparing to install Windows ADK" -Type Info
        
        # Get ADK setup files
        if (-not (Get-AdkSetupFiles -WorkingDir $WorkingDirectory)) {
            throw "Failed to prepare ADK setup files"
        }
        
        # Install from ISOs directly
        $adkIsoPath = Join-Path $script:Config.Paths.ISOs "adk.iso"
        $winpeIsoPath = Join-Path $script:Config.Paths.ISOs "winpe.iso"
        
        # Create log directory
        New-RequiredDirectory -Path $script:Config.Paths.Logs | Out-Null
        
        # Install ADK
        Write-Status "Installing Windows ADK..." -Type Info
        
        try {
            # Mount ADK ISO
            $adkMountResult = Mount-DiskImage -ImagePath $adkIsoPath -PassThru
            $adkDriveLetter = ($adkMountResult | Get-Volume).DriveLetter
            $adkSetupPath = "${adkDriveLetter}:\adksetup.exe"
            
            if (-not (Test-Path $adkSetupPath)) {
                throw "ADK setup file not found in ISO at: $adkSetupPath"
            }
            
            # Define ADK installation parameters
            $adkLogPath = Join-Path $script:Config.Paths.Logs "adksetup.log"
            $adkArgs = @(
                "/quiet"
                "/norestart"
                "/log", "`"$adkLogPath`""
                "/features", "OptionId.DeploymentTools OptionId.ImagingAndConfigurationDesigner OptionId.ICDConfigurationDesigner"
                "/ceip", "off"
                "/installpath", "`"${env:ProgramFiles(x86)}\Windows Kits\10`""
            )
            
            # Run ADK setup
            $adkProcess = Start-Process -FilePath $adkSetupPath -ArgumentList $adkArgs -Wait -PassThru -NoNewWindow
            
            # Check result
            if ($adkProcess.ExitCode -ne 0 -and $adkProcess.ExitCode -ne 3010) {
                # Read the log file to provide more details on failure
                if (Test-Path $adkLogPath) {
                    $logContent = Get-Content -Path $adkLogPath -Tail 20 -ErrorAction SilentlyContinue
                    $errorMsg = "ADK installation failed with exit code: $($adkProcess.ExitCode)"
                    if ($logContent) {
                        $errorMsg += "`nLast lines from log:`n$($logContent -join "`n")"
                    }
                    throw $errorMsg
                }
                else {
                    throw "ADK installation failed with exit code: $($adkProcess.ExitCode)"
                }
            }
            
            Write-Status "Windows ADK installed successfully" -Type Success
        }
        finally {
            # Ensure ISO is dismounted even if installation fails
            Dismount-DiskImage -ImagePath $adkIsoPath -ErrorAction SilentlyContinue
        }
        
        # Install WinPE
        Write-Status "Installing Windows PE add-on..." -Type Info
        
        try {
            # Mount WinPE ISO
            $winpeMountResult = Mount-DiskImage -ImagePath $winpeIsoPath -PassThru
            $winpeDriveLetter = ($winpeMountResult | Get-Volume).DriveLetter
            $winpeSetupPath = "${winpeDriveLetter}:\adkwinpesetup.exe"
            
            if (-not (Test-Path $winpeSetupPath)) {
                throw "WinPE setup file not found in ISO at: $winpeSetupPath"
            }
            
            # Define WinPE installation parameters
            $winpeLogPath = Join-Path $script:Config.Paths.Logs "winpesetup.log"
            $winpeArgs = @(
                "/quiet"
                "/norestart"
                "/log", "`"$winpeLogPath`""
                "/features", "OptionId.WindowsPreinstallationEnvironment"
                "/ceip", "off"
                "/installpath", "`"${env:ProgramFiles(x86)}\Windows Kits\10`""
            )
            
            # Run WinPE setup
            $winpeProcess = Start-Process -FilePath $winpeSetupPath -ArgumentList $winpeArgs -Wait -PassThru -NoNewWindow
            
            # Check result
            if ($winpeProcess.ExitCode -ne 0 -and $winpeProcess.ExitCode -ne 3010) {
                # Read the log file to provide more details on failure
                if (Test-Path $winpeLogPath) {
                    $logContent = Get-Content -Path $winpeLogPath -Tail 20 -ErrorAction SilentlyContinue
                    $errorMsg = "WinPE installation failed with exit code: $($winpeProcess.ExitCode)"
                    if ($logContent) {
                        $errorMsg += "`nLast lines from log:`n$($logContent -join "`n")"
                    }
                    throw $errorMsg
                }
                else {
                    throw "WinPE installation failed with exit code: $($winpeProcess.ExitCode)"
                }
            }
            
            Write-Status "Windows PE add-on installed successfully" -Type Success
        }
        finally {
            # Ensure ISO is dismounted even if installation fails
            Dismount-DiskImage -ImagePath $winpeIsoPath -ErrorAction SilentlyContinue
        }

        Write-Status "ADK components installed successfully" -Type Success
        return $true
    }
    catch {
        Write-Status "Failed to install ADK components: $_" -Type Error
        return $false
    }
}

function Install-WinPEOnly {
    [CmdletBinding()]
    param()
    
    try {
        # Prepare WinPE ISO
        $winpeIsoPath = Join-Path $script:Config.Paths.ISOs "winpe.iso"
        
        if (-not (Test-Path $winpeIsoPath)) {
            if (-not (Get-AdkSetupFiles -WorkingDir $WorkingDirectory)) {
                throw "Failed to prepare WinPE setup files"
            }
        }
        
        # Install WinPE from ISO directly
        Write-Status "Installing Windows PE add-on only..." -Type Info
        
        try {
            # Mount WinPE ISO
            $winpeMountResult = Mount-DiskImage -ImagePath $winpeIsoPath -PassThru
            $winpeDriveLetter = ($winpeMountResult | Get-Volume).DriveLetter
            $winpeSetupPath = "${winpeDriveLetter}:\adkwinpesetup.exe"
            
            if (-not (Test-Path $winpeSetupPath)) {
                throw "WinPE setup file not found in ISO at: $winpeSetupPath"
            }
            
            # Define WinPE installation parameters
            $winpeLogPath = Join-Path $script:Config.Paths.Logs "winpesetup.log"
            $winpeArgs = @(
                "/quiet"
                "/norestart"
                "/log", "`"$winpeLogPath`""
                "/features", "OptionId.WindowsPreinstallationEnvironment"
                "/ceip", "off"
                "/installpath", "`"${env:ProgramFiles(x86)}\Windows Kits\10`""
            )
            
            # Run WinPE setup
            $winpeProcess = Start-Process -FilePath $winpeSetupPath -ArgumentList $winpeArgs -Wait -PassThru -NoNewWindow
            
            # Check result
            if ($winpeProcess.ExitCode -ne 0 -and $winpeProcess.ExitCode -ne 3010) {
                throw "WinPE installation failed with exit code: $($winpeProcess.ExitCode)"
            }
            
            Write-Status "Windows PE add-on installed successfully" -Type Success
            return $true
        }
        finally {
            # Ensure ISO is dismounted even if installation fails
            Dismount-DiskImage -ImagePath $winpeIsoPath -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Status "Failed to install WinPE add-on: $_" -Type Error
        return $false
    }
}

function Get-USBDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$MinimumSizeGB = 8,
        
        [Parameter(Mandatory = $false)]
        [int]$MaximumSizeGB = 256
    )
    
    try {
        Write-Status "Searching for USB drives..." -Type Info
        
        # Get all physical disks
        $allDisks = Get-Disk -ErrorAction SilentlyContinue
        
        # Filter for USB disks with appropriate size
        $usbDisks = $allDisks | Where-Object { 
            $_.BusType -eq 'USB' -and 
            $_.Size -ge ($MinimumSizeGB * 1GB) -and 
            $_.Size -le ($MaximumSizeGB * 1GB) -and
            $_.OperationalStatus -eq 'Online'
        }
        
        # Display all USB disks found for debugging
        if ($usbDisks) {
            Write-Status "Found $($usbDisks.Count) USB disk(s):" -Type Info
            foreach ($disk in $usbDisks) {
                $sizeGB = [math]::Round($disk.Size / 1GB, 2)
                Write-Status "  - Disk $($disk.Number): $($disk.FriendlyName) ($sizeGB GB)" -Type Info
            }
        }
        else {
            # Try an alternative approach if no USB disks found
            $usbDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue | 
            Where-Object { $_.InterfaceType -eq 'USB' -and $_.Size -ge ($MinimumSizeGB * 1GB) -and $_.Size -le ($MaximumSizeGB * 1GB) }
            
            if ($usbDisks) {
                Write-Status "Found $($usbDisks.Count) USB disk(s) via WMI:" -Type Info
                foreach ($disk in $usbDisks) {
                    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
                    Write-Status "  - Disk $($disk.Index): $($disk.Model) ($sizeGB GB)" -Type Info
                }
            }
            else {
                Write-Status "No suitable USB drives found" -Type Warning
                return $null
            }
        }
        
        # If multiple disks, select the first one
        $selectedDisk = $usbDisks | Select-Object -First 1
        
        # Get the drive letter
        $partitions = Get-Partition -DiskNumber $selectedDisk.Number -ErrorAction SilentlyContinue | 
        Where-Object { $_.Type -eq 'Basic' }
        
        $volumes = $partitions | Get-Volume -ErrorAction SilentlyContinue | 
        Where-Object { $null -ne $_.DriveLetter }
        
        $driveLetter = $volumes | Select-Object -ExpandProperty DriveLetter -First 1
        
        if ($driveLetter) {
            $volumeInfo = Get-Volume -DriveLetter $driveLetter
            $freeSpaceGB = [math]::Round($volumeInfo.SizeRemaining / 1GB, 2)
            $totalSizeGB = [math]::Round($volumeInfo.Size / 1GB, 2)
            
            Write-Status "Selected USB drive at ${driveLetter}: ($totalSizeGB GB, $freeSpaceGB GB free)" -Type Success
            return @{
                Disk        = $selectedDisk
                DriveLetter = $driveLetter
                Path        = "${driveLetter}:"
                FreeSpaceGB = $freeSpaceGB
                TotalSizeGB = $totalSizeGB
            }
        }
        else {
            Write-Status "USB drive found but has no accessible drive letter" -Type Warning
            
            # Try to assign a drive letter
            try {
                $partitions | ForEach-Object {
                    if (-not $_.DriveLetter) {
                        $driveLetter = [char]((67..90) | Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1)
                        if ($driveLetter) {
                            Write-Status "Assigning drive letter $driveLetter to USB partition" -Type Info
                            Set-Partition -InputObject $_ -NewDriveLetter $driveLetter -ErrorAction SilentlyContinue
                            return @{
                                Disk            = $selectedDisk
                                DriveLetter     = $driveLetter
                                Path            = "${driveLetter}:"
                                IsNewlyAssigned = $true
                            }
                        }
                    }
                }
            }
            catch {
                Write-Status "Error assigning drive letter: $_" -Type Error
            }
            
            # Return the disk even without a drive letter
            $sizeGB = [math]::Round($selectedDisk.Size / 1GB, 2)
            Write-Status "Will use disk directly: $($selectedDisk.FriendlyName) ($sizeGB GB)" -Type Info
            
            return @{
                Disk          = $selectedDisk
                DiskNumber    = $selectedDisk.Number
                TotalSizeGB   = $sizeGB
                NoDriveLetter = $true
            }
        }
    }
    catch {
        Write-Status "Error detecting USB drives: $_" -Type Error
        return $null
    }
}

function Test-ODT {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    try {
        $odtPath = Join-Path $Path "setup.exe"
        
        # If ODT already exists, return it
        if (Test-Path $odtPath) {
            return $odtPath
        }
        
        # Create directory if needed
        if (-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        
        # Use the known working ODT URL
        $odtUrl = "https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_18526-20146.exe"
        $odtSetupPath = Join-Path $Path "odtsetup.exe"
        
        if (-not (Get-File -Url $odtUrl -Destination $odtSetupPath -Description "Office Deployment Tool")) {
            throw "Failed to download Office Deployment Tool"
        }
        
        Write-Status "Extracting Office Deployment Tool..." -Type Info
        $extractPath = Join-Path $Path "extracted"
        if (-not (Test-Path $extractPath)) {
            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        }
        
        # Run extraction process hidden to prevent popup window
        # Only use WindowStyle parameter, not NoNewWindow (they conflict)
        Start-Process -FilePath $odtSetupPath -ArgumentList "/extract:$extractPath /quiet" -Wait -WindowStyle Hidden
        $extractedSetup = Join-Path $extractPath "setup.exe"
        
        if (Test-Path $extractedSetup) {
            return $extractedSetup
        }
        elseif (Test-Path $odtSetupPath) {
            return $odtSetupPath
        }
        else {
            throw "Failed to extract Office Deployment Tool"
        }
    }
    catch {
        Write-Status "Failed to set up Office Deployment Tool: $_" -Type Error
        return $null
    }
}

function Download-OfficeSources {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Setup,
        
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $false)]
        [string]$Lang = "en-us"
    )
    
    try {
        # Create paths
        $sourcesPath = Join-Path $Path "OfficeSources"
        New-RequiredDirectory -Path $sourcesPath | Out-Null
        
        # Create configuration XML with working settings
        $configXml = @"
<Configuration>
    <Add OfficeClientEdition="64" 
         Channel="MonthlyEnterprise" 
         SourcePath="$sourcesPath" 
         AllowCdnFallback="TRUE">
        <Product ID="O365ProPlusRetail">
            <Language ID="$Lang"/>
        </Product>
        <Product ID="LanguagePack">
            <Language ID="$Lang"/>
        </Product>
    </Add>
    <Display Level="None" AcceptEULA="TRUE"/>
    <Logging Level="Standard" Path="$($script:Config.Paths.Logs)" />
</Configuration>
"@
        
        $configPath = Join-Path $Path "download.xml"
        Set-Content -Path $configPath -Value $configXml -Force -Encoding UTF8
        
        # Create a PowerShell job to monitor the log file for progress
        $logPath = Join-Path $script:Config.Paths.Logs "Office*.log"
        $monitorJob = Start-Job -ScriptBlock {
            param($logPath)
            
            $lastLogSize = 0
            $waitCount = 0
            $maxWait = 600 # 10 minutes max wait time
            
            while ($waitCount -lt $maxWait) {
                Start-Sleep -Seconds 2
                $waitCount += 2
                
                # Check if log file exists
                $logFile = Get-Item -Path $logPath -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                
                if ($logFile) {
                    $waitCount = 0 # Reset wait counter when log found
                    $currentSize = $logFile.Length
                    
                    if ($currentSize -gt $lastLogSize) {
                        # Get last 10 lines of the log
                        $logContent = Get-Content -Path $logFile.FullName -Tail 10 -ErrorAction SilentlyContinue
                        
                        # Look for download progress indicators
                        foreach ($line in $logContent) {
                            if ($line -match '(Download|Downloading|Progress)') {
                                Write-Output $line
                                break
                            }
                        }
                        
                        $lastLogSize = $currentSize
                    }
                    
                    # Check if the download appears to be complete
                    $logContent = Get-Content -Path $logFile.FullName -Tail 20 -ErrorAction SilentlyContinue
                    if ($logContent -match 'Download completed successfully' -or $logContent -match 'Operation completed successfully') {
                        Write-Output "Download completed successfully"
                        break
                    }
                }
            }
        } -ArgumentList $logPath
        
        # Download Office sources
        Write-Status "Downloading Office sources for language: $Lang" -Type Info
        $processStartTime = Get-Date
        $process = Start-Process -FilePath $Setup -ArgumentList "/download $configPath" -PassThru
        
        # Update progress while the process is running
        while (-not $process.HasExited) {
            $elapsedTime = (Get-Date) - $processStartTime
            $formattedTime = "{0:hh\:mm\:ss}" -f $elapsedTime
            
            # Get updates from the monitor job
            $jobOutput = Receive-Job -Job $monitorJob -ErrorAction SilentlyContinue
            
            if ($jobOutput) {
                $latestOutput = $jobOutput | Select-Object -Last 1
                Write-Progress -Activity "Downloading Office ($Lang)" -Status "Time elapsed: $formattedTime" -PercentComplete -1
                Write-Status "Office download progress: $latestOutput" -Type Info
            }
            else {
                Write-Progress -Activity "Downloading Office ($Lang)" -Status "Time elapsed: $formattedTime" -PercentComplete -1
            }
            
            Start-Sleep -Seconds 5
        }
        
        # Clean up the job
        Remove-Job -Job $monitorJob -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity "Downloading Office ($Lang)" -Completed
        
        # Verify download was successful
        $officeFiles = Get-ChildItem -Path $sourcesPath -Recurse -File -ErrorAction SilentlyContinue
        if (-not $officeFiles -or $officeFiles.Count -eq 0) {
            throw "Office download completed but no files were found"
        }
        
        $totalSize = [math]::Round(($officeFiles | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
        Write-Status "Downloaded Office sources successfully ($totalSize GB)" -Type Success
        
        return $true
    }
    catch {
        Write-Status "Failed to download Office sources: $_" -Type Error
        return $false
    }
}

function Copy-OfficeToUSB {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory = $false)]
        [string]$ForcedLanguage
    )
    
    try {
        # Find all available drives with OSDCloud folders
        Write-Status "Looking for OSDCloud USB drive..." -Type Info
        $osdcloudDrives = Get-Volume | 
        Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Removable' } | 
        ForEach-Object {
            $driveLetter = $_.DriveLetter
            $drivePath = "${driveLetter}:"
            $osdCloudPath = Join-Path $drivePath "OSDCloud"
                
            if (Test-Path $osdCloudPath) {
                [PSCustomObject]@{
                    DriveLetter  = $driveLetter
                    Path         = $drivePath
                    OSDCloudPath = $osdCloudPath
                    FriendlyName = $_.FileSystemLabel
                }
            }
        }
            
        # If no OSDCloud drive was found by type, look for any drive with OSDCloud folder
        if (-not $osdcloudDrives) {
            Write-Status "No removable drive with OSDCloud folder found, checking all drives..." -Type Info
            $osdcloudDrives = Get-Volume | 
            Where-Object { $_.DriveLetter } |
            ForEach-Object {
                $driveLetter = $_.DriveLetter
                $drivePath = "${driveLetter}:"
                $osdCloudPath = Join-Path $drivePath "OSDCloud"
                    
                if (Test-Path $osdCloudPath) {
                    [PSCustomObject]@{
                        DriveLetter  = $driveLetter
                        Path         = $drivePath
                        OSDCloudPath = $osdCloudPath
                        FriendlyName = $_.FileSystemLabel
                    }
                }
            }
        }
        
        # If still no OSDCloud drive found, try Get-USBDrive as fallback
        if (-not $osdcloudDrives) {
            $usbDrive = Get-USBDrive
            if ($usbDrive -and $usbDrive.DriveLetter) {
                $drivePath = "${$usbDrive.DriveLetter}:"
                $osdCloudPath = Join-Path $drivePath "OSDCloud"
                
                # Create OSDCloud folder if it doesn't exist
                if (-not (Test-Path $osdCloudPath)) {
                    Write-Status "Creating OSDCloud folder on USB drive..." -Type Info
                    New-Item -ItemType Directory -Path $osdCloudPath -Force | Out-Null
                }
                
                $osdcloudDrives = @([PSCustomObject]@{
                        DriveLetter  = $usbDrive.DriveLetter
                        Path         = $drivePath
                        OSDCloudPath = $osdCloudPath
                        FriendlyName = $usbDrive.Disk.FriendlyName
                    })
            }
        }
        
        # Check if we found any OSDCloud drives
        if (-not $osdcloudDrives -or $osdcloudDrives.Count -eq 0) {
            throw "No drive with OSDCloud folder could be found"
        }
        
        # Select the first drive with OSDCloud folder
        $selectedDrive = $osdcloudDrives | Select-Object -First 1
        Write-Status "Found OSDCloud folder on drive $($selectedDrive.DriveLetter): ($($selectedDrive.Path))" -Type Success
        
        # Set destination path
        $destPath = Join-Path $selectedDrive.OSDCloudPath "Office"
        
        # Create destination directory
        if (-not (Test-Path $destPath)) {
            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
        }
        
        # Create language indicator file if needed
        if ($ForcedLanguage) {
            $languageFile = Join-Path $destPath "language.txt"
            Set-Content -Path $languageFile -Value $ForcedLanguage -Force
        }
        
        # Copy files
        Write-Status "Copying Office files to USB ($destPath)..." -Type Info
        Copy-Item -Path "$SourcePath\*" -Destination $destPath -Recurse -Force
        
        # Verify copy was successful
        $copiedFiles = Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue
        if (-not $copiedFiles -or $copiedFiles.Count -eq 0) {
            throw "File copy completed but no files were found at destination"
        }
        
        $totalSize = [math]::Round(($copiedFiles | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
        Write-Status "Copied Office files successfully ($totalSize GB)" -Type Success
        
        return $true
    }
    catch {
        Write-Status "Failed to copy Office files to USB: $_" -Type Error
        return $false
    }
}

function Test-ADKPrerequisites {
    <#
    .SYNOPSIS
        Tests if Windows ADK prerequisites are met
    .DESCRIPTION
        Checks if Windows ADK and Windows PE add-on are installed
    #>
    [CmdletBinding()]
    param()
    
    Write-TaskHeader "🧰 Checking Windows ADK Prerequisites"
    
    # Check Windows ADK installation
    $adkVersion = Get-AdkVersion
    
    if ($adkVersion) {
        Write-Status "Windows ADK is installed (Version: $adkVersion)" -Type Success
    }
    else {
        Write-Status "Windows ADK is not installed or not detected" -Type Warning
        
        $title = "Windows ADK Installation"
        $message = "Windows ADK and Windows PE add-on are required but not detected.`nDo you want to install them now?"
        $options = @(
            [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Install Windows ADK")
            [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Continue without installing")
            [System.Management.Automation.Host.ChoiceDescription]::new("&Cancel", "Exit script")
        )
        
        $result = $Host.UI.PromptForChoice($title, $message, $options, 0)
        
        switch ($result) {
            0 { 
                Install-ADKComponents
                $adkVersion = Get-AdkVersion
                if (-not $adkVersion) {
                    throw "Windows ADK installation failed or could not be verified. Cannot continue."
                }
            }
            1 { 
                Write-Status "Continuing without Windows ADK installation. Some features may not work properly." -Type Warning
            }
            2 { 
                throw "Operation cancelled by user. Windows ADK is required."
            }
        }
    }
    
    return $adkVersion
}
#endregion

function Show-CompletionDocumentation {
    [CmdletBinding()]
    param()
    
    Write-Host "`n" -NoNewline
    Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                      TCG OSDCLOUD USB DOCUMENTATION                      ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    Write-Host "`n📋 NEXT STEPS FOR IT ADMINISTRATORS:`n" -ForegroundColor Yellow
    
    # Driver Pack Instructions
    Write-Host "🔧 ADDING DRIVER PACKS FOR SPECIFIC HARDWARE MODELS:" -ForegroundColor Green
    Write-Host "   Run the following commands to add driver packages for your specific hardware:"
    Write-Host "   • Edit-TCGWinPE -BootWimPath <path\to\boot.wim> -DriverPaths @('C:\Drivers\Dell')" -ForegroundColor White
    Write-Host "   • Edit-TCGWinPE -BootWimPath <path\to\boot.wim> -DriverPaths @('C:\Drivers\HP')" -ForegroundColor White
    Write-Host "   • Edit-TCGWinPE -BootWimPath <path\to\boot.wim> -DriverPaths @('C:\Drivers\Lenovo')" -ForegroundColor White
    Write-Host "   • Edit-TCGWinPE -BootWimPath <path\to\boot.wim> -DriverPaths @('C:\Drivers')" -ForegroundColor White
    
    # Additional OS Images
    Write-Host "`n💿 ADDING ADDITIONAL OPERATING SYSTEMS:" -ForegroundColor Green
    Write-Host "   To add Windows 10 for offline deployment, run:"
    Write-Host "   • Update-TCGUSB -OSName 'Windows 10 22H2'" -ForegroundColor White
    
    # Testing and Verification
    Write-Host "`n🔍 TESTING AND VERIFICATION:" -ForegroundColor Green
    Write-Host "   1. Test your USB in a virtual machine first to verify functionality"
    Write-Host "   2. Verify that your device boots from the USB properly in UEFI mode"
    Write-Host "   3. Test Autopilot registration and OS deployment on a test device"
    
    # Custom Scripts
    Write-Host "`n📜 CUSTOMIZING DEPLOYMENT SCRIPTS:" -ForegroundColor Green
    Write-Host "   • Custom scripts are stored in the Scripts folder on your USB drive"
    Write-Host "   • You can customize the StartNet scripts to modify the WinPE experience"
    Write-Host "   • You can customize the SetupComplete scripts to modify the post-deployment experience"
    
    # Office Deployment
    Write-Host "`n📊 OFFICE DEPLOYMENT:" -ForegroundColor Green
    Write-Host "   • Office sources have been added to the USB drive"
    Write-Host "   • Office will be installed using the language of the OS selected"
    
    # Troubleshooting
    Write-Host "`n🛠️ TROUBLESHOOTING:" -ForegroundColor Green
    Write-Host "   • During OS deployment, press F10 to access the technical overlay view"
    Write-Host "   • Logs for USB creation are saved in: $($script:Config.Paths.Logs)"
    
    Write-Host "`n" -NoNewline
    Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                           USB CREATION COMPLETE                          ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

#region Main Script Execution
try {
    Write-TaskHeader "🚀 TCGCloud USB Setup"
    Write-Status "Starting TCGCloud USB creation process" -Type Info
    
    # Initialize environment
    Write-Status "Setting up working directories" -Type Info
    if (-not (Initialize-Environment)) {
        throw "Failed to initialize environment"
    }
    
    # Install prerequisites
    Write-Status "Checking prerequisites" -Type Info
    if (-not (Install-Prerequisites)) {
        throw "Failed to install prerequisites"
    }
    
    # Module Verification
    Write-TaskHeader "TCGCloud Module Verification"
    Write-Status "Checking TCGCloud module installation" -Type Info
    $tcgModule = Get-Module -Name TCGCloud -ErrorAction SilentlyContinue
    if (-not $tcgModule) {
        Write-Status "TCGCloud module is not loaded — attempting re-import" -Type Warning
        $tcgModulePath = Join-Path $PSScriptRoot 'Scripts\Modules\TCGCloud\TCGCloud.psd1'
        if (Test-Path $tcgModulePath) {
            Import-Module $tcgModulePath -Force -ErrorAction Stop
            Write-Status "TCGCloud module loaded" -Type Success
        }
        else {
            throw "TCGCloud module not found at: $tcgModulePath"
        }
    }
    else {
        Write-Status "TCGCloud module version $($tcgModule.Version) is loaded" -Type Success
    }

    # Install ADK components
    Write-TaskHeader "🔧 Windows ADK Components"
    Write-Status "Checking ADK installation status" -Type Info
    
    # Use a safer ADK check method that doesn't rely on Get-AdkVersion
    $adkInstalled = $false
    $adkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
    $deploymentToolsPath = Join-Path $adkPath "Deployment Tools"
    $winPEPath = Join-Path $adkPath "Windows Preinstallation Environment"
    
    if (Test-Path $deploymentToolsPath) {
        $adkInstalled = $true
        Write-Status "ADK Deployment Tools found at $deploymentToolsPath" -Type Success
        
        if (Test-Path $winPEPath) {
            Write-Status "WinPE components found at $winPEPath" -Type Success
            Write-Status "Using existing Windows ADK installation" -Type Success
        }
        else {
            Write-Status "WinPE components not found, will install" -Type Warning
            if (-not (Install-WinPEOnly)) {
                throw "Failed to install WinPE components"
            }
        }
    }
    else {
        Write-Status "Windows ADK not found, will install" -Type Info
        if (-not (Install-ADKComponents)) {
            throw "Failed to install ADK components"
        }
    }
    
    # Workspace and custom configuration
    Write-TaskHeader "📂 TCGCloud Workspace"
    
    # Check for TCGCloud template
    Write-Status "Checking for TCGCloud template" -Type Info
    
    try {
        $templatePath = Get-TCGTemplate -Name 'TCGCloud'
        
        if ($templatePath) {
            Write-Status "Found TCGCloud template at: $templatePath" -Type Success
        }
        else {
            Write-Status "Creating TCGCloud template" -Type Info
            $templatePath = New-TCGTemplate -Name 'TCGCloud'
            if ($templatePath) {
                Write-Status "TCGCloud template created at: $templatePath" -Type Success
            }
        }
    }
    catch {
        Write-Status "Error checking TCGCloud template: $_" -Type Warning
        Write-Status "Creating TCGCloud template" -Type Info
        
        try {
            $templatePath = New-TCGTemplate -Name 'TCGCloud'
            if ($templatePath) {
                Write-Status "TCGCloud template created at: $templatePath" -Type Success
            }
            else {
                Write-Status "Failed to create TCGCloud template" -Type Error
                Write-Status "Will continue without template" -Type Warning
            }
        }
        catch {
            Write-Status "Failed to create TCGCloud template: $_" -Type Error
            Write-Status "Will continue without template" -Type Warning
        }
    }

    # Check for existing workspace
    $workspacePath = Join-Path $WorkingDirectory "Media"
    $hasValidWorkspace = $false

    # More thorough check for valid workspace - check for key TCGCloud files/folders
    if (Test-Path $workspacePath) {
        # Check for essential TCGCloud workspace components
        $requiredPaths = @(
            (Join-Path $workspacePath "sources\boot.wim"),
            (Join-Path $workspacePath "EFI"),
            (Join-Path $workspacePath "OSDCloud")
        )
        
        $hasValidWorkspace = ($requiredPaths | Where-Object { -not (Test-Path $_) }).Count -eq 0
    }

    $recreateWorkspace = $true
    
    if ($hasValidWorkspace) {
        Write-Status "Existing workspace found" -Type Info
        $title = "Existing Workspace"
        $question = "Workspace found. Recreate it?"
        $choices = @(
            [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Delete and recreate"),
            [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Keep existing workspace")
        )
        $decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
        $recreateWorkspace = ($decision -eq 0)
    }
    else {
        Write-Status "No valid workspace found or workspace is incomplete - will create new one" -Type Info
    }
    
    if ($recreateWorkspace) {
        Write-Status "Creating workspace from template" -Type Info
        
        try {
            $wsResult = New-TCGWorkspace -WorkspacePath $WorkingDirectory -TemplateName 'TCGCloud'
            if ($wsResult) {
                Write-Status "Workspace created successfully" -Type Success
            }
            else {
                Write-Status "Failed to create workspace" -Type Error
                Write-Status "Will attempt to continue with USB creation anyway" -Type Warning
            }
        }
        catch {
            Write-Status "Failed to create workspace: $_" -Type Error
            Write-Status "Will attempt to continue with USB creation anyway" -Type Warning
        }
    }
    else {
        Write-Status "Using existing workspace" -Type Success
    }
    
    # Copy custom scripts if available
    if (-not $PSScriptRoot) {
        $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    
    $scriptsSource = Join-Path $PSScriptRoot "Scripts"
    $scriptsDestination = Join-Path $WorkingDirectory "Config\Scripts"
    
    Write-Status "Checking for custom scripts" -Type Info
    if (-not (Test-Path $scriptsSource)) {
        Write-Status "Custom scripts folder not found at $scriptsSource" -Type Warning
    }
    else {
        $sourceFiles = Get-ChildItem -Path $scriptsSource -Recurse
        Write-Status "Found $($sourceFiles.Count) files in custom scripts folder" -Type Info
        
        try {
            # Copy to Config\Scripts
            if (Test-Path $scriptsDestination) { Remove-Item -Path $scriptsDestination -Recurse -Force }
            New-Item -ItemType Directory -Path $scriptsDestination -Force | Out-Null
            Copy-Item -Path "$scriptsSource\*" -Destination $scriptsDestination -Recurse -Force

            # Also copy to direct Scripts folder for redundancy
            $directScriptsPath = Join-Path $WorkingDirectory "Scripts"
            if (Test-Path $directScriptsPath) { Remove-Item -Path $directScriptsPath -Recurse -Force }
            New-Item -ItemType Directory -Path $directScriptsPath -Force | Out-Null
            Copy-Item -Path "$scriptsSource\*" -Destination $directScriptsPath -Recurse -Force

            Write-Status "Custom scripts copied successfully" -Type Success
        }
        catch {
            Write-Status "Failed to copy custom scripts: $_" -Type Warning
        }
    }
    
    # USB Media Creation
    Write-TaskHeader "💿 USB Media Creation"
    Write-Status "Checking for USB drive" -Type Info

    # Try to find USB drive
    $usbDrive = Get-USBDrive
    $maxAttempts = 3
    $currentAttempt = 1
    
    while (-not $usbDrive -and $currentAttempt -le $maxAttempts) {
        Write-Status "No suitable USB drive found (attempt $currentAttempt of $maxAttempts)" -Type Warning
        
        # Show connected disks for debugging
        try {
            $allDisks = Get-Disk -ErrorAction SilentlyContinue
            $connectedDisks = $allDisks | Where-Object { $_.BusType -ne 'Virtual' -and $_.OperationalStatus -eq 'Online' }
            
            if ($connectedDisks) {
                Write-Status "Connected physical disks:" -Type Info
                foreach ($disk in $connectedDisks) {
                    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
                    $busType = $disk.BusType
                    Write-Status "  - Disk $($disk.Number): $($disk.FriendlyName) ($sizeGB GB, $busType)" -Type Info
                }
            }
        }
        catch {
            Write-Status "Error listing disks: $_" -Type Error
        }
        
        # Try alternative detection method using WMI
        try {
            $wmiDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue | 
            Where-Object { $_.InterfaceType -eq 'USB' }
                
            if ($wmiDisks) {
                Write-Status "USB drives found via WMI:" -Type Info
                foreach ($disk in $wmiDisks) {
                    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
                    Write-Status "  - $($disk.DeviceID): $($disk.Model) ($sizeGB GB)" -Type Info
                }
            }
        }
        catch {
            Write-Status "Error listing WMI disks: $_" -Type Error
        }
        
        Write-Host "`nPlease insert a USB drive (minimum 8GB, maximum 256GB) and press Enter to continue..."
        Write-Host "Press Ctrl+C to cancel the operation`n"
        
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Status "Scanning for USB drives..." -Type Info
        Start-Sleep -Seconds 3  # Give Windows more time to recognize the drive
        $usbDrive = Get-USBDrive
        $currentAttempt++
    }
    
    if (-not $usbDrive) {
        throw "Unable to find a suitable USB drive after $maxAttempts attempts. Please ensure a USB drive is connected and try again."
    }
    
    # Use the TCGCloud module to format and populate the USB drive
    Write-Status "Preparing USB media" -Type Info
    
    $usbResult = New-TCGUSB -WorkspacePath $script:Config.Paths.Working -DiskNumber $usbDrive.Disk.Number -Force
    if (-not $usbResult.Success) {
        throw "Failed to create TCGCloud USB: check above output for details"
    }
    $usbDriveLetter = $usbResult.DriveLetter
    Write-Status "USB drive prepared on $usbDriveLetter`:" -Type Success
    
    # Customize WinPE environment
    Write-Status "Customizing WinPE environment" -Type Info
    $bootWimPath  = Join-Path $script:Config.Paths.Working "Media\sources\boot.wim"
    $wallpaperPath = Join-Path $WorkingDirectory "Config\Scripts\Custom\wallpaper.jpg"
    $driversPath  = Join-Path $WorkingDirectory "Drivers"
    
    $editParams = @{
        BootWimPath     = $bootWimPath
        WirelessConnect = $true
        CloudDriver     = '*'
        UpdateUSB       = $usbDriveLetter
    }
    if (Test-Path $wallpaperPath) { $editParams['Wallpaper'] = $wallpaperPath }
    if (Test-Path $driversPath)   { $editParams['DriverPaths'] = @($driversPath) }
    
    $editResult = Edit-TCGWinPE @editParams
    if (-not $editResult) {
        Write-Status "WinPE customization reported an issue — USB may still be usable" -Type Warning
    }
    
    Write-Status "USB media created successfully" -Type Success
    
    # OS Selection and Installation
    if (-not $NoOS) {
        Write-TaskHeader "🖥️ Operating System Selection"
        $osLog = Join-Path $script:Config.Paths.Logs "os_installation.log"
        
        if ($OSName) {
            # Specific OS name provided
            Write-Status "Adding specified OS: $OSName" -Type Info
            
            try {
                $osUpdateResult = Update-TCGUSB -OSName $OSName -OSActivation Volume -USBPath "${usbDriveLetter}:"
                if ($osUpdateResult.Success) {
                    Write-Status "Operating system added successfully" -Type Success
                }
                else {
                    Write-Status "OS update reported a non-success result — continuing" -Type Warning
                }
                
                # Use the specified language
                $languageCode = $OSLanguage
            }
            catch {
                Write-Status "Error adding OS '$OSName': $_ — continuing with USB setup" -Type Warning
                $languageCode = $OSLanguage
            }
        }
        else {
            # No specific OS, use default
            Write-Status "Adding Windows 11 24H2" -Type Info
            
            try {
                $osUpdateResult = Update-TCGUSB -OSName "Windows 11 24H2" -OSActivation Volume -USBPath "${usbDriveLetter}:"
                if ($osUpdateResult.Success) {
                    Write-Status "OS selection complete" -Type Success
                }
                else {
                    Write-Status "OS update reported a non-success result — continuing" -Type Warning
                }
                    
                # Try to detect the OS language from files on the USB
                $osFiles = $null
                $drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C' }
                
                foreach ($drive in $drives) {
                    $driveLetter = $drive.DriveLetter
                    $osPath = "${driveLetter}:\OSDCloud\OS"
                        
                    if (Test-Path $osPath) {
                        $osFiles = Get-ChildItem -Path $osPath -Include "*.esd", "*.wim", "*.iso" -Recurse -ErrorAction SilentlyContinue
                        if ($osFiles -and $osFiles.Count -gt 0) {
                            break
                        }
                    }
                }
                    
                if ($osFiles -and $osFiles.Count -gt 0) {
                    $selectedOSFile = $osFiles | Select-Object -First 1
                    $languageCode = Extract-LanguageCode -OSFileName $selectedOSFile.Name
                    
                    Write-Status "Detected OS language: $languageCode" -Type Info
                    
                    # Log the detection
                    $logContent = "OS Detected: $($selectedOSFile.Name)`nLanguage Code: $languageCode`nDate: $(Get-Date)"
                    $logContent | Out-File -FilePath (Join-Path $script:Config.Paths.Logs "language-detection.log") -Force
                }
                else {
                    $languageCode = $OSLanguage
                    Write-Status "Could not detect OS language, using default: $languageCode" -Type Warning
                }
            }
            catch {
                Write-Status "Error adding OS: $_ — continuing with USB setup" -Type Warning
                $languageCode = $OSLanguage
            }
        }
        
        # Download and add Office sources
        Write-TaskHeader "📊 Microsoft Office Setup"
        Write-Status "Preparing to download Office for language: $languageCode" -Type Info
        
        $officeWorkingDir = Join-Path $WorkingDirectory "OfficeSetup"
        New-RequiredDirectory -Path $officeWorkingDir | Out-Null
        
        try {
            # Get ODT setup
            $odtSetupPath = Test-ODT -Path (Join-Path $officeWorkingDir "ODT")
            if (-not $odtSetupPath) {
                throw "Failed to set up Office Deployment Tool"
            }
                        
            # Download Office sources
            $officeSuccess = Download-OfficeSources -Setup $odtSetupPath -Path $officeWorkingDir -Lang $languageCode
                        
            if ($officeSuccess) {
                # Verify Office sources
                $officeSources = Join-Path $officeWorkingDir "OfficeSources"
                $officeFiles = Get-ChildItem -Path $officeSources -Recurse -ErrorAction SilentlyContinue
                            
                if ($officeFiles -and $officeFiles.Count -gt 0) {
                    # Copy to USB
                    Write-Status "Copying Office sources to USB..." -Type Info
                    $copyResult = Copy-OfficeToUSB -SourcePath $officeSources -ForcedLanguage $languageCode
                                
                    if ($copyResult) {
                        Write-Status "Office sources successfully added to USB" -Type Success
                    }
                    else {
                        Write-Status "Failed to copy Office sources to USB" -Type Error
                    }
                }
                else {
                    Write-Status "Office download appears to have failed - no files found" -Type Error
                }
            }
            else {
                Write-Status "Failed to download Office sources" -Type Error
            }
        }
        catch {
            Write-Status "Error setting up Office: $_" -Type Error
        }
    }
    # Show documentation for next steps
    Show-CompletionDocumentation
}
catch {
    Write-Host "`nError occurred during execution!" -ForegroundColor Red
    Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Error Type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
    Write-Host "Command: $($_.InvocationInfo.MyCommand)" -ForegroundColor Red
    Write-Host "Line Number: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "Stack Trace:`n$($_.ScriptStackTrace)" -ForegroundColor Red
    $_ | Format-List * -Force | Out-String | Write-Host -ForegroundColor Red
}
finally {
    # Suppress specific non-critical errors
    $suppressedErrors = @(
        "*We did not find any results for*",
        "*Cannot validate argument on parameter 'Uri'*",
        "*The argument is null or empty*"
    )
    
    # Filter out suppressed errors if they exist
    if ($Error.Count -gt 0) {
        $remainingErrors = $Error | Where-Object { 
            $currentError = $_
            -not ($suppressedErrors | Where-Object { $currentError -like $_ })
        }
        
        if ($remainingErrors.Count -gt 0) {
            Write-Host "`n❌ Script encountered errors:" -ForegroundColor Red
            foreach ($err in $remainingErrors) { 
                Write-Host "- $($err.Exception.Message)" -ForegroundColor DarkRed 
            }
        }
        else {
            Write-Host "`n✅ Script completed successfully" -ForegroundColor Green
        }
    }
    
    try { 
        Stop-Transcript -ErrorAction SilentlyContinue 
    } 
    catch { }
}
#endregion
# SIG # Begin signature block
# MII6mwYJKoZIhvcNAQcCoII6jDCCOogCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAv/B9sVyjv66J0
# V6ayYteNNagu1lPiAeMbuCVxErFcWaCCIsAwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggb0MIIE3KADAgECAhMzAAJ1DuX9
# 5lGRvYLpAAAAAnUOMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDEwHhcNMjUwNDE2MDUzMTE5WhcNMjUwNDE5
# MDUzMTE5WjBxMQ8wDQYDVQQREwY0MTEgMTcxCzAJBgNVBAYTAlNFMRMwEQYDVQQH
# EwpHb3RoZW5idXJnMRYwFAYDVQQJEw1LdW5nc3RvcmdldCA3MREwDwYDVQQKEwhY
# ZW5pdCBBQjERMA8GA1UEAxMIWGVuaXQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCsDyI1bGPlU40mc55l9eUkzqHv1F2wpqpXQHrdvMPb8MiamBtN
# jZ2nZqTLlR0xuyKxC8o1hGwTXRauLN3dDaCMH7p7oP5TpliTdjRPQN2vLHgA8tuW
# Ne3Dkz0QsW142DSzQnHxsY3/FfTJ+EtLXrWiAq8IR5ihe0wcUAmC8vv22A9JBYIt
# oE5tTkM0MeFCbDcY54CiF+/CDTWah/FysLf2CewwDA4152nwZPPJNZYDQ+kDvt1I
# 8JFUm6Tctl2DAQcJ5ekd9LnkwI1LKOEf3j4F0xFm1L0CrNVyotQaYQDf/frViZaV
# zqsxQ8iQhC/vIlwDuKDdGl/TvUKnFbKG8tf/Ob5kI591Mt8ml5WPiFkDUSqNHpLV
# B30cBM0kVVIPgcEhkoz9Uv8xftETtiOViYnPFXVDLnJ/SccVX6XZX/ODL9Ne41GO
# E2kft2CLmEv/OmS62+nN4I8QY1uLTUuN0wczoe7Zryi0P6e04iE04A70yxc5K8VX
# I74ubAAHwg1wTUsCAwEAAaOCAhowggIWMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/
# BAQDAgeAMD0GA1UdJQQ2MDQGCisGAQQBgjdhAQAGCCsGAQUFBwMDBhwrBgEEAYI3
# YYO10YN2g7mJmUuC4IHDfoLmr91jMB0GA1UdDgQWBBQUwYywKeobbXCI7pKtZOSC
# luRjdjAfBgNVHSMEGDAWgBR2nDZ0E9GQfWFfswLrgPSZS6U+hTBnBgNVHR8EYDBe
# MFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAxLmNybDCB
# pQYIKwYBBQUHAQEEgZgwgZUwZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMS5jcnQwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVv
# Y3NwLm1pY3Jvc29mdC5jb20vb2NzcDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30B
# ATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQBMA0GCSqGSIb3DQEBDAUAA4IC
# AQBQdPGQavI+a5AMyIBNtPxtHwygPSSfE2ZVIuml4W5kamSUyXCa6YMPgKaCHM1m
# VtjCv20DcsOefIuzbkpIi34tuqi/iSPH14kwsWGkEeFtFS6fohdFOLKdv/pe2vUy
# LeTEZYWEWYGFSqSqofxw8RKPqx3+zhjkm+BRqITHBtRO/A/dg+N8zj5Ld0v4fVRB
# xaeH7lHZOb3HD+r3ir+D9ZHn2YFxuUnkLC6J+2DHLeFwLjUBqZnK/ffaGcNWNrKJ
# RcLd+9cPKdJNZXJ+5WTw7+K1OmR/Zf5JJhnD7kSmZYBbqNF3JKxfWVjjkSPrRvkr
# 0waBW3PWVQuFBoIcvpP2bFZWNVbL8eZkxD9QQuCBDRvrFMapkj+xyhW83AXeN0vH
# v52zz56KBS7T+xdQnI63uaLyg8avBV3xDOaNpFu9TX4LI/RKuyvLMOqDKyktJI4X
# Izb84P/ngzbK8JxyXbV26sdDYmQtDReObgQxNPOUWqDIjtK/nkD8qbukjnnNcLdn
# wC7n9KurPYOkJkBbDVbNokg2ME0UJUzL9hNlnZFcG4BNUKB0yBXSCqtX2e0G/gz/
# zh8GSwpy1Pr6e0s5zHgjo6AFaJeSzbrI9LPhSpJ6tQpRXCeQ5UrHhmnh0X89ZFKe
# 2RwvhhQGV74qsdXujasgovoLE1tX+upCGS0mzliBPnlB/jCCBvQwggTcoAMCAQIC
# EzMAAnUO5f3mUZG9gukAAAACdQ4wDQYJKoZIhvcNAQEMBQAwWjELMAkGA1UEBhMC
# VVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjErMCkGA1UEAxMiTWlj
# cm9zb2Z0IElEIFZlcmlmaWVkIENTIEVPQyBDQSAwMTAeFw0yNTA0MTYwNTMxMTla
# Fw0yNTA0MTkwNTMxMTlaMHExDzANBgNVBBETBjQxMSAxNzELMAkGA1UEBhMCU0Ux
# EzARBgNVBAcTCkdvdGhlbmJ1cmcxFjAUBgNVBAkTDUt1bmdzdG9yZ2V0IDcxETAP
# BgNVBAoTCFhlbml0IEFCMREwDwYDVQQDEwhYZW5pdCBBQjCCAaIwDQYJKoZIhvcN
# AQEBBQADggGPADCCAYoCggGBAKwPIjVsY+VTjSZznmX15STOoe/UXbCmqldAet28
# w9vwyJqYG02NnadmpMuVHTG7IrELyjWEbBNdFq4s3d0NoIwfunug/lOmWJN2NE9A
# 3a8seADy25Y17cOTPRCxbXjYNLNCcfGxjf8V9Mn4S0tetaICrwhHmKF7TBxQCYLy
# +/bYD0kFgi2gTm1OQzQx4UJsNxjngKIX78INNZqH8XKwt/YJ7DAMDjXnafBk88k1
# lgND6QO+3UjwkVSbpNy2XYMBBwnl6R30ueTAjUso4R/ePgXTEWbUvQKs1XKi1Bph
# AN/9+tWJlpXOqzFDyJCEL+8iXAO4oN0aX9O9QqcVsoby1/85vmQjn3Uy3yaXlY+I
# WQNRKo0ektUHfRwEzSRVUg+BwSGSjP1S/zF+0RO2I5WJic8VdUMucn9JxxVfpdlf
# 84Mv017jUY4TaR+3YIuYS/86ZLrb6c3gjxBjW4tNS43TBzOh7tmvKLQ/p7TiITTg
# DvTLFzkrxVcjvi5sAAfCDXBNSwIDAQABo4ICGjCCAhYwDAYDVR0TAQH/BAIwADAO
# BgNVHQ8BAf8EBAMCB4AwPQYDVR0lBDYwNAYKKwYBBAGCN2EBAAYIKwYBBQUHAwMG
# HCsGAQQBgjdhg7XRg3aDuYmZS4LggcN+guav3WMwHQYDVR0OBBYEFBTBjLAp6htt
# cIjukq1k5IKW5GN2MB8GA1UdIwQYMBaAFHacNnQT0ZB9YV+zAuuA9JlLpT6FMGcG
# A1UdHwRgMF4wXKBaoFiGVmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIw
# MDEuY3JsMIGlBggrBgEFBQcBAQSBmDCBlTBkBggrBgEFBQcwAoZYaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZl
# cmlmaWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAxLmNydDAtBggrBgEFBQcwAYYhaHR0
# cDovL29uZW9jc3AubWljcm9zb2Z0LmNvbS9vY3NwMGYGA1UdIARfMF0wUQYMKwYB
# BAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAEwDQYJKoZIhvcN
# AQEMBQADggIBAFB08ZBq8j5rkAzIgE20/G0fDKA9JJ8TZlUi6aXhbmRqZJTJcJrp
# gw+ApoIczWZW2MK/bQNyw558i7NuSkiLfi26qL+JI8fXiTCxYaQR4W0VLp+iF0U4
# sp2/+l7a9TIt5MRlhYRZgYVKpKqh/HDxEo+rHf7OGOSb4FGohMcG1E78D92D43zO
# Pkt3S/h9VEHFp4fuUdk5vccP6veKv4P1kefZgXG5SeQsLon7YMct4XAuNQGpmcr9
# 99oZw1Y2solFwt371w8p0k1lcn7lZPDv4rU6ZH9l/kkmGcPuRKZlgFuo0XckrF9Z
# WOORI+tG+SvTBoFbc9ZVC4UGghy+k/ZsVlY1Vsvx5mTEP1BC4IENG+sUxqmSP7HK
# FbzcBd43S8e/nbPPnooFLtP7F1Ccjre5ovKDxq8FXfEM5o2kW71Nfgsj9Eq7K8sw
# 6oMrKS0kjhcjNvzg/+eDNsrwnHJdtXbqx0NiZC0NF45uBDE085RaoMiO0r+eQPyp
# u6SOec1wt2fALuf0q6s9g6QmQFsNVs2iSDYwTRQlTMv2E2WdkVwbgE1QoHTIFdIK
# q1fZ7Qb+DP/OHwZLCnLU+vp7SznMeCOjoAVol5LNusj0s+FKknq1ClFcJ5DlSseG
# aeHRfz1kUp7ZHC+GFAZXviqx1e6NqyCi+gsTW1f66kIZLSbOWIE+eUH+MIIHWjCC
# BUKgAwIBAgITMwAAAAZKGvrPBWFqdAAAAAAABjANBgkqhkiG9w0BAQwFADBjMQsw
# CQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTQwMgYD
# VQQDEytNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ29kZSBTaWduaW5nIFBDQSAyMDIx
# MB4XDTIxMDQxMzE3MzE1NFoXDTI2MDQxMzE3MzE1NFowWjELMAkGA1UEBhMCVVMx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjErMCkGA1UEAxMiTWljcm9z
# b2Z0IElEIFZlcmlmaWVkIENTIEVPQyBDQSAwMTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAMfjyD/0Id3GGcC7xcurrieH06d5Z+xqrO7PJU1cn4DiVj9W
# gAcJNv6MXVY30h1KuDEz14pS+e6ov3x+2J3RCuCp3d7uXHnRcK9mh0k6er5fzy9X
# QC/bH6A7zaXRtDf0fOAIWDaQUE4aTuPwasZgoJd4iEX4YdqBVTrok4g1Vr1wYO+m
# 3I5x5xBLV87wFsCbtGwVO6EUakHneFVybSAlbfmaClEo6mOcFJYQHcB4ft9QZ6QT
# wsxbSlYi6esxLUcjsUXoGoBVPsi4F775ndOyAzdEtky2LomY08PpHGDraDYCq+5N
# AuhPVn9x+Ix2r5NjMahabYHy9IC/s20m/lQTSolU9Jqs1ySCZlpqsNCvg9zCn5gn
# q93twm6z/heUbQm9F2hNLkXCT2SY1sHIgwcQSG5DReBi9doZeb8nYBTJs0HDbqHS
# sl//95Sydattq6B1UtXILbC4KY1mGZQZYQk3FyXmd8bmib12Qfa3Cwl9eToFy9tb
# VFMCQixNu1eQBmcZDt4ueJoEgrMLTpllOACnfwf3tyrV7+lwVESrgLXns9RKYJaG
# mcEHo/ZeXTfVIfFtfQWYPSJS5fsR0V+Lw4jFgFH/+wDXuDKEvfBeOa++iBidIQtN
# hDLjGcQBK8GY9JZ9Gi+dxM5TGuSQokTm29FKCx3xknTSbDINLo9wwEA3VVkxAgMB
# AAGjggIOMIICCjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFHacNnQT0ZB9YV+zAuuA9JlLpT6FMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTZQSmwDw9jbO9p1/XNKZ6kSGow
# 5jBwBgNVHR8EaTBnMGWgY6Bhhl9odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25p
# bmclMjBQQ0ElMjAyMDIxLmNybDCBrgYIKwYBBQUHAQEEgaEwgZ4wbQYIKwYBBQUH
# MAKGYWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9z
# b2Z0JTIwSUQlMjBWZXJpZmllZCUyMENvZGUlMjBTaWduaW5nJTIwUENBJTIwMjAy
# MS5jcnQwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20v
# b2NzcDANBgkqhkiG9w0BAQwFAAOCAgEAai8Jn9iwdUI1IGtBu8xZGxnfDQUCxz9C
# jhQVjSRWYk7Sn6TtG2dln7Or+b6iCoxN9kOjPPRuGZFXL1rhAAPnb4y04UsvPWNP
# /5v1k0isGLYkdRMJ+8dZMPxYPd8EKbNgtVlI/tNP+rjaxfneDFScVdR6ASA/veWS
# FtCpKmaKZzgOMObz+E+XAaa2UAJT/7zBsgdB/fqRzaNI0/UPIHyiTcx0vYtQ4AZp
# rnxnVvUwcrp6PBgIsxTIS5SLNPG+ZYpSJBOc9xTAFAK/l4CCNRTWZ2+NziOkHdsz
# oo242H7q7F1AjRwvkUsCRpuVC8z8pmIIJyfpISTqu6EpajxqW6+9IRgXj8Pye/5p
# kqqe4U4LdJj4pEtYuGqfMfj98npmEoZxa4Fde+dkyPgLOvS34C7YZCE73+2xRwfL
# 5iIWnWQjktL0wsdwfvzlXBDCzTtmydDvYpHNSakdBb6se5wMDEUodxVaqLIMwW1p
# 1ZECau6FhcDFXxSGJ+iz0WTLePLuojFAhQUj3XbDwP+pPOZhL/tPFOVgkO8nY9Sl
# Vdkx63v/Jix4npvcH/ws6IakZ7cTNhP8fjR8ukwTJ0j0EaoYTX7joFAwFhGJpTP2
# RxmjyG+8Tr31ci0P+5emH6IE93qbcKeBjhkYx+c/oBvZKQSMfEK0ZejopZ5cURMa
# JJjH5S+5ddkwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1
# MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmll
# ZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2
# YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6
# EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxk
# P/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVO
# mRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qOb
# U4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaC
# qUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXe
# ghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGI
# x7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLf
# oAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83a
# bd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4IC
# NTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2
# MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUF
# BzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcN
# AQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB
# +eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQ
# kRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BR
# u/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtH
# o0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4V
# poq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4
# wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvF
# bbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95n
# HBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+
# mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyK
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIXMTCC
# Fy0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDAxAhMzAAJ1DuX95lGRvYLpAAAAAnUOMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIJ9Jpl+Q93AsO4zbBAYy2NXJrSnJWvmPoKkAT/1hgT2YMA0GCSqGSIb3
# DQEBAQUABIIBgIo3PE9jKd8Q1VWvO74uwzJay71KhD7QFivbqI11HN1mR8rw9mQp
# OYs3jyEl5+RC+j92VpnfMHtOyJm54BD2LepVz6kEh1h8Xz5+l0RF+CCrSoeQumqF
# UjbKEprjvKhVlu1TYRT0Xlc7fUIvx3sg1LCLXKD65C62mujgwyWzZYmpFcLnyjRJ
# GgoS4Sdkx/FKxnk7Sm8cDmROiv+pICecUOMH8aRMkoUDq5ccqzHawcK/CTAhu0Xb
# l08MEpiKbFksuj6TERCIizarh9WHzDOEvYWoLBieAzShbrEa2sRKNa1+cyMr4LGR
# B2CPls1YNYV8Xu/SFtQ4uxfqFEfwchQounqLWAPvJssN+x9sOIVPflre+pYWOnwL
# X1TSe3Eb8fNaJaGgt5l3TrQKbWusHndogYepkz/WzsJrRUuNl75jM53GAA+1FWRk
# H806t5kFV6JVN32AomxVsOvkVCzUVQYEaQu8PswMar5lnnx0erFNq+CaoTYoRePm
# DrBL6oqgFiQwBqGCFLEwghStBgorBgEEAYI3AwMBMYIUnTCCFJkGCSqGSIb3DQEH
# AqCCFIowghSGAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFpBgsqhkiG9w0BCRABBKCC
# AVgEggFUMIIBUAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD+Pifr
# KNQyBsYgu/VjFafFj/MNA64Eet2G74fijNE6EAIGZ+U34R1HGBIyMDI1MDQxNjA3
# NTMyMi42M1owBIACAfSggemkgeYwgeMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlv
# bnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQ1MUEtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaCCDykwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAF
# MA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJp
# ZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDEx
# MTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/
# sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8
# y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFP
# u6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR
# 4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi
# +dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+Mk
# euaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xG
# l57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eE
# purRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTe
# hawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxw
# jEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEA
# AaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+
# 0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRl
# bnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRo
# b3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedM
# eGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LY
# haa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nP
# ISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2c
# Io1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3
# xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag
# 1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK
# +KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88
# o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bq
# jN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8A
# DHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6J
# QivRepyvWcl+JYbYbBh7pmgAXVswggefMIIFh6ADAgECAhMzAAAAVD/yAD6+odim
# AAAAAABUMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MDIyNzE5NDAyN1oXDTI2MDIy
# NjE5NDAyN1owgeMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQ1MUEtMDVFMC1EOTQ3MTUwMwYDVQQD
# EyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK7Wnnjlw596igDzQ7R0X23v
# QVa+rXKNIACd35OP+MD1C7yApSmxTQ7rAHsBF66lxk+1pAU5q7UzaWOW7rFrkPVX
# hd9ZzcCQ+yXKgCwYEI7czsnqhyHV5rXJeN0nBS10c7xk54hOQi7JGn8MRm5jdW6U
# 7lMxJbmvr+rTkO7lqMe9DcnROD09MrK03VgGzNlvauMK9rpqK/hDUJHslgi8p9Uk
# BUeeRSZc+c9WcHzNFxBHv7jNB9ZPnaIrGmyBqvF13aSXQsA3OLJ5ErAW+tPoiAhe
# ApQuQlKH9lyLF0Hp+4Deyt7V+Z9a+4UiYNfMLEql964BFUqPgDm9icr8o0SUAgc4
# itc/+XZ6Qm4PouEPK6V89uopDSzwhlOxtehq1NlzS3/ncqlcdtD1r6uqKJSYyzr3
# 4z6QX+dAOQVrW+IFtVJA7xIosC6Uf3MT8mO6dr1PhGR8GV4NJ1/BQBXg83jYeK9E
# byi7UlGfXaGIm+n3rk5b2juIBBadcmhQnMlje6STwuCknheFu6UQ/ZULYxcX20I9
# Ri3rimB0noxDUsM2e3oNjCqjBSfZu4G5KRORl+8sERCowawabgRKcJKI05gFrSV2
# Axc0+NPFxJJcJGHTWXHmeyxUAHuW3Q2loSVfxsIsqZMGnhiQX4f8xtqR2+dJu9TK
# 1kuWDSKv7DKhSMHB98I7AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQU0mk2gtuzakAQ
# FqbmgXWAbmc3XdkwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYD
# VR0fBGUwYzBhoF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9j
# cmwvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0El
# MjAyMDIwLmNybDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGlj
# JTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8E
# AjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNV
# HSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EM
# AQQCMA0GCSqGSIb3DQEBDAUAA4ICAQBz2BTfhlJWlQFTmpmXmIPh9DhsKMmgE6am
# JWyc42zNMXE2KbKtBQCkcHFCoLTrBORt52psHmm0LMdUqExfPLzIgP7+vtyBi03B
# UkBTr0f1EcgMHwzY/8aWCO/dx5BStip/3YzwPLHebCao/vIHNspwvxmKZPnz68Bs
# l4Gbxtes8J7hIH9mabHUY/2jJ0yMGt7164AXaAgMgziO/D8ZR6vIpptKsAcLAlW0
# B+F64oFOVf5GhVYss86hD2QN+UK0nTP3snU4+rrWZAlxwaw2OsrU8AEyb7r6Wozb
# VwTxRNITSLrlimbU+L1jRMFf3kzfa/hOAqEGARW5pN4UOU+U6nFNp+4jpri1iSlG
# kna3+QZEpRLuzu5fnMNV8gNUBh0PMk0pq6lMEKgaqrm6sB2RVuG+O/1WJQAc8pt9
# EHH/owuZD6a4Q4NhVqUZXWqwzfuS+z6oT88qcUIom9AY0WDsMjA3c4nvULS6g95F
# NQxvnJhDhqxJEVef8452wETsRlYxYE+B64UPaYWBSzJCE2Oea55PSyzeBMBtsPl1
# hglmoo3yJKWOS3EBm6wouObjfjg0oy9kebPUcUzWs+5767NE8V/BrKOulvZWyT+q
# JgmRXCiQBVgb/y/uaCC8peyx0QQuoDsJ9VhnQ5cVl9+3yrdXYhj9ltlyd9m1Tlm4
# PVwBrkoOFDGCA9QwggPQAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBS
# U0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABUP/IAPr6h2KYAAAAAAFQwDQYJ
# YIZIAWUDBAIBBQCgggEtMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkq
# hkiG9w0BCQQxIgQgkoJvb1d2qvDGWdySJchJMn5hrtIp1i7wMMe3kqk/Hg0wgd0G
# CyqGSIb3DQEJEAIvMYHNMIHKMIHHMIGgBCDUgap6YlmYSW/WIF/+rbNjJEZNLqfc
# NECo7poQmEmwCzB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMAITMwAAAFQ/8gA+vqHYpgAAAAAAVDAiBCBwjfCI
# 6sQSTHxYwn1mGZexRVnEFz0aMNg8FCFes74F8zANBgkqhkiG9w0BAQsFAASCAgBt
# bhDQGEN3vlwizA5UHi/iy7uiGgesMm8B1OrGp1bPu//H8qPice7iL74sBPWAAsTI
# UCsyz/fbdgr3/OLPrkK2CfYDnstq5t6Y6h7k0a58LZMAtP3FVM35Tpzj1BE7D+4p
# NOKpPQtpWdzv/az7i4iwui/A+IAF3T8GokkAYK2WRnqwNP8zcHJpUuBy6I79aeyZ
# BymVq0MZNiB/0txjMteiCdhIyTERPwOYhMF1uMBU29OhZ0txY9+tKzJ9KZlbbuqL
# LmNCdiPLOxOrV9QIvtRPMdBLzJGQBJvs/7bwpc0o7FSLB5yg1hKQSfptd0hPaeMw
# VazsvAvDDxBjF/uAJV3VBvTm5nr2vwO9I1gn1JrxlIaYkNn4b0Bf6xFw9eR6y6Cb
# Uvsr7ZJ8tEzKjzewbaoisI3H1rYmMqtrOqYmxXn/r1iGf3+ORUAvAbtk8W/b8AXf
# a1s7j5ejenecz9nZC/nf1D1OM6UWir3gJDo5VAV0We6rzM41HYshA5JPJ/B42zJm
# HQvDVUa9FLC18wvX6toj3Z3990lxwSBqRJ3Y5T/BddsQ5hQioXa5UejY8WnkaKdM
# kPSKhrLYIuNfJdRNWlv3dUR4oMAEVCQCrmm86IftwoDVOguqbu3oPfW6j7M8uXu/
# ptItS/LjX1p2yPeejutuPtcWRp1dnK5PHZa0tQwDfw==
# SIG # End signature block
