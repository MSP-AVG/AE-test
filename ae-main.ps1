#-----------------------------------------------
# Load GitHub functions and menus
#-----------------------------------------------
Set-ExecutionPolicy Bypass -Force
iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1)
sleep -Seconds 3
iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1)

#-----------------------------------------------
# Define OS variables for OSDCloud
#-----------------------------------------------
$Product = (Get-MyComputerProduct)
$OSVersion = 'Windows 11'
$OSReleaseID = '24H2'
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage = 'nl-NL'

#-----------------------------------------------
# OSDCloud variables
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
# Driver pack
#-----------------------------------------------
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
if ($DriverPack){ $Global:MyOSDCloud.DriverPackName = $DriverPack.Name }

#================================================
# AUTOPILOT (WINPE SAFE)
#================================================

# GroupTag already set by ae-ap-menu.ps1
if (-not $GroupTag) { throw "GroupTag missing" }

#-----------------------------------------------
# Load credentials from USB (NOT C:)
#-----------------------------------------------
$OSDCloudUSB = Get-Volume.usb | Where-Object FileSystemLabel -match 'OSDCloud' | Select-Object -First 1
$CredPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\Config\AutopilotCredentials.ps1"
. $CredPath

$SerialNumber = (Get-CimInstance Win32_BIOS).SerialNumber

Connect-MSGraphApp -Tenant $Tenant -AppId $ClientId -AppSecret $ClientSecret
Set-Location "C:\Program Files\WindowsPowerShell\Scripts"

#-----------------------------------------------
# Upload hash if needed
#-----------------------------------------------
if (!(Get-AutopilotDevice -Serial $SerialNumber)) {
    Write-Host "Uploading Autopilot hash..."
    ./Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag $GroupTag -TenantId $Tenant -AppId $ClientId -AppSecret $ClientSecret
    Start-Sleep -Seconds 120
}

#-----------------------------------------------
# ALWAYS assign (safe even if already assigned)
#-----------------------------------------------
Write-Host "Assigning Autopilot profile..."
./Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag $GroupTag -TenantId $Tenant -AppId $ClientId -AppSecret $ClientSecret

#================================================
# START DEPLOYMENT
#================================================

Write-Host "Starting OSDCloud" -ForegroundColor Green
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

#-----------------------------------------------
# NOW C: EXISTS → persist GroupTag for later use
#-----------------------------------------------
$GroupTag | Out-File "C:\Windows\DeviceType.txt" -Force

#-----------------------------------------------
# SetupComplete + tools
#-----------------------------------------------
if (Test-Path "x:\windows\system32\cmtrace.exe") {
    Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe"
}

Set-SetupCompleteOSDCloudUSB

Restart-Computer
