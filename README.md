# TCGCloud 2.1.1

Enterprise Windows deployment toolkit built on WinPE with Microsoft Autopilot integration. Creates bootable USB drives that automate Windows installation, device registration, and post-deployment configuration for corporate environments.

## What It Does

TCGCloud automates the full lifecycle of Windows device deployment:

1. **USB Creation** — Builds a bootable WinPE USB drive with Windows ADK, custom scripts, and OS installation media
2. **Boot & Network** — Boots into WinPE, connects to WiFi, and detects device language
3. **Autopilot Detection** — Checks if the device is already registered in Microsoft Autopilot via Graph API
4. **Interactive UI** — WPF overlay lets technicians select Country, Device Type (Persona), and Language — or auto-deploys if already registered
5. **Disk Setup** — Handles RAID detection (PERC, MegaRAID, LSI), Storage Spaces, and GPT partitioning (ESP/MSR/Windows)
6. **OS Deployment** — Applies the Windows image via OSDCloud with enterprise settings
7. **Post-Install** — Runs Windows Update, installs drivers, deploys Office, and cleans up

## Architecture

```
┌─── HOST (Windows 10/11 + ADK) ──────────────────────────────┐
│  Setup-OSDCloudUSB.ps1                                       │
│  ├─ Install Windows ADK + WinPE add-on                       │
│  ├─ Create OSDCloud workspace & template                     │
│  ├─ Copy TCGCloud scripts to USB                             │
│  ├─ Add Windows install media + Office sources               │
│  └─ Output: Bootable USB                                     │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌─── WINPE BOOT (Target Device) ───────────────────────────────┐
│  startnet.cmd → Scripts/init.ps1                             │
│  ├─ OS version selection (Win11 24H2 / Win10 22H2)          │
│  └─ Scripts/StartNet/_init.ps1                               │
│     ├─ Import OSD module, connect WiFi                       │
│     ├─ Detect language from install media                    │
│     └─ Launch Show-OSDCloudOverlay.ps1                       │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌─── INTERACTIVE OVERLAY (WPF) ────────────────────────────────┐
│  Show-OSDCloudOverlay.ps1                                    │
│  ├─ Check Autopilot status (Invoke-Prereq.ps1)              │
│  ├─ REGISTERED → auto-deploy with GroupTag settings          │
│  └─ NOT REGISTERED → show form → register via Graph API     │
│     ├─ Invoke-ImportAutopilot.ps1 (oa3tool → hardware hash) │
│     ├─ POST to Autopilot via Microsoft Graph                 │
│     └─ Poll for confirmation (max 25 × 30s)                 │
│                                                              │
│  Then: Initialize-CustomDisk → Start-OSDCloud → Monitor     │
│  Progress: tail logs + match StatusPatterns.json → UX msgs   │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌─── POST-INSTALL ─────────────────────────────────────────────┐
│  SetupComplete.cmd                                           │
│  ├─ Copy-OfficeSources.ps1 (USB → local)                    │
│  ├─ SetupComplete.ps1 (Windows Update drivers + OS updates)  │
│  └─ Remove-OSDCloudFolders.ps1 (cleanup)                    │
│                                                              │
│  OOBE phase:                                                 │
│  ├─ OOBEDeploy.ps1 (PSWindowsUpdate, Store apps via winget) │
│  └─ Copy-OfficeSources.ps1 (finalize Office deployment)     │
└──────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
TCGCloud_2.1.1/
├── Setup-OSDCloudUSB.ps1              # Main USB creation orchestrator (run on host)
├── Scripts/
│   ├── init.ps1                       # OS version selection dialog (WinPE entry point)
│   ├── StartNet/                      # WinPE runtime scripts
│   │   ├── _init.ps1                  # Network setup & language detection
│   │   ├── Show-OSDCloudOverlay.ps1   # Main WPF UI & deployment orchestration
│   │   ├── OSDCloudOverlay.xaml       # WPF window layout definition
│   │   ├── StatusPatterns.json        # Log-to-message pattern mapping (100+ patterns)
│   │   ├── Invoke-Prereq.ps1         # Autopilot status check via Graph API
│   │   ├── Invoke-DiskFunctions.ps1   # RAID detection & disk partitioning
│   │   ├── Invoke-ImportAutopilot.ps1 # Hardware hash generation & Autopilot import
│   │   ├── Utils.ps1                  # Graph API token & Autopilot helper functions
│   │   ├── Logging.psm1              # Standardized logging framework
│   │   └── thomas-logo.png           # UI branding logo
│   ├── Custom/                        # Embedded tools & configuration
│   │   ├── TCGLogging.ps1 / .psm1    # Custom logging functions & module
│   │   ├── TCGUtility.ps1 / .psm1    # Microsoft Graph API integration module
│   │   ├── OA3.cfg                    # OA3 tool hardware hash config
│   │   ├── oa3tool.exe                # Microsoft hardware hash generator
│   │   ├── PCPKsp.dll                 # Windows Autopilot support DLL
│   │   ├── thomas-logo.png            # Branding logo
│   │   ├── wallpaper.jpg              # Custom WinPE wallpaper
│   │   └── OOBE/                      # Out-of-Box Experience scripts
│   │       ├── OOBEDeploy.ps1         # Windows Update & Store app install
│   │       ├── Copy-OfficeSources.ps1 # Office deployment file staging
│   │       └── oobe.cmd               # OOBE entry point
│   └── SetupComplete/                 # First-boot scripts
│       ├── SetupComplete.ps1          # Windows Updates & driver install
│       ├── SetupComplete.cmd          # Entry point batch file
│       ├── Copy-OfficeSources.ps1     # Office sources staging
│       └── Remove-OSDCloudFolders.ps1 # Cleanup temporary files
└── README.md
```

## Prerequisites

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 (host machine for USB creation) |
| **PowerShell** | Version 5.1+ running as Administrator |
| **Windows ADK** | v10.1.25398.1 (auto-installed by script) |
| **WinPE Add-on** | Matching ADK version (auto-installed) |
| **USB Drive** | 8 GB – 256 GB capacity |
| **Internet** | Required for ADK download, PSGallery modules, Graph API |
| **Azure AD App** | Service principal with Autopilot permissions |

### PowerShell Modules (Auto-Installed)

- **OSDCloud** — Workspace, template, USB media, and WinPE customization
- **OSD** — Core deployment helper functions (used in WinPE)
- **PSWindowsUpdate** — Driver and OS update management (installed during deployment)

## Usage

### Create a Bootable USB

```powershell
# Default: Windows 11 24H2 Enterprise
.\Setup-OSDCloudUSB.ps1

# With specific OS
.\Setup-OSDCloudUSB.ps1 -OSName "Windows 10 22H2"

# Custom working directory
.\Setup-OSDCloudUSB.ps1 -WorkingDirectory "D:\OSDCloud-Build"

# Skip OS media (scripts only)
.\Setup-OSDCloudUSB.ps1 -NoOS
```

### Deploy a Device

1. Boot target device from the USB drive
2. Select Windows version (Win11 24H2 is default, auto-selects after 10s)
3. Wait for WiFi connection and Autopilot status check
4. **If device is pre-registered**: deployment starts automatically
5. **If not registered**: select Country, Device Type, Language → click Continue
6. Monitor progress via the overlay UI (or toggle Technical View for raw logs)
7. Device reboots into Windows OOBE, then Autopilot takes over

## OSDCloud Dependency Summary

This project currently depends on the [OSDCloud](https://www.osdcloud.com/) PowerShell module for several core functions:

| OSDCloud Function | Where Used | Purpose |
|---|---|---|
| `New-OSDCloudTemplate` | Setup-OSDCloudUSB.ps1 | Creates WinPE template with drivers |
| `Get-OSDCloudTemplate` | Setup-OSDCloudUSB.ps1 | Checks for existing template |
| `New-OSDCloudWorkspace` | Setup-OSDCloudUSB.ps1 | Creates deployment workspace structure |
| `New-OSDCloudUSB` | Setup-OSDCloudUSB.ps1 | Formats USB and copies boot media |
| `Edit-OSDCloudWinPE` | Setup-OSDCloudUSB.ps1 | Customizes WinPE (wallpaper, drivers, WiFi) |
| `Update-OSDCloudUSB` | Setup-OSDCloudUSB.ps1 | Adds OS installation files to USB |
| `Import-Module OSD` | _init.ps1, Show-OSDCloudOverlay.ps1 | Core OSD helper functions in WinPE |
| `Start-OSDCloud` | Show-OSDCloudOverlay.ps1 | Executes Windows image deployment |
| `Start-WinREWiFi` | _init.ps1 | WiFi connection in WinPE |

See [OSDCLOUD_REPLACEMENT_PLAN.md](OSDCLOUD_REPLACEMENT_PLAN.md) for the migration strategy.

## Key Configuration

### OSDCloud Settings (at deployment time)

```powershell
$Global:MyOSDCloud = @{
    Restart               = $true
    RecoveryPartition     = $true
    OEMActivation         = $true
    WindowsUpdate         = $false    # Handled by post-install scripts
    WindowsUpdateDrivers  = $false    # Handled by post-install scripts
    WindowsDefenderUpdate = $false
    SetTimeZone           = $true
    ClearDiskConfirm      = $false
    ShutdownSetupComplete = $false
    SyncMSUpCatDriverUSB  = $true
    CheckSHA1             = $false
    SkipClearDisk         = $true     # Custom disk handling (RAID-aware)
    SkipNewOSDisk         = $true     # Custom disk handling (RAID-aware)
}
```

### Start-OSDCloud Parameters

```powershell
Start-OSDCloud -OSLanguage "en-us" `
    -OSVersion "Windows 11" -OSBuild "24H2" `
    -OSEdition "Enterprise" -OSActivation "Volume" `
    -SkipAutopilot -SkipODT -ZTI
```

## Improvement Opportunities

### Security
- **Client secret in source code** — `TCGUtility.psm1` contains hardcoded Azure AD client secret; should use certificate-based authentication or Azure Key Vault
- **Input validation** — Autopilot registration form fields lack sanitization

### Code Quality
- **Duplicate logging modules** — `TCGLogging.psm1` and `Logging.psm1` serve similar purposes; consolidate into one
- **Duplicate code blocks** — `Show-OSDCloudOverlay.ps1` has two near-identical deployment blocks (registered vs unregistered paths); refactor into a shared function
- **Duplicate `Copy-OfficeSources.ps1`** — exists in both `SetupComplete/` and `OOBE/` with minor differences
- **Large monolithic scripts** — `Setup-OSDCloudUSB.ps1` (2,170 lines) and `Show-OSDCloudOverlay.ps1` (1,000+ lines) could be modularized

### Reliability
- **Error recovery** — Some error paths silently continue; add structured retry logic
- **Disk function edge cases** — RAID detection relies on friendly name matching (`PERC`, `MegaRAID`, `LSI`); may miss newer controllers

### Maintainability
- **No tests** — Add Pester tests for critical functions (Graph API, disk detection, pattern matching)
- **No CI/CD** — Add GitHub Actions for linting (PSScriptAnalyzer) and testing
- **Version tracking** — No version metadata beyond the repo name

## License

Internal use — Thomas Computing Group.
