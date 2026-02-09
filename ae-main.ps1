<#
Loads Functions
Creates Setup Complete Files
#>

Set-ExecutionPolicy Bypass -Force

iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-ap-menu.ps1)

Write-Host -Foreground Red $GroupTag
Start-Sleep -Seconds 3

iex (irm https://raw.githubusercontent.com/MSP-AVG/AE-test/refs/heads/main/ae-functions.ps1)

Set-ExecutionPolicy Bypass -Force


# =====================================
# WINPE STUFF  (CORRECTED + SIMPLE)
# =====================================
if ($env:SystemDrive -eq 'X:') {

    Write-Host "WinPE detected" -ForegroundColor Cyan
    Write-Host "Using GroupTag: $GroupTag" -ForegroundColor Yellow

    # Find USB drive
    $USB = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' } | Select-Object -First 1

    if ($USB) {
        $APS = "$($USB.DriveLetter):\OSDCloud\Config\Scripts\Register-Autopilot.ps1"

        if (Test-Path $APS) {
            Write-Host "Running Autopilot Registration" -ForegroundColor Green
            PowerShell.exe -ExecutionPolicy Bypass -File $APS -GroupTag $GroupTag
            Start-Sleep -Seconds 5
        }
        else {
            Write-Host "Register-Autopilot.ps1 not found on USB" -ForegroundColor Red
        }
    }
    else {
        Write-Host "No USB Drive Found" -ForegroundColor Red
    }
}


# =====================================
# CONTINUE WITH NORMAL OSDCLOUD
# (this MUST be OUTSIDE the WinPE block)
# =====================================

#Variables to define the Windows OS / Edition etc to be applied during OSDCloud
$Product = (Get-MyComputerProduct)
$OSVersion = 'Windows 11'
$OSReleaseID = '24H2'
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Enterprise'
$OSActivation = 'Volume'
$OSLanguage = 'nl-NL'

#Set OSDCloud Vars
$Global:MyOSDCloud = [ordered]@{
    Restart = $False
    RecoveryPartition = $True
    OEMActivation = $True
    WindowsUpdate = $True
    WindowsUpdateDrivers = $False
    WindowsDefenderUpdate = $True
    SetTimeZone = $True
    ClearDiskConfirm = $False
    ShutdownSetupComplete = $True
    SyncMSUpCatDriverUSB = $True
}

#Used to Determine Driver Pack
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID
if ($DriverPack) { $Global:MyOSDCloud.DriverPackName = $DriverPack.Name }

Write-Output $Global:MyOSDCloud

#Import latest module
$ModulePath = (Get-ChildItem -Path "$($Env:ProgramFiles)\WindowsPowerShell\Modules\osd" | 
                Where-Object {$_.Attributes -match "Directory"} |
                Select-Object -Last 1).FullName
Import-Module "$ModulePath\OSD.psd1" -Force

#Launch OSDCloud
Write-Host "Starting OSDCloud" -ForegroundColor Green
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

Write-Host "OSDCloud Process Complete, Running Custom Actions" -ForegroundColor Green

#Copy CMTrace Local
if (Test-path "x:\windows\system32\cmtrace.exe") {
    Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System\cmtrace.exe"
}

$GroupTag | Out-File C:\Windows\DeviceType.txt

Set-SetupCompleteOSDCloudUSB

# Save Windows Image on USB
$OSDCloudUSB = Get-Volume.usb | Where-Object { $_.FileSystemLabel -match 'OSDCloud' -or $_.FileSystemLabel -match 'BHIMAGE' } | Select-Object -First 1
$DriverPath = "$($OSDCloudUSB.DriveLetter):\OSDCloud\OS\"
if (!(Test-Path $DriverPath)) { New-Item -ItemType Directory -Path $DriverPath }

$ImageFileName = Get-ChildItem -Path $DriverPath -Name *.esd
$ImageFileNameDL = Get-ChildItem -Path 'C:\OSDCloud\OS' -Name *.esd

if ($ImageFileName -ne $ImageFileNameDL) {
    Remove-Item -Path ($DriverPath + $ImageFileName) -Force
    Copy-Item -Path "C:\OSDCloud\OS\$ImageFileNameDL" -Destination $DriverPath -Force
}

Restart-Computer
