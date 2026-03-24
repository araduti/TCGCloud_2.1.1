# ---------------------------------------------------------------------------
# Script-level constants — shared by Invoke-TCGDriverUpdate and helpers
# ---------------------------------------------------------------------------

# Minimum NuGet provider version required to install PSGallery modules
$script:NuGetMinVersion = '2.8.5.201'

# Dell Command Update CLI exit codes
$script:DcuExitSuccess   = 0    # Update(s) applied successfully
$script:DcuExitNoUpdates = 500  # No applicable updates found

# Windows Update COM API result codes (IInstallationResult.ResultCode)
$script:WuResultSucceeded           = 1  # All updates succeeded
$script:WuResultSucceededWithErrors = 2  # Some updates succeeded with errors

# ---------------------------------------------------------------------------
# Private helper — Windows Update COM API driver scan
# Called from the WU fallback and Surface paths inside Invoke-TCGDriverUpdate.
# ---------------------------------------------------------------------------
function _InvokeWindowsUpdateCOM {
    param([PSCustomObject]$Result)

    try {
        Write-Host 'OSDStatus: Scanning for driver updates via Windows Update COM API...' -ForegroundColor Cyan
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $found    = $searcher.Search("IsInstalled=0 AND Type='Driver'")

        if ($found.Updates.Count -gt 0) {
            Write-Host "Found $($found.Updates.Count) driver update(s) — downloading and installing..." -ForegroundColor Cyan
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $found.Updates) {
                Write-Host "  Queuing: $($u.Title)"
                $coll.Add($u) | Out-Null
            }
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $coll
            $dl.Download() | Out-Null

            $inst = $session.CreateUpdateInstaller()
            $inst.Updates = $coll
            $installResult = $inst.Install()
            $Result.Success = $installResult.ResultCode -in @(
                $script:WuResultSucceeded,
                $script:WuResultSucceededWithErrors
            )
            $Result.Message = "Windows Update COM driver install: result=$($installResult.ResultCode), reboot=$($installResult.RebootRequired)"
            Write-Host "OSDStatus: $($Result.Message)" -ForegroundColor Green
        }
        else {
            $Result.Success = $true
            $Result.Message = 'Windows Update COM: no driver updates found'
            Write-Host "OSDStatus: $($Result.Message)" -ForegroundColor Green
        }
    }
    catch {
        $Result.Message = "Windows Update COM error: $_"
        Write-Host "Warning — $($Result.Message)" -ForegroundColor Yellow
    }

    return $Result
}

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------
function Invoke-TCGDriverUpdate {
    <#
    .SYNOPSIS
        Installs the latest drivers for the current hardware using vendor-specific
        PowerShell cmdlets or CLI tools, on demand — no local driver packs required.
    .DESCRIPTION
        Detects the hardware manufacturer via WMI and dispatches to the appropriate
        provider tool:

          Dell     — Dell Command Update CLI (winget install Dell.CommandUpdate)
          HP       — HP Client Management Script Library (Install-Module HPCMSL)
          Lenovo   — LSUClient module (Install-Module LSUClient)
          Surface  — Windows Update via PSWindowsUpdate / COM fallback
          Other    — PSWindowsUpdate Driver category / COM API fallback

        All paths are non-fatal: failures are written to the host as warnings so
        that a driver-update error never blocks an otherwise successful deployment.

    .PARAMETER Manufacturer
        Override the auto-detected manufacturer string. Useful for testing.

    .PARAMETER LogPath
        Optional file path to append driver-update output to (in addition to the
        console). When omitted, output goes to the host only.

    .PARAMETER Force
        Skip the interactive confirmation prompt in non-ZTI callers (DCU and
        LSUClient paths) and proceed automatically.

    .OUTPUTS
        [PSCustomObject] with:
          Manufacturer [string]  — detected (or overridden) manufacturer
          Provider     [string]  — tool/module used
          Success      [bool]    — $true if the provider reported no errors
          Message      [string]  — human-readable summary

    .EXAMPLE
        Invoke-TCGDriverUpdate
    .EXAMPLE
        Invoke-TCGDriverUpdate -Manufacturer 'Lenovo' -Force -LogPath 'C:\Logs\drivers.log'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Manufacturer = '',

        [Parameter()]
        [string]$LogPath = '',

        [Parameter()]
        [switch]$Force
    )

    # -------------------------------------------------------------------------
    # Internal helpers
    # -------------------------------------------------------------------------
    function _DrvLog {
        param([string]$Message, [string]$Color = 'Cyan')
        Write-Host $Message -ForegroundColor $Color
        if ($LogPath) {
            Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" -ErrorAction SilentlyContinue
        }
    }

    function _EnsureModule {
        param([string]$Name)
        if (-not (Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue)) {
            _DrvLog "Installing module '$Name' from PSGallery..."
            try {
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
                        Where-Object { $_.Version -ge $script:NuGetMinVersion })) {
                    Install-PackageProvider -Name NuGet -MinimumVersion $script:NuGetMinVersion `
                        -Force -ErrorAction Stop | Out-Null
                }
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Module -Name $Name -Force -Scope AllUsers -ErrorAction Stop
            }
            catch {
                _DrvLog "Warning — could not install '$Name': $_" 'Yellow'
                return $false
            }
        }
        try {
            Import-Module -Name $Name -Force -ErrorAction Stop
            return $true
        }
        catch {
            _DrvLog "Warning — could not import '$Name': $_" 'Yellow'
            return $false
        }
    }

    # -------------------------------------------------------------------------
    # Manufacturer detection
    # -------------------------------------------------------------------------
    if (-not $Manufacturer) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $Manufacturer = $cs.Manufacturer
        }
        catch {
            try {
                $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
                $Manufacturer = $cs.Manufacturer
            }
            catch {
                $Manufacturer = 'Unknown'
            }
        }
    }

    _DrvLog "OSDStatus: Detected manufacturer: $Manufacturer"

    $result = [PSCustomObject]@{
        Manufacturer = $Manufacturer
        Provider     = 'Unknown'
        Success      = $false
        Message      = ''
    }

    # -------------------------------------------------------------------------
    # Dell — Dell Command Update CLI
    # -------------------------------------------------------------------------
    if ($Manufacturer -match 'Dell') {
        $result.Provider = 'DellCommandUpdate'
        _DrvLog 'OSDStatus: Using Dell Command Update for driver installation...'

        # Locate DCU CLI — check both default installation paths
        $dcuPaths = @(
            "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe"
            "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
        )
        $dcuCli = $dcuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $dcuCli) {
            _DrvLog 'Dell Command Update CLI not found — attempting install via winget...' 'Yellow'
            try {
                $winget = Get-Command winget -ErrorAction Stop
                & $winget install --id Dell.CommandUpdate --accept-source-agreements `
                    --accept-package-agreements --silent 2>&1 |
                    ForEach-Object { _DrvLog $_ }
                # Re-locate after install
                $dcuCli = $dcuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            }
            catch {
                _DrvLog "Warning — winget not available or install failed: $_" 'Yellow'
            }
        }

        if ($dcuCli) {
            _DrvLog "Running: $dcuCli /applyupdates -updateType=driver -silent"
            try {
                $dcuArgs = @('/applyupdates', '-updateType=driver', '-silent')
                if ($Force) { $dcuArgs += '-reboot=disable' }
                $proc = Start-Process -FilePath $dcuCli -ArgumentList $dcuArgs -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -in @($script:DcuExitSuccess, $script:DcuExitNoUpdates)) {
                    $result.Success = $true
                    $result.Message = "Dell Command Update completed (exit $($proc.ExitCode))"
                    _DrvLog "OSDStatus: $($result.Message)" 'Green'
                }
                else {
                    $result.Message = "Dell Command Update exited with code $($proc.ExitCode)"
                    _DrvLog "Warning — $($result.Message)" 'Yellow'
                }
            }
            catch {
                $result.Message = "Dell Command Update error: $_"
                _DrvLog "Warning — $($result.Message)" 'Yellow'
            }
        }
        else {
            $result.Message = 'Dell Command Update CLI not found and could not be installed'
            _DrvLog "Warning — $($result.Message)" 'Yellow'
        }
    }

    # -------------------------------------------------------------------------
    # HP — HP Client Management Script Library (HPCMSL)
    # -------------------------------------------------------------------------
    elseif ($Manufacturer -match 'HP|Hewlett') {
        $result.Provider = 'HPCMSL'
        _DrvLog 'OSDStatus: Using HP Client Management Script Library (HPCMSL) for driver installation...'

        if (_EnsureModule 'HPCMSL') {
            try {
                _DrvLog 'Retrieving HP driver updates...'
                # Get-HPDriverPackCatalog resolves the model-specific softpaq catalog online
                $softpaqs = Get-HPDriverPackCatalog -ErrorAction Stop |
                    Where-Object { $_.Category -match 'Driver' }

                if ($softpaqs -and $softpaqs.Count -gt 0) {
                    _DrvLog "Found $($softpaqs.Count) driver softpaq(s) — installing..."
                    foreach ($sp in $softpaqs) {
                        _DrvLog "Installing: $($sp.Name) ($($sp.Id))"
                        try {
                            $installArgs = @{ SoftPaqNumber = $sp.Id; Overwrite = 'yes' }
                            Get-Softpaq @installArgs -ErrorAction Stop
                            $result.Success = $true
                        }
                        catch {
                            _DrvLog "Warning — could not install $($sp.Id): $_" 'Yellow'
                        }
                    }
                    $result.Message = "HPCMSL driver installation completed ($($softpaqs.Count) softpaq(s) processed)"
                    _DrvLog "OSDStatus: $($result.Message)" 'Green'
                }
                else {
                    $result.Success = $true
                    $result.Message = 'HPCMSL: no applicable driver softpaqs found for this model'
                    _DrvLog "OSDStatus: $($result.Message)" 'Green'
                }
            }
            catch {
                $result.Message = "HPCMSL error: $_"
                _DrvLog "Warning — $($result.Message)" 'Yellow'
            }
        }
        else {
            $result.Message = 'HPCMSL module could not be loaded'
            _DrvLog "Warning — $($result.Message)" 'Yellow'
        }
    }

    # -------------------------------------------------------------------------
    # Lenovo — LSUClient module
    # -------------------------------------------------------------------------
    elseif ($Manufacturer -match 'Lenovo') {
        $result.Provider = 'LSUClient'
        _DrvLog 'OSDStatus: Using LSUClient module for Lenovo driver installation...'

        if (_EnsureModule 'LSUClient') {
            try {
                _DrvLog 'Fetching available Lenovo updates...'
                $updates = Get-LSUpdate -ErrorAction Stop |
                    Where-Object { $_.Category -match 'Driver' }

                if ($updates -and $updates.Count -gt 0) {
                    _DrvLog "Found $($updates.Count) Lenovo driver update(s) — installing..."
                    $installArgs = @{ Updates = $updates }
                    if ($Force) { $installArgs['All'] = $true }
                    Install-LSUpdate @installArgs -ErrorAction Stop
                    $result.Success = $true
                    $result.Message = "LSUClient driver installation completed ($($updates.Count) update(s))"
                    _DrvLog "OSDStatus: $($result.Message)" 'Green'
                }
                else {
                    $result.Success = $true
                    $result.Message = 'LSUClient: no applicable driver updates found for this model'
                    _DrvLog "OSDStatus: $($result.Message)" 'Green'
                }
            }
            catch {
                $result.Message = "LSUClient error: $_"
                _DrvLog "Warning — $($result.Message)" 'Yellow'
            }
        }
        else {
            $result.Message = 'LSUClient module could not be loaded'
            _DrvLog "Warning — $($result.Message)" 'Yellow'
        }
    }

    # -------------------------------------------------------------------------
    # Microsoft Surface — Windows Update (drivers ship via WU/WUfB)
    # -------------------------------------------------------------------------
    elseif ($Manufacturer -match 'Microsoft') {
        $result.Provider = 'WindowsUpdate'
        _DrvLog 'OSDStatus: Microsoft Surface detected — installing drivers via Windows Update...'

        # Surface driver and firmware updates are distributed exclusively through
        # Windows Update; fall through to the WU block below.
        $useWindowsUpdate = $true
    }

    # -------------------------------------------------------------------------
    # Fallback — any other vendor, or Surface (set $useWindowsUpdate above)
    # -------------------------------------------------------------------------
    if ($result.Provider -eq 'Unknown' -or ($Manufacturer -match 'Microsoft' -and $useWindowsUpdate)) {
        if ($result.Provider -eq 'Unknown') {
            $result.Provider = 'WindowsUpdate'
            _DrvLog 'OSDStatus: No vendor-specific tool available — using Windows Update driver scan...'
        }

        # Prefer PSWindowsUpdate if available; fall back to COM API
        if (_EnsureModule 'PSWindowsUpdate') {
            try {
                _DrvLog 'Installing driver updates via PSWindowsUpdate...'
                $wuArgs = @{
                    UpdateType   = 'Driver'
                    AcceptAll    = $true
                    IgnoreReboot = $true
                    Silent       = $true
                }
                $wuResult = Install-WindowsUpdate @wuArgs -ErrorAction Stop
                $result.Success = $true
                $result.Message = "PSWindowsUpdate driver installation completed ($($wuResult.Count) update(s))"
                _DrvLog "OSDStatus: $($result.Message)" 'Green'
            }
            catch {
                _DrvLog "PSWindowsUpdate failed ($_) — falling back to COM API" 'Yellow'
                $result = _InvokeWindowsUpdateCOM -Result $result
            }
        }
        else {
            $result = _InvokeWindowsUpdateCOM -Result $result
        }
    }

    return $result
}
