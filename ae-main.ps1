#================================================
# ae-main.ps1 - Production-ready OSDCloud + Autopilot (Hardened)
#================================================
# Author: Mark Vermue (Support Engineer 2e lijn)
# Last updated: 2026-02-05
# Notes:
#   - Loads menu/functions from GitHub (validated)
#   - Validates GroupTag (supports $Global:GroupTag from caller)
#   - Loads credentials from OSDCloud USB
#   - Connects to Graph via WindowsAutoPilotIntune (App secret by default)
#   - Uploads hash (if unknown), assigns Autopilot profile, retries gracefully
#   - Launches OSDCloud deployment
#   - Persists GroupTag + optional CMTrace copy
#   - Saves Windows image to USB (single .esd copy) if needed
#   - Restarts to continue OSDCloud task sequence
#================================================

#region --- Global Preferences & Logging ---
$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'Continue'

# Folders / files
$LogFolder = 'C:\OSDCloud\Logs'
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
$LogFile   = Join-Path $LogFolder 'ae-main.log'

Function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Tee-Object -FilePath $LogFile -Append
}

# Start transcript (best-effort)
try {
    Start-Transcript -Path (Join-Path $LogFolder 'Transcript.txt') -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Log "Failed to start transcript: $($_.Exception.Message)" 'WARN'
}

$ScriptStart = Get-Date
Write-Log '================================================' 'DEBUG'
Write-Log "Script start: $($ScriptStart.ToString('s'))" 'INFO'
Write-Log '================================================' 'DEBUG'
#endregion

#region --- Helpers ---
# Hardened remote script loader (basic safety checks)
Function Invoke-RemoteScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    try {
        Write-Log "Downloading remote script: $Url" 'INFO'
        $content = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop

        # Basic sanity checks to avoid accidentally running HTML/garbage
        if ($null -eq $content -or $content.Trim().Length -lt 10) {
            Write-Log "Empty or too-short content from $Url" 'ERROR'
            throw "Invalid content"
        }
        if ($content -match '<html|<!DOCTYPE|<head|<body') {
            Write-Log "Downloaded content appears to be HTML, refusing to execute: $Url" 'ERROR'
            throw "Unexpected HTML content"
        }

        if ($content -notmatch 'function|param|#' -and $content.Length -lt 200) {
            Write-Log "Downloaded content does not look like PowerShell script: $Url" 'ERROR'
            throw "Suspicious content"
        }

        # Execute
        Invoke-Expression $content
        Write-Log "Successfully loaded script: $Url" 'INFO'
    }
    catch {
        Write-Log "Failed to load script $Url: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

# Internet reachability check (Graph endpoints)
Function Test-Internet {
    [CmdletBinding()]
    param(
        [string[]]$Targets = @('login.microsoftonline.com','graph.microsoft.com','www.microsoft.com'),
        [int]$TimeoutSeconds = 5
    )
    foreach ($t in $Targets) {
        try {
            # Prefer Test-NetConnection if available
            if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
                $r = Test-NetConnection -ComputerName $t -WarningAction SilentlyContinue
                if ($r.PingSucceeded -or $r.TcpTestSucceeded) { return $true }
            }
            else {
                $ok = Test-Connection -ComputerName $t -Count 1 -Quiet -TimeoutSeconds $TimeoutSeconds
                if ($ok) { return $true }
            }
        } catch { }
    }
    return $false
}

# Safer USB discovery that matches label AND required folder structure
Function Get-OSDCloudUSB {
    [CmdletBinding()]
    param()

    # Prefer OSD helper if present
    $usbVol = $null
    if (Get-Command Get-Volume.usb -ErrorAction SilentlyContinue) {
        $usbVol = Get-Volume.usb | Where-Object {
            $_.FileSystemLabel -match 'OSDCloud'
        } | Select-Object -First 1
    }

    # Fallback
    if (-not $usbVol) {
        $usbVol = Get-Volume | Where-Object {
            $_.DriveType -eq 'Removable' -and $_.FileSystemLabel -match 'OSDCloud'
        } | Select-Object -First 1
    }

    if ($usbVol) {
        $root = "$($usbVol.DriveLetter):\OSDCloud"
        if (Test-Path (Join-Path $root 'Config')) { return $usbVol }
    }
    return $null
}
#endregion

#region --- Load GitHub Menus & Functions ---
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
    Invoke-RemoteScript 'https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1'
    Start-Sleep -Seconds 2
    Invoke-RemoteScript 'https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1'
    Write-Log 'Remote menus/functions loaded' 'INFO'
}
catch {
    Write-Log "Failed to load remote menus/functions: $($_.Exception.Message)" 'ERROR'
    throw
}
#endregion

#region --- OSD Variables ---
$Product      = $null
try {
    $Product = Get-MyComputerProduct
    Write-Log "Detected Product: $Product" 'INFO'
} catch {
    Write-Log "Failed to detect Product: $($_.Exception.Message)" 'WARN'
}
$OSVersion    = 'Windows 11'
$OSReleaseID  = '24H2'
$OSName       = 'Windows 11 24H2 x64'
$OSEdition    = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage   = 'nl-NL'

# OSDCloud global settings
$Global:MyOSDCloud = [ordered]@{
    Restart                = $false
    RecoveryPartition      = $true
    OEMActivation          = $true
    WindowsUpdate          = $true
    WindowsUpdateDrivers   = $false
    WindowsDefenderUpdate  = $true
    SetTimeZone            = $true
    ClearDiskConfirm       = $false
    ShutdownSetupComplete  = $true
    SyncMSUpCatDriverUSB   = $true
}
#endregion

#region --- Driver Pack Resolution ---
try {
    $DriverPack = $null
    if ($Product) {
        $DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID -ErrorAction Stop
        if ($DriverPack) {
            $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
            Write-Log "Driver pack selected: $($DriverPack.Name)" 'INFO'
        } else {
            Write-Log 'No matching driver pack found' 'WARN'
        }
    } else {
        Write-Log 'Skipping driver pack detection (no Product)' 'WARN'
    }
}
catch {
    Write-Log "Failed to get driver pack: $($_.Exception.Message)" 'ERROR'
}
#endregion

#region --- GroupTag Validation (supports caller's global) ---
if (-not $GroupTag -and $Global:GroupTag) { $GroupTag = $Global:GroupTag }
if (-not $GroupTag) {
    Write-Log 'GroupTag missing – cannot continue. Ensure ae-ap-menu.ps1 sets GroupTag.' 'ERROR'
    throw "GroupTag missing"
}
Write-Log "Using GroupTag: $GroupTag" 'INFO'
#endregion

#region --- Load Credentials from USB ---
$OSDCloudUSB = $null
try {
    $OSDCloudUSB = Get-OSDCloudUSB
    if (-not $OSDCloudUSB) { throw "OSDCloud USB not found (label 'OSDCloud' with \OSDCloud\Config expected)" }

    $CredPath = "{0}:\OSDCloud\Config\AutopilotCredentials.ps1" -f $OSDCloudUSB.DriveLetter
    if (-not (Test-Path $CredPath)) { throw "AutopilotCredentials.ps1 missing on USB ($CredPath)" }

    Write-Log "Loading Autopilot credentials from: $CredPath" 'INFO'
    . $CredPath

    # Basic validation of required variables
    foreach ($name in @('Tenant','ClientId','ClientSecret')) {
        if (-not (Get-Variable -Name $name -Scope Script,Global -ErrorAction SilentlyContinue)) {
            Write-Log "Credential variable `$${name} not defined by credentials script" 'ERROR'
            throw "Missing `$${name}"
        }
    }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
#endregion

#region --- Import Required Modules (OSD + WindowsAutoPilotIntune) ---
try {
    Install-PackageProvider -Name NuGet -Force -Confirm:$false | Out-Null

    # Import latest OSD module
    $osdMod = Get-Module -ListAvailable -Name OSD | Sort-Object Version -Descending | Select-Object -First 1
    if ($osdMod) {
        Import-Module $osdMod -Force -ErrorAction Stop
        Write-Log "Imported OSD module v$($osdMod.Version)" 'INFO'
    } else {
        Write-Log 'OSD module not found. Ensure OSD is present in WinPE environment.' 'ERROR'
        throw
    }

    # WindowsAutoPilotIntune
    Import-Module WindowsAutoPilotIntune -Force -ErrorAction Stop
    Write-Log 'Imported WindowsAutoPilotIntune module' 'INFO'
}
catch {
    Write-Log "Failed to import modules: $($_.Exception.Message)" 'ERROR'
    throw
}
#endregion

#region --- Gather Device Info ---
$SerialNumber = $null
try {
    $SerialNumber = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    Write-Log "Device SerialNumber: $SerialNumber" 'INFO'
}
catch {
    Write-Log "Failed to get SerialNumber: $($_.Exception.Message)" 'ERROR'
}
#endregion

#region --- Internet Connectivity Check ---
if (-not (Test-Internet)) {
    Write-Log 'No internet connectivity detected to Microsoft endpoints. Autopilot upload/assignment will fail.' 'ERROR'
    throw "Internet connectivity required"
}
#endregion

#region --- Connect to Graph (App Secret) ---
try {
    # NOTE: For higher security, prefer certificate auth stored on USB or injected in WinPE
    # If your environment supports it, adjust to use certificate parameters instead.
    Connect-MSGraphApp -Tenant $Tenant -AppId $ClientId -AppSecret $ClientSecret -ErrorAction Stop
    Write-Log 'Connected to Microsoft Graph (app-only)' 'INFO'
}
catch {
    Write-Log "Failed to connect to MS Graph: $($_.Exception.Message)" 'ERROR'
    throw
}
#endregion

#region --- Locate Get-WindowsAutoPilotInfo.ps1 ---
$APScript = $null
try {
    # Try to resolve via command
    $APScript = (Get-Command -Name Get-WindowsAutoPilotInfo.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $APScript) {
        # Fallback to common scripts location
        $cand = 'C:\Program Files\WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1'
        if (Test-Path $cand) { $APScript = $cand }
    }
    if (-not (Test-Path $APScript)) {
        Write-Log 'Autopilot info script not found (Get-WindowsAutoPilotInfo.ps1)' 'ERROR'
        throw
    }
    Write-Log "Using Autopilot info script: $APScript" 'INFO'
}
catch {
    Write-Log "Failed to locate Autopilot info script: $($_.Exception.Message)" 'ERROR'
