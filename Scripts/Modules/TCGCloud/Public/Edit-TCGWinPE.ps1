function Edit-TCGWinPE {
    <#
    .SYNOPSIS
        Customizes a WinPE boot.wim image with drivers, WiFi support, and wallpaper.
    .DESCRIPTION
        Replaces Edit-OSDCloudWinPE. Mounts boot.wim, injects optional components
        and drivers, sets the wallpaper, customizes startnet.cmd, then unmounts
        and commits the image. Optionally copies the updated boot.wim to a USB drive.
    .PARAMETER BootWimPath
        Path to the boot.wim file to customize.
    .PARAMETER Wallpaper
        Path to a .jpg wallpaper to embed in the WinPE image.
    .PARAMETER DriverPaths
        One or more directories containing .inf drivers to inject.
    .PARAMETER CloudDriver
        Wildcard pattern matching OSDCloud-style driver packs (for compatibility).
        When set to '*', all available driver paths are used.
    .PARAMETER WirelessConnect
        Add WiFi support packages (WinPE-Dot3Svc, WinPE-WiFi, etc.).
    .PARAMETER UpdateUSB
        Drive letter of a USB to copy the updated boot.wim to after committing.
    .PARAMETER StartnetCommand
        Custom command to append to startnet.cmd inside the WinPE image.
        Defaults to launching the TCGCloud init script.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    .EXAMPLE
        Edit-TCGWinPE -BootWimPath 'D:\Build\Media\sources\boot.wim' -WirelessConnect -Wallpaper '.\wallpaper.jpg'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BootWimPath,

        [Parameter()]
        [string]$Wallpaper,

        [Parameter()]
        [string[]]$DriverPaths,

        [Parameter()]
        [string]$CloudDriver,

        [Parameter()]
        [switch]$WirelessConnect,

        [Parameter()]
        [string]$UpdateUSB,

        [Parameter()]
        [string]$StartnetCommand = 'powershell -ExecutionPolicy Bypass -File X:\OSDCloud\Config\Scripts\init.ps1'
    )

    if (-not (Test-Path $BootWimPath)) {
        Write-TCGStatus "boot.wim not found: $BootWimPath" -Type Error
        return $false
    }

    $mountPath = Join-Path $env:TEMP "TCGCloud-Mount-$(Get-Random)"

    try {
        # --- Mount ---------------------------------------------------------------
        $mounted = Mount-WimImage -WimPath $BootWimPath -MountPath $mountPath -Index 1
        if (-not $mounted) { return $false }

        # --- Inject drivers ------------------------------------------------------
        if ($DriverPaths) {
            foreach ($dp in $DriverPaths) {
                if (Test-Path $dp) {
                    Write-TCGStatus "Injecting drivers from: $dp" -Type Info
                    Invoke-DismOperation -MountPath $mountPath -Arguments @(
                        '/Add-Driver', "/Driver:`"$dp`"", '/Recurse', '/ForceUnsigned'
                    ) | Out-Null
                }
                else {
                    Write-TCGStatus "Driver path not found, skipping: $dp" -Type Warning
                }
            }
        }

        # --- WiFi support packages -----------------------------------------------
        if ($WirelessConnect) {
            $ocPath = Get-WinPEOCPath
            if ($ocPath) {
                $wifiPackages = @(
                    'WinPE-WMI.cab'
                    'WinPE-NetFx.cab'
                    'WinPE-Scripting.cab'
                    'WinPE-PowerShell.cab'
                    'WinPE-DismCmdlets.cab'
                    'WinPE-Dot3Svc.cab'
                    'WinPE-StorageWMI.cab'
                    'WinPE-SecureBootCmdlets.cab'
                )

                foreach ($pkg in $wifiPackages) {
                    $pkgPath = Join-Path $ocPath $pkg
                    if (Test-Path $pkgPath) {
                        Write-TCGStatus "Adding package: $pkg" -Type Info
                        Invoke-DismOperation -MountPath $mountPath -Arguments @(
                            '/Add-Package', "/PackagePath:`"$pkgPath`""
                        ) | Out-Null
                    }
                    else {
                        Write-TCGStatus "Package not found, skipping: $pkg" -Type Warning
                    }
                }
            }
            else {
                Write-TCGStatus 'Could not locate WinPE optional components. WiFi packages not added.' -Type Warning
            }
        }

        # --- Wallpaper -----------------------------------------------------------
        if ($Wallpaper -and (Test-Path $Wallpaper)) {
            $destWallpaper = Join-Path $mountPath 'Windows\System32\winpe.jpg'
            Copy-Item -Path $Wallpaper -Destination $destWallpaper -Force
            Write-TCGStatus 'Custom wallpaper applied.' -Type Success
        }

        # --- Customize startnet.cmd ----------------------------------------------
        $startnetPath = Join-Path $mountPath 'Windows\System32\startnet.cmd'
        $startnetContent = @"
wpeinit
$StartnetCommand
"@
        Set-Content -Path $startnetPath -Value $startnetContent -Force
        Write-TCGStatus 'startnet.cmd customized.' -Type Info

        # --- Unmount & commit ----------------------------------------------------
        Write-TCGStatus 'Committing changes to boot.wim...' -Type Info
        $dismResult = & dism /Unmount-Wim /MountDir:"$mountPath" /Commit 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-TCGStatus "DISM unmount/commit failed (exit $LASTEXITCODE): $dismResult" -Type Error
            return $false
        }
        Write-TCGStatus 'boot.wim updated successfully.' -Type Success

        # --- Copy to USB if requested --------------------------------------------
        if ($UpdateUSB) {
            $usbBootWim = "${UpdateUSB}:\sources\boot.wim"
            $usbDir = Split-Path $usbBootWim
            if (-not (Test-Path $usbDir)) {
                New-Item -Path $usbDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $BootWimPath -Destination $usbBootWim -Force
            Write-TCGStatus "Updated boot.wim copied to USB ($UpdateUSB`:)." -Type Success
        }

        return $true
    }
    catch {
        Write-TCGStatus "Error customizing WinPE: $_" -Type Error
        # Attempt to discard on error
        & dism /Unmount-Wim /MountDir:"$mountPath" /Discard 2>&1 | Out-Null
        return $false
    }
    finally {
        Remove-Item $mountPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
