<#
Loads Functions
Creates Setup Complete Files
#>

Set-ExecutionPolicy Bypass -Force
iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1)

Write-Host -Foreground Red $GroupTag
sleep -Seconds 3

iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1)

#++++++++++++++++++++++++++++++
# Functions were here !!
#++++++++++++++++++++++++++++++

Set-ExecutionPolicy Bypass -Force


 =====================================
# WINPE STUFF
# Runs only when Drive = X:
# =====================================
if ($env:SystemDrive -eq 'X:') {

    # (your GitHub logic here that defines $GroupTag)
    Write-Host -Foreground Red $GroupTag

    # Find USB
    $USB = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' } | Select-Object -First 1

    if ($USB) {
        # Autopilot script location
        $APS = "$($USB.DriveLetter):\Autopilot\Register-Autopilot.ps1"

        if (Test-Path $APS) {
            Write-Host "Running Autopilot Registration using GroupTag: $GroupTag" -ForegroundColor Green

            # THIS IS THE ONLY LINE YOU ASKED ABOUT
            PowerShell.exe -ExecutionPolicy Bypass -File $APS -GroupTag $GroupTag
            Start-Sleep -Seconds 5
        }
        else {
            Write-Host "Register-Autopilot.ps1 not found on USB" -ForegroundColor Yellow
        }
    }
}
#Variables to define the Windows OS / Edition etc to be applied during OSDCloud
$Product = (Get-MyComputerProduct)
$OSVersion = 'Windows 11' #Used to Determine Driver Pack
$OSReleaseID = '24H2' #Used to Determine Driver Pack
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage = 'nl-NL'


#Set OSDCloud Vars
$Global:MyOSDCloud = [ordered]@{
    Restart = [bool]$False
    RecoveryPartition = [bool]$true
    OEMActivation = [bool]$True
    WindowsUpdate = [bool]$true
    WindowsUpdateDrivers = [bool]$false
    WindowsDefenderUpdate = [bool]$true
    SetTimeZone = [bool]$true
    ClearDiskConfirm = [bool]$False
    ShutdownSetupComplete = [bool]$true
    SyncMSUpCatDriverUSB = [bool]$true
   }

#Used to Determine Driver Pack
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID

if ($DriverPack){
    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
}

<#
#Enable HPIA | Update HP BIOS | Update HP TPM 
if (Test-HPIASupport){
    #$Global:MyOSDCloud.DevMode = [bool]$True
    $Global:MyOSDCloud.HPTPMUpdate = [bool]$True
    if ($Product -ne '83B2'){$Global:MyOSDCloud.HPIAALL = [bool]$true} #I've had issues with this device and HPIA
    $Global:MyOSDCloud.HPBIOSUpdate = [bool]$true

    #Set HP BIOS Settings to what I want:
    iex (irm https://raw.githubusercontent.com/MSP-AVG/AE/refs/heads/main/ae-Manage-HPBiosSettings.ps1)
    Manage-HPBiosSettings -SetSettings
}
#>

#write variables to console
Write-Output $Global:MyOSDCloud

#Update Files in Module that have been updated since last PowerShell Gallery Build (Testing Only)
$ModulePath = (Get-ChildItem -Path "$($Env:ProgramFiles)\WindowsPowerShell\Modules\osd" | Where-Object {$_.Attributes -match "Directory"} | select -Last 1).fullname
import-module "$ModulePath\OSD.psd1" -Force

#Launch OSDCloud
Write-Host "Starting OSDCloud" -ForegroundColor Green
write-host "Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage"

Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

write-host "OSDCloud Process Complete, Running Custom Actions From Script Before Reboot" -ForegroundColor Green



#Copy CMTrace Local:
if (Test-path -path "x:\windows\system32\cmtrace.exe"){
    copy-item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe"
}

$GroupTag | Out-File -FilePath C:\Windows\DeviceType.txt

Set-SetupCompleteOSDCloudUSB

#Save Windows Image on USB 
$OSDCloudUSB = Get-Volume.usb | Where-Object {($_.FileSystemLabel -match 'OSDCloud') -or ($_.FileSystemLabel -match 'BHIMAGE')} | Select-Object -First 1
$DriverPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\OS\"
if (!(Test-Path $DriverPath)){New-Item -ItemType Directory -Path $DriverPath}
$ImageFileName = Get-ChildItem -Path $DriverPath -Name *.esd
$ImageFileNameDL = Get-ChildItem -Path 'C:\OSDCloud\OS' -Name *.esd 

if($ImageFileName -ne $ImageFileNameDL){
    Remove-Item -Path $DriverPath$ImageFileName -Force
if (!(Test-Path $DriverPath)){New-Item -ItemType Directory -Path $DriverPath}
if (!(Test-Path $DriverPath$ImageFileNameDL)){Copy-Item -Path C:\OSDCloud\OS\$ImageFileNameDL -Destination $DriverPath$ImageFileNameDL -Force}
}
#===================

Restart-Computer
}
