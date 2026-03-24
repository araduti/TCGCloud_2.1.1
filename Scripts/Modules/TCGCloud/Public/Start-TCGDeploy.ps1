function Start-TCGDeploy {
    <#
    .SYNOPSIS
        Applies a Windows image to the target disk and configures the boot environment.
    .DESCRIPTION
        Replaces Start-OSDCloud (Phase 4). Locates an install.wim or install.esd on a
        mounted USB drive, applies the selected edition to the Windows partition (C:),
        configures the EFI bootloader via bcdboot, copies SetupComplete and OOBE scripts,
        applies offline drivers, and injects an Autopilot JSON profile when present.

        Outputs OSDStatus: prefixed progress lines compatible with StatusPatterns.json
        so the WPF overlay can display human-readable status messages.
    .PARAMETER OSLanguage
        BCP-47 locale code for the OS image (e.g. 'en-us', 'de-de'). Defaults to 'en-us'.
    .PARAMETER OSVersion
        Windows major version string (e.g. 'Windows 11', 'Windows 10').
    .PARAMETER OSBuild
        Windows feature update build string (e.g. '24H2', '22H2').
    .PARAMETER OSEdition
        Windows edition to deploy (e.g. 'Enterprise', 'Professional'). Used to locate
        the correct image index inside a multi-edition WIM.
    .PARAMETER OSActivation
        Activation type: 'Volume' (default) or 'Retail'. Used for image selection hints.
    .PARAMETER ZTI
        Zero-touch installation — suppresses all interactive prompts.
    .PARAMETER SkipAutopilot
        Do not inject an Autopilot JSON profile, even if one is found.
    .PARAMETER SkipODT
        Reserved for parity with Start-OSDCloud; no Office Deployment Tool logic is
        implemented in this function (Office is handled post-install).
    .PARAMETER ScriptsRoot
        Override for the WinPE scripts root directory. Defaults to
        X:\OSDCloud\Config\Scripts when running inside WinPE.
    .OUTPUTS
        [PSCustomObject] with Success [bool], WindowsDrive [string], and Message [string].
    .EXAMPLE
        Start-TCGDeploy -OSLanguage 'en-us' -OSVersion 'Windows 11' -OSBuild '24H2' -ZTI
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OSLanguage = 'en-us',

        [Parameter()]
        [string]$OSVersion = 'Windows 11',

        [Parameter()]
        [string]$OSBuild = '24H2',

        [Parameter()]
        [string]$OSEdition = 'Enterprise',

        [Parameter()]
        [ValidateSet('Volume', 'Retail')]
        [string]$OSActivation = 'Volume',

        [Parameter()]
        [switch]$ZTI,

        [Parameter()]
        [switch]$SkipAutopilot,

        [Parameter()]
        [switch]$SkipODT,

        [Parameter()]
        [string]$ScriptsRoot
    )

    $ErrorActionPreference = 'Stop'

    # --- Resolve scripts root ----------------------------------------------------
    if (-not $ScriptsRoot) {
        $ScriptsRoot = if (Test-Path 'X:\OSDCloud\Config\Scripts') {
            'X:\OSDCloud\Config\Scripts'
        }
        else {
            $PSScriptRoot
        }
    }

    function _Log {
        param([string]$Msg, [string]$Color = 'Cyan')
        Write-Host $Msg -ForegroundColor $Color
    }

    _Log "OSDStatus: Starting TCGDeploy for $OSVersion $OSBuild ($OSLanguage)" 'Green'

    # =========================================================================
    # Step 1 — Locate OS image on USB
    # =========================================================================
    _Log 'OSDStatus: Searching for OS installation image...'

    $sourcePath = $null

    # Prefer USB volumes labelled OSDCLOUD; fall back to any removable with enough space
    try {
        $candidates = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }
    }
    catch {
        $candidates = @()
    }

    foreach ($vol in $candidates) {
        $dl = $vol.DriveLetter
        foreach ($name in @('install.wim', 'install.esd')) {
            $p = "${dl}:\OSDCloud\OS\$name"
            if (Test-Path $p) { $sourcePath = $p; break }
        }
        if ($sourcePath) { break }
    }

    # Fallback: search well-known local paths (e.g. downloaded by _init.ps1)
    if (-not $sourcePath) {
        foreach ($sp in @('C:\OSDCloud\OS', 'X:\OSDCloud\OS')) {
            if (Test-Path $sp) {
                $found = Get-ChildItem -Path $sp -Include 'install.wim', 'install.esd' `
                    -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $sourcePath = $found.FullName; break }
            }
        }
    }

    if (-not $sourcePath) {
        _Log 'OSDStatus: ERROR — No OS image found. Ensure a TCGCloud USB is attached.' 'Red'
        return [PSCustomObject]@{ Success = $false; WindowsDrive = $null; Message = 'OS image not found' }
    }

    _Log "OSDStatus: Using image: $sourcePath" 'Green'

    # =========================================================================
    # Step 2 — Identify the target Windows drive
    # =========================================================================
    # Initialize-CustomDisk / Format-OSDisk creates and formats the Windows
    # partition and labels it "Windows".  Find that volume.
    $windowsDrive = $null

    try {
        $winVol = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystemLabel -eq 'Windows' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' } |
            Select-Object -First 1

        if ($winVol) {
            $windowsDrive = "$($winVol.DriveLetter):"
        }
    }
    catch { }

    # Fallback: C: if it is an NTFS volume (common in test environments)
    if (-not $windowsDrive) {
        if ((Get-Volume -DriveLetter 'C' -ErrorAction SilentlyContinue)?.FileSystem -eq 'NTFS') {
            $windowsDrive = 'C:'
        }
    }

    if (-not $windowsDrive) {
        _Log 'OSDStatus: ERROR — Cannot locate Windows target partition.' 'Red'
        return [PSCustomObject]@{ Success = $false; WindowsDrive = $null; Message = 'Windows partition not found' }
    }

    _Log "OSDStatus: Target Windows partition: $windowsDrive"

    # =========================================================================
    # Step 3 — Identify the EFI System Partition drive letter
    # =========================================================================
    $espDrive = $null

    try {
        $espVol = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystemLabel -match 'System|EFI|ESP' -and $_.DriveLetter -and $_.FileSystem -eq 'FAT32' } |
            Select-Object -First 1
        if ($espVol) { $espDrive = "$($espVol.DriveLetter):" }
    }
    catch { }

    # Fallback: look for the GPT EFI partition type on any disk
    if (-not $espDrive) {
        try {
            $espPart = Get-Partition -ErrorAction SilentlyContinue |
                Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.DriveLetter } |
                Select-Object -First 1
            if ($espPart) { $espDrive = "$($espPart.DriveLetter):" }
        }
        catch { }
    }

    if ($espDrive) {
        _Log "OSDStatus: EFI System Partition: $espDrive"
    }
    else {
        _Log 'OSDStatus: Warning — EFI System Partition drive letter not detected; bcdboot will target default.' 'Yellow'
    }

    # =========================================================================
    # Step 4 — Find the correct image index
    # =========================================================================
    _Log "OSDStatus: Identifying image index for '$OSEdition'..."

    $imageIndex = 1

    try {
        $wimInfoOutput = & dism /Get-WimInfo /WimFile:"$sourcePath" 2>&1 | Out-String

        # Parse index + name pairs from DISM output
        $indexMatches = [regex]::Matches($wimInfoOutput, 'Index\s*:\s*(\d+)')
        $nameMatches  = [regex]::Matches($wimInfoOutput, 'Name\s*:\s*(.+)')

        for ($i = 0; $i -lt $indexMatches.Count; $i++) {
            $idxVal  = [int]$indexMatches[$i].Groups[1].Value
            $nameVal = if ($i -lt $nameMatches.Count) { $nameMatches[$i].Groups[1].Value.Trim() } else { '' }

            if ($nameVal -match [regex]::Escape($OSEdition)) {
                $imageIndex = $idxVal
                _Log "OSDStatus: Matched image index $imageIndex — $nameVal" 'Green'
                break
            }
        }

        if ($imageIndex -eq 1 -and $indexMatches.Count -gt 1) {
            _Log "OSDStatus: Edition '$OSEdition' not matched exactly; using index 1." 'Yellow'
        }
    }
    catch {
        _Log "OSDStatus: Warning — Could not query WIM info, using index 1: $_" 'Yellow'
    }

    # =========================================================================
    # Step 5 — Apply the Windows image
    # =========================================================================
    _Log "OSDStatus: Applying Windows image (index $imageIndex) to $windowsDrive ..."

    try {
        $applyArgs = @(
            '/Apply-Image',
            "/ImageFile:`"$sourcePath`"",
            "/Index:$imageIndex",
            "/ApplyDir:$windowsDrive\"
        )

        $applyOutput = & dism @applyArgs 2>&1 | Tee-Object -FilePath 'X:\OSDCloud\Logs\TCGDeploy-Apply.log' -Append -ErrorAction SilentlyContinue | Out-String

        if ($LASTEXITCODE -ne 0) {
            _Log "OSDStatus: ERROR — DISM image apply failed (exit $LASTEXITCODE)" 'Red'
            _Log $applyOutput 'Red'
            return [PSCustomObject]@{ Success = $false; WindowsDrive = $windowsDrive; Message = "DISM apply failed ($LASTEXITCODE)" }
        }

        _Log 'OSDStatus: Windows image applied successfully.' 'Green'
    }
    catch {
        _Log "OSDStatus: ERROR — Image apply threw an exception: $_" 'Red'
        return [PSCustomObject]@{ Success = $false; WindowsDrive = $windowsDrive; Message = "Image apply exception: $_" }
    }

    # =========================================================================
    # Step 6 — Configure the boot environment
    # =========================================================================
    _Log 'OSDStatus: Configuring boot environment...'

    try {
        $bcdbootArgs = if ($espDrive) {
            @("$windowsDrive\Windows", '/s', $espDrive, '/f', 'UEFI')
        }
        else {
            @("$windowsDrive\Windows", '/f', 'UEFI')
        }

        $bcdOutput = & bcdboot @bcdbootArgs 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            _Log "OSDStatus: Warning — bcdboot reported exit code $LASTEXITCODE : $bcdOutput" 'Yellow'
        }
        else {
            _Log 'OSDStatus: Boot environment configured.' 'Green'
        }
    }
    catch {
        _Log "OSDStatus: Warning — bcdboot error: $_" 'Yellow'
    }

    # =========================================================================
    # Step 7 — Copy SetupComplete scripts
    # =========================================================================
    _Log 'OSDStatus: Copying SetupComplete scripts...'

    $setupCompleteSrc = Join-Path $ScriptsRoot 'SetupComplete'
    $setupCompleteDst = "$windowsDrive\Windows\Setup\Scripts"

    if (Test-Path $setupCompleteSrc) {
        try {
            if (-not (Test-Path $setupCompleteDst)) {
                New-Item -Path $setupCompleteDst -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path "$setupCompleteSrc\*" -Destination $setupCompleteDst -Recurse -Force
            _Log 'OSDStatus: SetupComplete scripts copied.' 'Green'
        }
        catch {
            _Log "OSDStatus: Warning — Could not copy SetupComplete scripts: $_" 'Yellow'
        }
    }
    else {
        _Log "OSDStatus: SetupComplete source not found at $setupCompleteSrc — skipping." 'Yellow'
    }

    # =========================================================================
    # Step 8 — Copy OOBE scripts
    # =========================================================================
    _Log 'OSDStatus: Copying OOBE scripts...'

    $oobeSrc = Join-Path $ScriptsRoot 'Custom\OOBE'
    $oobeDst = "$windowsDrive\Windows\Setup\Scripts\OOBE"

    if (Test-Path $oobeSrc) {
        try {
            if (-not (Test-Path $oobeDst)) {
                New-Item -Path $oobeDst -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path "$oobeSrc\*" -Destination $oobeDst -Recurse -Force
            _Log 'OSDStatus: OOBE scripts copied.' 'Green'
        }
        catch {
            _Log "OSDStatus: Warning — Could not copy OOBE scripts: $_" 'Yellow'
        }
    }

    # =========================================================================
    # Step 9 — Autopilot JSON injection
    # =========================================================================
    if (-not $SkipAutopilot) {
        _Log 'OSDStatus: Checking for Autopilot profile...'

        $apJsonPaths = @(
            'X:\OSDCloud\Config\AutopilotConfigurationFile.json',
            (Join-Path $ScriptsRoot 'Custom\AutopilotConfigurationFile.json')
        )

        $apJsonSrc = $apJsonPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($apJsonSrc) {
            $apDst = "$windowsDrive\Windows\Provisioning\Autopilot"
            try {
                if (-not (Test-Path $apDst)) {
                    New-Item -Path $apDst -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $apJsonSrc -Destination (Join-Path $apDst 'AutopilotConfigurationFile.json') -Force
                _Log 'OSDStatus: Autopilot profile injected.' 'Green'
            }
            catch {
                _Log "OSDStatus: Warning — Could not inject Autopilot profile: $_" 'Yellow'
            }
        }
        else {
            _Log 'OSDStatus: No Autopilot profile found — skipping injection.' 'Yellow'
        }
    }

    # =========================================================================
    # Step 10 — Apply offline drivers
    # =========================================================================
    _Log 'OSDStatus: Checking for offline driver packs...'

    $driverPaths = @()

    try {
        $removables = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }

        foreach ($vol in $removables) {
            $dp = "$($vol.DriveLetter):\OSDCloud\Drivers"
            if (Test-Path $dp) { $driverPaths += $dp }
        }
    }
    catch { }

    if ($driverPaths.Count -gt 0) {
        foreach ($dp in $driverPaths) {
            _Log "OSDStatus: Applying drivers from: $dp"
            try {
                $driverOutput = & dism /Image:"$windowsDrive\" /Add-Driver /Driver:"$dp" /Recurse /ForceUnsigned 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    _Log "OSDStatus: Warning — Driver injection returned exit $LASTEXITCODE" 'Yellow'
                }
                else {
                    _Log 'OSDStatus: Offline drivers applied.' 'Green'
                }
            }
            catch {
                _Log "OSDStatus: Warning — Driver injection error: $_" 'Yellow'
            }
        }
    }
    else {
        _Log 'OSDStatus: No offline driver packs found on USB — skipping.'
    }

    # =========================================================================
    # Done
    # =========================================================================
    _Log "OSDStatus: TCGDeploy complete. Windows installed on $windowsDrive" 'Green'

    return [PSCustomObject]@{
        Success      = $true
        WindowsDrive = $windowsDrive
        Message      = "Deployment complete — Windows on $windowsDrive"
    }
}
