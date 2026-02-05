#================================================
# ae-main.ps1 - Production-ready OSDCloud + Autopilot
#================================================

#-----------------------------------------------
# Load GitHub menus and functions
#-----------------------------------------------
Set-ExecutionPolicy Bypass -Force
iex (irm "https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1")
Start-Sleep -Seconds 3
iex (irm "https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1")
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
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
if ($DriverPack) { $Global:MyOSDCloud.DriverPackName = $DriverPack.Name }

#================================================
# AUTOPILOT PRE-PROVISIONING (WINPE SAFE)
#================================================

#-----------------------------------------------
# Ensure $GroupTag exists in memory (from menu)
#-----------------------------------------------
if (-not $GroupTag) { throw "GroupTag missing – check ae-ap-menu.ps1" }

#-----------------------------------------------
# Load credentials from USB (never C:)
#-----------------------------------------------
$OSDCloudUSB = Get-Volume.usb | Where-Object { $_.FileSystemLabel -match 'OSDCloud' } | Select-Object -First 1
if (-not $OSDCloudUSB) { throw "OSDCloud USB not found" }

$CredPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\Config\AutopilotCredentials.ps1"
if (!(Test-Path $CredPath)) { throw "AutopilotCredentials.ps1 missing on USB" }

. $CredPath

#-----------------------------------------------
# Import required modules
#-----------------------------------------------
# NuGet provider
Install-PackageProvider -Name NuGet -Force -Confirm:$false

# OSDCloud helper module
$ModulePath = (Get-ChildItem -Path "$($Env:ProgramFiles)\WindowsPowerShell\Modules\osd" |
    Where-Object {$_.Attributes -match "Directory"} | Select-Object -Last 1).FullName
Import-Module "$ModulePath\OSD.psd1" -Force

# Windows AutoPilot module
Import-Module WindowsAutoPilotIntune -Force

#-----------------------------------------------
# Gather device info
#-----------------------------------------------
$SerialNumber = (Get-CimInstance Win32_BIOS).SerialNumber

# Connect to Graph
Connect-MSGraphApp -Tenant $Tenant -AppId $ClientId -AppSecret $ClientSecret
Set-Location "C:\Program Files\WindowsPowerShell\Scripts"

#-----------------------------------------------
# Upload hash if device not known
#-----------------------------------------------
if (!(Get-AutopilotDevice -Serial $SerialNumber)) {
    Write-Host "Uploading Autopilot hardware hash..."
    ./Get-WindowsAutoPilotInfo.ps1 `
        -Online `
        -GroupTag $GroupTag `
        -TenantId $Tenant `
        -AppId $ClientId `
        -AppSecret $ClientSecret

    Write-Host "Waiting 2 minutes for Autopilot backend propagation..."
    Start-Sleep -Seconds 120
}

#-----------------------------------------------
# Always assign profile (idempotent)
#-----------------------------------------------
Write-Host "Assigning Autopilot profile..."
./Get-WindowsAutoPilotInfo.ps1 `
    -Online `
    -Assign `
    -GroupTag $GroupTag `
    -TenantId $Tenant `
    -AppId $ClientId `
    -AppSecret $ClientSecret

#================================================
# START OSDCloud deployment
#================================================
Write-Host "Starting OSDCloud..." -ForegroundColor Green
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

#-----------------------------------------------
# Persist GroupTag to C: for SetupComplete & logging
#-----------------------------------------------
$GroupTag | Out-File "C:\Windows\DeviceType.txt" -Encoding ASCII -Force

#-----------------------------------------------
# Copy CMTrace locally (optional)
#-----------------------------------------------
if (Test-Path "x:\windows\system32\cmtrace.exe") {
    Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe"
}

#-----------------------------------------------
# SetupComplete creation
#-----------------------------------------------
Set-SetupCompleteOSDCloudUSB

#-----------------------------------------------
# Save Windows image on USB if needed
#-----------------------------------------------
$DriverPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\OS\"
if (!(Test-Path $DriverPath)) { New-Item -ItemType Directory -Path $DriverPath }

$ImageFileName = Get-ChildItem -Path $DriverPath -Name *.esd
$ImageFileNameDL = Get-ChildItem -Path 'C:\OSDCloud\OS' -Name *.esd

if ($ImageFileName -ne $ImageFileNameDL) {
    Remove-Item -Path $DriverPath$ImageFileName -Force
    Copy-Item -Path "C:\OSDCloud\OS\$ImageFileNameDL" -Destination $DriverPath$ImageFileNameDL -Force
}

#-----------------------------------------------
# Restart to continue deployment
#-----------------------------------------------
Restart-Computer -Force
