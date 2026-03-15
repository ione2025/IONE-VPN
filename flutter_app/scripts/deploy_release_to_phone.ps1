param(
  [string]$DeviceId = "",
  [switch]$LaunchAfterInstall
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

$localProps = Join-Path $projectRoot "android\local.properties"
$adb = ""

if (Test-Path $localProps) {
  $sdkLine = Select-String -Path $localProps -Pattern '^sdk.dir=' | Select-Object -First 1
  if ($sdkLine) {
    $sdkDir = $sdkLine.Line.Substring(8) -replace '\\\\', '\\'
    $adbCandidate = Join-Path $sdkDir "platform-tools\adb.exe"
    if (Test-Path $adbCandidate) {
      $adb = $adbCandidate
    }
  }
}

if (-not $adb) {
  $adb = "adb"
}

Write-Host "==> Checking connected Android devices..."
$deviceList = & $adb devices
$deviceList | Out-Host

$onlineDevices = @(
  $deviceList |
    Select-Object -Skip 1 |
    Where-Object { $_ -match '\S+\s+device$' } |
    ForEach-Object { ($_ -split '\s+')[0] }
)

if ($onlineDevices.Count -eq 0) {
  throw "No Android device detected in ADB. Connect phone, enable USB debugging, and accept RSA prompt."
}

if ($DeviceId -and -not ($onlineDevices -contains $DeviceId)) {
  throw "Specified device '$DeviceId' is not online."
}

$adbArgsPrefix = @()
if ($DeviceId) {
  $adbArgsPrefix = @("-s", $DeviceId)
} elseif ($onlineDevices.Count -eq 1) {
  $adbArgsPrefix = @("-s", $onlineDevices[0])
}

Write-Host "==> Resolving Flutter dependencies..."
flutter pub get

Write-Host "==> Building release APK..."
flutter build apk --release

$apk = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apk)) {
  throw "Release APK not found at $apk"
}

Write-Host "==> Installing APK on phone..."
& $adb @adbArgsPrefix install -r $apk

if ($LASTEXITCODE -ne 0) {
  throw "APK install failed with exit code $LASTEXITCODE"
}

if ($LaunchAfterInstall) {
  Write-Host "==> Launching app..."
  & $adb @adbArgsPrefix shell monkey -p com.ione.vpn -c android.intent.category.LAUNCHER 1 | Out-Null
}

Write-Host "==> Done. Latest release APK installed successfully."
