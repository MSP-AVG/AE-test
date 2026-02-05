#================================================
# ae-main.ps1 - Production-ready OSDCloud + Autopilot
#================================================

#-----------------------------------------------
# Setup logging & verbose preferences
#-----------------------------------------------
$LogFolder = "C:\OSDCloud\Logs"
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force }
$LogFile = "$LogFolder\ae-main.log"
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

Function Write-Log {
    param([string]$Message, [string]$Level="INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp [$Level] $Message" | Tee-Object -FilePath $LogFile -Append
}

#-----------------------------------------------
# Helper to safely invoke remote scripts
#-----------------------------------------------
Function Invoke-RemoteScript {
    param([string]$Url)
    Try {
        Write-Log "Downloading and invoking script: $Url"
        iex (irm $Url)
    }
    Catch {
        Write-Log "Failed to load script $Url: $($_.Exception.Message)" "ERROR"
        Throw
    }
}

#-----------------------------------------------
# Load GitHub menus and functions
#-----------------------------------------------
Set-ExecutionPolicy Bypass -Force
Invoke-RemoteScript "https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1"
Start-Sleep -Seconds 3
Invoke-RemoteScript "https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1"
Set-ExecutionPolicy Bypass -Force

#-----------------------------------------------
# Define OS variables for OSDCloud
#-----------------------------------------------
$Product = Get-MyComputerProduct
$OSVersion = 'Windows 11'
$OSReleaseID = '24H2'
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage = 'nl-NL'

#-----------------------------------------------
# OSDCloud global settings
#-----------------------------------------------
$Global:MyOSDCloud = [ordered]@{
    Restart = $false
    RecoveryPartition = $true
    OEMActivation = $true
    WindowsUpdate = $true
    WindowsUpdateDrivers = $false
    WindowsDefenderUpdate = $true
    SetTimeZone = $true
    ClearDiskConfirm = $false
    ShutdownSetupComplete = $true
    SyncMSUpCatDriverUSB = $true
}

#-----------------------------------------------
# Determine driver pack
#-----------------------------------------------
Try {
    $DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
    if ($DriverPack) { $Global:MyOSDCloud.DriverPackName = $DriverPack.Name }
    Write-Log "Driver pack selected: $($DriverPack.Name)"
}
Catch {
    Write-Log "Failed to get driver pack: $($_.Exception.Message)" "ERROR"
}

#================================================
# AUTOPILOT PRE-PROVISIONING (WINPE SAFE)
#================================================

#-----------------------------------------------
# Ensure $GroupTag exists
#-----------------------------------------------
if (-not $GroupTag) { 
    Write-Log "GroupTag missing – check ae-ap-menu.ps1" "ERROR"
    Throw "GroupTag missing – cannot continue"
}

#-----------------------------------------------
# Load credentials from USB
#-----------------------------------------------
Try {
    $OSDCloudUSB = Get-Volume.usb | Where-Object { $_.FileSystemLabel -match 'OSDCloud' } | Select-Object -First 1
    if (-not $OSDCloudUSB) { Throw "OSDCloud USB not found" }

    $CredPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\Config\AutopilotCredentials.ps1"
    if (!(Test-Path $CredPath)) { Throw "AutopilotCredentials.ps1 missing on USB" }

    Write-Log "Loading Autopilot credentials from USB"
    . $CredPath
}
Catch {
    Write-Log $_.Exception.Message "ERROR"
    Throw
}

#-----------------------------------------------
# Import required modules
#-----------------------------------------------
Try {
    Install-PackageProvider -Name NuGet -Force -Confirm:$false
    $ModulePath = (Get-ChildItem -Path "$($Env:ProgramFiles)\WindowsPowerShell\Modules\osd" |
        Where-Object {$_.Attributes -match "Directory"} | Select-Object -Last 1).FullName
    Import-Module "$ModulePath\OSD.psd1" -Force
    Import-Module WindowsAutoPilotIntune -Force
    Write-Log "Required modules imported"
}
Catch {
    Write-Log "Failed to import modules: $($_.Exception.Message)" "ERROR"
    Throw
}

#-----------------------------------------------
# Gather device info
#-----------------------------------------------
Try {
    $SerialNumber = (Get-CimInstance Win32_BIOS).SerialNumber
    Write-Log "Device SerialNumber: $SerialNumber"
}
Catch {
    Write-Log "Failed to get SerialNumber: $($_.Exception.Message)" "ERROR"
}

#-----------------------------------------------
# Connect to Graph
#-----------------------------------------------
Try {
    Connect-MSGraphApp -Tenant $Tenant -AppId $ClientId -AppSecret $ClientSecret
    Set-Location "C:\Program Files\WindowsPowerShell\Scripts"
    Write-Log "Connected to MS Graph"
}
Catch {
    Write-Log "Failed to connect to MS Graph: $($_.Exception.Message)" "ERROR"
    Throw
}

#-----------------------------------------------
# Upload hash if device not known
#-----------------------------------------------
Try {
    if (!(Get-AutopilotDevice -Serial $SerialNumber)) {
        Write-Log "Uploading Autopilot hardware hash..."
        ./Get-WindowsAutoPilotInfo.ps1 `
            -Online `
            -GroupTag $GroupTag `
            -TenantId $Tenant `
            -AppId $ClientId `
            -AppSecret $ClientSecret

        Write-Log "Waiting 2 minutes for Autopilot backend propagation..."
        Start-Sleep -Seconds 120
    }

    Write-Log "Assigning Autopilot profile..."
    ./Get-WindowsAutoPilotInfo.ps1 `
        -Online `
        -Assign `
        -GroupTag $GroupTag `
        -TenantId $Tenant `
        -AppId $ClientId `
        -AppSecret $ClientSecret
}
Catch {
    Write-Log "Autopilot upload/profile assignment failed: $($_.Exception.Message)" "ERROR"
    Throw
}

#================================================
# START OSDCloud deployment
#================================================
Try {
    Write-Host "Starting OSDCloud..." -ForegroundColor Green
    Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage -Verbose -ErrorAction Stop
    Write-Log "OSDCloud started successfully"
}
Catch {
    Write-Log "OSDCloud failed: $($_.Exception.Message)" "ERROR"
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $_ | Out-File "$LogFolder\StartOSDCloudError.txt" -Append
    Exit 1
}

#-----------------------------------------------
# Persist GroupTag to C: for SetupComplete & logging
#-----------------------------------------------
Try {
    $GroupTag | Out-File "C:\Windows\DeviceType.txt" -Encoding ASCII -Force
    Write-Log "GroupTag persisted to C:\Windows\DeviceType.txt"
}
Catch { Write-Log "Failed to persist GroupTag: $($_.Exception.Message)" "ERROR" }

#-----------------------------------------------
# Copy CMTrace locally (optional)
#-----------------------------------------------
Try {
    if (Test-Path "x:\windows\system32\cmtrace.exe") {
        Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe" -Force
        Write-Log "CMTrace copied locally"
    }
}
Catch { Write-Log "Failed to copy CMTrace: $($_.Exception.Message)" "ERROR" }

#-----------------------------------------------
# SetupComplete creation
#-----------------------------------------------
Try {
    Set-SetupCompleteOSDCloudUSB
    Write-Log "SetupComplete created successfully"
}
Catch { Write-Log "SetupComplete creation failed: $($_.Exception.Message)" "ERROR" }

#-----------------------------------------------
# Save Windows image on USB if needed
#-----------------------------------------------
Try {
    $DriverPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\OS\"
    if (!(Test-Path $DriverPath)) { New-Item -ItemType Directory -Path $DriverPath -Force }

    $ImageFileNameDL = Get-ChildItem -Path 'C:\OSDCloud\OS' -Name *.esd | Select-Object -First 1
    $ImageFileNameUSB = Get-ChildItem -Path $DriverPath -Name *.esd | Select-Object -First 1

    if ($ImageFileNameDL -and $ImageFileNameDL -ne $ImageFileNameUSB) {
        if ($ImageFileNameUSB) { Remove-Item -Path "$DriverPath$ImageFileNameUSB" -Force }
        Copy-Item -Path "C:\OSDCloud\OS\$ImageFileNameDL" -Destination "$DriverPath$ImageFileNameDL" -Force
        Write-Log "Windows image copied to USB"
    }
}
Catch { Write-Log "Failed to save Windows image: $($_.Exception.Message)" "ERROR" }

#-----------------------------------------------
# Restart to continue deployment
#-----------------------------------------------
Try {
    Write-Log "Restarting computer to continue deployment"
    Restart-Computer -Force
}
Catch { Write-Log "Restart failed: $($_.Exception.Message)" "ERROR" }
