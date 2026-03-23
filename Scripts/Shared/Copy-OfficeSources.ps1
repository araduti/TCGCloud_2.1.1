# Copy-OfficeSources.ps1 — Shared implementation
# Copies Office installation sources from USB to a local staging directory.
# Called by both SetupComplete and OOBE entry points.

function Copy-OfficeSourcesToLocal {
    <#
    .SYNOPSIS
        Copies Office sources from a removable USB drive to a local staging directory.
    .DESCRIPTION
        Searches all removable drives for an OSDCloud\Office directory, validates free
        space, copies files via robocopy, and optionally copies a language.txt file.
    .PARAMETER DestinationPath
        Local directory to stage the Office sources into.
    .PARAMETER SourceSubPath
        Relative path under the USB OSDCloud directory. Defaults to 'Office'.
    .OUTPUTS
        [bool] $true on success, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [string]$DestinationPath = 'C:\Windows\Temp\OfficeSources',
        [string]$SourceSubPath   = 'Office'
    )

    try {
        Write-Host "Starting Office sources copy process..." -ForegroundColor Cyan

        # Ensure destination exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Host "Created directory: $DestinationPath" -ForegroundColor Green
        }

        # Search for USB drives with Office sources
        $usbDrives = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter }

        foreach ($drive in $usbDrives) {
            $driveLetter     = $drive.DriveLetter
            $officeSourcePath = "${driveLetter}:\OSDCloud\$SourceSubPath"

            if (-not (Test-Path $officeSourcePath)) { continue }

            Write-Host "Found Office sources on drive ${driveLetter}: $officeSourcePath" -ForegroundColor Green

            # Validate free space
            $officeSize = (Get-ChildItem -Path $officeSourcePath -Recurse -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1GB
            $freeSpace  = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB
            Write-Host ("Office size: {0:N2} GB, Free space on C: {1:N2} GB" -f $officeSize, $freeSpace) -ForegroundColor Yellow

            if ($freeSpace -lt ($officeSize * 1.5)) {
                Write-Host "Warning: Limited free space on C: drive." -ForegroundColor Yellow
            }

            # Copy with robocopy for reliability
            $robocopyArgs = @($officeSourcePath, $DestinationPath, '/E', '/R:3', '/W:5', '/J', '/NP', '/NFL', '/NDL')
            $proc = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -lt 8) {
                $copiedFiles = Get-ChildItem -Path $DestinationPath -Recurse
                $copiedMB    = ($copiedFiles | Measure-Object -Property Length -Sum).Sum / 1MB
                Write-Host ("Successfully copied Office sources: {0} files ({1:N2} MB)" -f $copiedFiles.Count, $copiedMB) -ForegroundColor Green

                # Copy language preference if present
                $languageFile = Join-Path $officeSourcePath 'language.txt'
                if (Test-Path $languageFile) {
                    Copy-Item $languageFile (Join-Path $DestinationPath 'language.txt') -Force
                    Write-Host "Language preference copied: $(Get-Content $languageFile -Raw)" -ForegroundColor Green
                }

                return $true
            }
            else {
                Write-Host "Error copying Office sources (robocopy exit code: $($proc.ExitCode))" -ForegroundColor Red
            }
        }

        Write-Host "No USB drive with Office sources found." -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "Error copying Office sources: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}
