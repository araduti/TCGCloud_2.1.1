# TCGCloud 2.1.1

Enterprise Windows deployment toolkit built on WinPE with Microsoft Autopilot integration. Supports two deployment methods: **USB-based** (traditional) and **network-based** (no USB required — boot media hosted on GitHub).

## What It Does

TCGCloud automates the full lifecycle of Windows device deployment:

1. **Boot Media** — Either create a USB drive or download WinPE boot media from GitHub on demand
2. **Boot & Network** — Boots into WinPE, connects to WiFi, and detects device language
3. **Autopilot Detection** — Checks if the device is already registered in Microsoft Autopilot via Graph API
4. **Interactive UI** — WPF overlay lets technicians select Country, Device Type (Persona), and Language — or auto-deploys if already registered
5. **Disk Setup** — Handles RAID detection (PERC, MegaRAID, LSI), Storage Spaces, and GPT partitioning (ESP/MSR/Windows)
6. **OS Deployment** — Applies the Windows image via OSDCloud with enterprise settings
7. **Post-Install** — Runs Windows Update, installs drivers, deploys Office, and cleans up

## Deployment Methods

### Option A: Network Deployment (No USB Required)

Downloads WinPE boot media from a GitHub Release, configures a one-time RAM-disk boot, and reboots into WinPE. Scripts are either embedded in the WIM or downloaded from GitHub at boot time.

```powershell
# One-liner: download and run
irm https://github.com/araduti/TCGCloud_2.1.1/releases/latest/download/Start-NetworkDeploy.ps1 -OutFile Start-NetworkDeploy.ps1
.\Start-NetworkDeploy.ps1
```

```powershell
# With options
.\Start-NetworkDeploy.ps1 -ReleaseTag "v2.1.1" -SkipReboot   # Stage only, don't reboot
.\Start-NetworkDeploy.ps1 -CreateISO                           # Create bootable ISO instead
.\Start-NetworkDeploy.ps1 -Force                                # Skip confirmation prompts
```

### Option B: USB Deployment (Traditional)

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

### Building Boot Media

To create the `boot.wim` for GitHub hosting (requires Windows ADK):

```powershell
# Build boot.wim with embedded scripts
.\Build-BootMedia.ps1

# Build with ISO output
.\Build-BootMedia.ps1 -CreateISO -OutputPath D:\Release

# Inject additional drivers
.\Build-BootMedia.ps1 -DriverPaths "C:\Drivers\WiFi","C:\Drivers\Storage"
```

Then upload `boot.wim`, `boot.sdi`, and `tcgcloud-scripts.zip` to a GitHub Release.

## Architecture

```
┌─── DEPLOYMENT ENTRY POINTS ──────────────────────────────────┐
│                                                              │
│  Option A: Network                Option B: USB              │
│  Start-NetworkDeploy.ps1          Setup-OSDCloudUSB.ps1      │
│  ├─ Download boot.wim             ├─ Install ADK + WinPE     │
│  │  from GitHub Release           ├─ Create OSDCloud media   │
│  ├─ Download scripts              ├─ Copy scripts to USB     │
│  ├─ Configure RAM-disk boot       ├─ Add OS + Office media   │
│  └─ Reboot into WinPE             └─ Boot from USB           │
│                                                              │
│  Build-BootMedia.ps1 ← Builds boot.wim for GitHub hosting   │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌─── WINPE BOOT (Target Device) ───────────────────────────────┐
│  startnet.cmd → Scripts/init.ps1                             │
│  ├─ OS version selection (Win11 24H2 / Win10 22H2)          │
│  └─ Scripts/StartNet/_init.ps1                               │
│     ├─ Detect boot mode (USB vs Network)                     │
│     ├─ If Network: download scripts from GitHub              │
│     ├─ Connect WiFi (OSD module or netsh fallback)           │
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
├── Start-NetworkDeploy.ps1            # Network deployment — download boot media & reboot
├── Build-BootMedia.ps1                # Build boot.wim from ADK with embedded scripts
├── Setup-OSDCloudUSB.ps1              # USB creation orchestrator (traditional flow)
├── deploy-config.json                 # Central config: GitHub URLs, OS defaults
├── OSDCLOUD_REPLACEMENT_PLAN.md       # Migration plan for replacing OSDCloud dependencies
├── .github/workflows/
│   └── build-release.yml              # CI: package scripts & create GitHub Releases
├── Scripts/
│   ├── init.ps1                       # OS version selection dialog (WinPE entry point)
│   ├── Modules/
│   │   └── TCGCloud/                  # Custom module replacing OSDCloud functions
│   │       ├── TCGCloud.psd1          # Module manifest (v2.1.1)
│   │       ├── TCGCloud.psm1          # Root module — dot-sources Public/ and Private/
│   │       ├── Public/
│   │       │   ├── Get-TCGTemplate.ps1    # Replaces Get-OSDCloudTemplate
│   │       │   └── Connect-TCGWiFi.ps1    # Replaces Start-WinREWiFi
│   │       └── Private/
│   │           └── Write-TCGStatus.ps1    # Shared status output helper
│   ├── Shared/
│   │   └── Copy-OfficeSources.ps1     # Shared Office staging logic (used by SetupComplete & OOBE)
│   ├── StartNet/                      # WinPE runtime scripts
│   │   ├── _init.ps1                  # Boot mode detection, network setup, language
│   │   ├── Show-OSDCloudOverlay.ps1   # Main WPF UI & deployment orchestration
│   │   ├── OSDCloudOverlay.xaml       # WPF window layout definition
│   │   ├── StatusPatterns.json        # Log-to-message pattern mapping (100+ patterns)
│   │   ├── Invoke-Prereq.ps1         # Autopilot status check via Graph API
│   │   ├── Invoke-DiskFunctions.ps1   # RAID detection & disk partitioning
│   │   ├── Invoke-ImportAutopilot.ps1 # Hardware hash generation & Autopilot import
│   │   ├── Utils.ps1                  # Graph API token & Autopilot helper functions
│   │   ├── Logging.psm1              # Compatibility wrapper → delegates to TCGLogging
│   │   └── thomas-logo.png           # UI branding logo
│   ├── Custom/                        # Embedded tools & configuration
│   │   ├── TCGLogging.ps1 / .psm1    # Canonical logging functions & module
│   │   ├── TCGUtility.ps1 / .psm1    # Microsoft Graph API integration module
│   │   ├── OA3.cfg                    # OA3 tool hardware hash config
│   │   ├── oa3tool.exe                # Microsoft hardware hash generator
│   │   ├── PCPKsp.dll                 # Windows Autopilot support DLL
│   │   ├── thomas-logo.png            # Branding logo
│   │   ├── wallpaper.jpg              # Custom WinPE wallpaper
│   │   └── OOBE/                      # Out-of-Box Experience scripts
│   │       ├── OOBEDeploy.ps1         # Windows Update & Store app install
│   │       ├── Copy-OfficeSources.ps1 # Delegates to Shared/Copy-OfficeSources.ps1
│   │       └── oobe.cmd               # OOBE entry point
│   └── SetupComplete/                 # First-boot scripts
│       ├── SetupComplete.ps1          # Windows Updates & driver install
│       ├── SetupComplete.cmd          # Entry point batch file
│       ├── Copy-OfficeSources.ps1     # Delegates to Shared/Copy-OfficeSources.ps1
│       └── Remove-OSDCloudFolders.ps1 # Cleanup temporary files
├── Tests/
│   ├── TCGCloud.Module.Tests.ps1      # Pester tests for TCGCloud module
│   └── Security.Tests.ps1            # Pester tests for secret leakage
└── README.md
```

## Prerequisites

### For Network Deployment (Start-NetworkDeploy.ps1)

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 on the target machine |
| **PowerShell** | Version 5.1+ running as Administrator |
| **Internet** | Required to download boot media from GitHub |
| **Azure AD App** | Service principal with Autopilot permissions |

### For USB Deployment (Setup-OSDCloudUSB.ps1)

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 (host machine for USB creation) |
| **PowerShell** | Version 5.1+ running as Administrator |
| **Windows ADK** | v10.1.25398.1 (auto-installed by script) |
| **WinPE Add-on** | Matching ADK version (auto-installed) |
| **USB Drive** | 8 GB – 256 GB capacity |
| **Internet** | Required for ADK download, PSGallery modules, Graph API |
| **Azure AD App** | Service principal with Autopilot permissions |

### For Building Boot Media (Build-BootMedia.ps1)

| Requirement | Details |
|---|---|
| **Windows ADK** | With WinPE add-on installed |
| **PowerShell** | Version 5.1+ running as Administrator |

### PowerShell Modules (Auto-Installed)

- **OSDCloud** — Workspace, template, USB media, and WinPE customization (USB mode)
- **OSD** — Core deployment helper functions (USB mode WinPE)
- **PSWindowsUpdate** — Driver and OS update management (installed during deployment)

## Deploying a Device

1. Boot target device from USB drive or via network deploy reboot
2. Select Windows version (Win11 24H2 is default, auto-selects after 10s)
3. Wait for WiFi connection and Autopilot status check
4. **If device is pre-registered**: deployment starts automatically
5. **If not registered**: select Country, Device Type, Language → click Continue
6. Monitor progress via the overlay UI (or toggle Technical View for raw logs)
7. Device reboots into Windows OOBE, then Autopilot takes over

## GitHub Release Workflow

The CI/CD pipeline (`.github/workflows/build-release.yml`) automates packaging:

1. **On tag push** (e.g., `git tag v2.1.1 && git push --tags`): packages scripts into `tcgcloud-scripts.zip` and creates a GitHub Release
2. **Manual dispatch**: trigger from the Actions tab in GitHub
3. **Boot media**: `boot.wim` and `boot.sdi` must be built locally with `Build-BootMedia.ps1` and uploaded to the release manually (requires Windows ADK)

### Release Asset Structure

| Asset | How Created | Purpose |
|---|---|---|
| `tcgcloud-scripts.zip` | CI (automatic) | Scripts package for WinPE |
| `Start-NetworkDeploy.ps1` | CI (automatic) | Network deployment launcher |
| `Build-BootMedia.ps1` | CI (automatic) | Boot media builder |
| `boot.wim` | Manual upload | WinPE boot image |
| `boot.sdi` | Manual upload | RAM-disk System Deployment Image |

## Configuration

### deploy-config.json

Central configuration for both network and USB deployment:

```json
{
    "github": {
        "owner": "araduti",
        "repo": "TCGCloud_2.1.1",
        "releaseTag": "latest"
    },
    "bootMedia": {
        "wimFileName": "boot.wim",
        "sdiFileName": "boot.sdi",
        "scriptsPackage": "tcgcloud-scripts.zip"
    },
    "defaults": {
        "osVersion": "Windows 11",
        "osBuild": "24H2",
        "osEdition": "Enterprise",
        "osActivation": "Volume",
        "osLanguage": "en-us"
    }
}
```

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

## OSDCloud Dependency Summary

This project currently depends on the [OSDCloud](https://www.osdcloud.com/) PowerShell module for several core functions. The network deployment path reduces this dependency — `_init.ps1` now gracefully handles the absence of the OSD module by falling back to native networking.

| OSDCloud Function | Where Used | Purpose | Network Mode |
|---|---|---|---|
| `New-OSDCloudTemplate` | Setup-OSDCloudUSB.ps1 | Creates WinPE template with drivers | Not needed |
| `Get-OSDCloudTemplate` | Setup-OSDCloudUSB.ps1 | Checks for existing template | Not needed |
| `New-OSDCloudWorkspace` | Setup-OSDCloudUSB.ps1 | Creates deployment workspace structure | Not needed |
| `New-OSDCloudUSB` | Setup-OSDCloudUSB.ps1 | Formats USB and copies boot media | Not needed |
| `Edit-OSDCloudWinPE` | Setup-OSDCloudUSB.ps1 | Customizes WinPE (wallpaper, drivers, WiFi) | Not needed |
| `Update-OSDCloudUSB` | Setup-OSDCloudUSB.ps1 | Adds OS installation files to USB | Not needed |
| `Import-Module OSD` | _init.ps1, Show-OSDCloudOverlay.ps1 | Core OSD helper functions in WinPE | Optional (graceful fallback) |
| `Start-OSDCloud` | Show-OSDCloudOverlay.ps1 | Executes Windows image deployment | Still required |
| `Start-WinREWiFi` | _init.ps1 | WiFi connection in WinPE | Replaced by netsh fallback |

See [OSDCLOUD_REPLACEMENT_PLAN.md](OSDCLOUD_REPLACEMENT_PLAN.md) for the full migration strategy.

## Improvement Opportunities

### Security
- ~~**Client secret in source code**~~ ✅ Resolved — credentials now read from environment variables (`TCG_TENANT_ID`, `TCG_CLIENT_ID`, `TCG_CLIENT_SECRET`)
- **Input validation** — Autopilot registration form fields lack sanitization

### Code Quality
- ~~**Duplicate logging modules**~~ ✅ Resolved — `Logging.psm1` is now a thin compatibility wrapper that delegates to `TCGLogging.psm1`
- **Duplicate code blocks** — `Show-OSDCloudOverlay.ps1` has two near-identical deployment blocks (registered vs unregistered paths); refactor into a shared function
- ~~**Duplicate `Copy-OfficeSources.ps1`**~~ ✅ Resolved — shared implementation in `Scripts/Shared/Copy-OfficeSources.ps1`; both SetupComplete and OOBE entry points delegate to it
- **Large monolithic scripts** — `Setup-OSDCloudUSB.ps1` (2,170 lines) and `Show-OSDCloudOverlay.ps1` (1,000+ lines) could be modularized

### Reliability
- **Error recovery** — Some error paths silently continue; add structured retry logic
- **Disk function edge cases** — RAID detection relies on friendly name matching (`PERC`, `MegaRAID`, `LSI`); may miss newer controllers

### Maintainability
- ~~**No tests**~~ ✅ Resolved — Pester test scaffolding added in `Tests/` for TCGCloud module and security checks
- **Version tracking** — No version metadata beyond the repo name

## License

Internal use — Thomas Computing Group.
