#-----------------------------------------------
# Load GitHub functions and menus
#-----------------------------------------------
Set-ExecutionPolicy Bypass -Force
iex (irm https://raw.githubusercontent.com/MSP-AVG/AE/refs/heads/main/ae-ap-menu.ps1)
sleep -Seconds 3
iex (irm https://raw.githubusercontent.com/MSP-AVG/AE/refs/heads/main/ae-functions.ps1)
Set-ExecutionPolicy Bypass -Force

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

# Set OSDCloud variables
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

# Determine driver pack
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
if ($DriverPack){ $Global:MyOSDCloud.DriverPackName = $DriverPack.Name }

#-----------------------------------------------
# Upload Autopilot hash + assign profile safely
#-----------------------------------------------

# Load local credentials (not in GitHub)
. "C:\OSDCloud\Config\AutopilotCredentials.ps1"

# Define GroupTag
$GroupTag = Get-Content "C:\Windows\DeviceType.txt"

# Save GroupTag locally for SetupComplete
$GroupTag | Out-File -FilePath C:\Windows\DeviceType.txt

# Get serial number
$SerialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber

# Connect to MS Graph
Connect-MSGraphApp -Tenant $Tenant -AppId $ClientId -AppSecret $ClientSecret

# Check if device exists in Autopilot
if (!(Get-AutopilotDevice -Serial $SerialNumber)) {
    Write-Host "Device not yet known in Autopilot – uploading hash and setting GroupTag"
    Set-Location "C:\Program Files\WindowsPowerShell\Scripts"
    ./Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag $GroupTag -TenantId $Tenant -AppId $ClientId -AppSecret $ClientSecret
    #-----------------------------------------------
    # Delay to give backend time before -Assign
    #-----------------------------------------------
    Write-Host "Waiting 2 minutes for Autopilot backend to propagate..."
    Start-Sleep -Seconds 120

    # Assign profile now that backend has processed hash + tag
    Write-Host "Assigning Autopilot profile..."
    ./Get-WindowsAutoPilotInfo.ps1 -Online -Assign -GroupTag $GroupTag -TenantId $Tenant -AppId $ClientId -AppSecret $ClientSecret
} else {
    Write-Host "Device already known in Autopilot – skipping upload"
}

#-----------------------------------------------
# Continue OSDCloud deployment
#-----------------------------------------------
Write-Host "Starting OSDCloud" -ForegroundColor Green
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

# Copy CMTrace locally
if (Test-Path "x:\windows\system32\cmtrace.exe") {
    Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe"
}

# Create SetupComplete for OSDCloud USB
Set-SetupCompleteOSDCloudUSB

# Save Windows image on USB if needed (existing logic)
$OSDCloudUSB = Get-Volume.usb | Where-Object {($_.FileSystemLabel -match 'OSDCloud') -or ($_.FileSystemLabel -match 'BHIMAGE')} | Select-Object -First 1
$DriverPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\OS\"
if (!(Test-Path $DriverPath)){ New-Item -ItemType Directory -Path $DriverPath }
$ImageFileName = Get-ChildItem -Path $DriverPath -Name *.esd
$ImageFileNameDL = Get-ChildItem -Path 'C:\OSDCloud\OS' -Name *.esd
if($ImageFileName -ne $ImageFileNameDL){
    Remove-Item -Path $DriverPath$ImageFileName -Force
    Copy-Item -Path "C:\OSDCloud\OS\$ImageFileNameDL" -Destination $DriverPath$ImageFileNameDL -Force
}

# Restart computer to continue deployment
Restart-Computer
