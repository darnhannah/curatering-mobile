# Build customer + staff release APKs and zip them for Google Drive sharing.
# Run from repo root or this folder:
#   powershell -ExecutionPolicy Bypass -File packages/frontend/scripts/build_release_apks.ps1

$ErrorActionPreference = "Stop"
$frontendRoot = Split-Path -Parent $PSScriptRoot
Set-Location $frontendRoot

$dist = Join-Path $frontendRoot "dist"
$apkOut = Join-Path $frontendRoot "build\app\outputs\flutter-apk"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Test-ApkFile([string]$path) {
    if (-not (Test-Path $path)) {
        throw "APK not found: $path"
    }
    $len = (Get-Item $path).Length
    if ($len -lt 1MB) {
        throw "APK looks too small ($len bytes): $path — build may have failed."
    }
    # APK files start with PK (zip archive).
    $bytes = [byte[]](Get-Content -Path $path -Encoding Byte -TotalCount 2)
    if ($bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
        throw "File is not a valid APK (missing PK header): $path"
    }
    return $len
}

Write-Host "Building CUSTOMER release APK..."
flutter build apk --flavor customer --release `
    --dart-define=APP_FLAVOR=customer
$customerApk = Join-Path $apkOut "app-customer-release.apk"
$customerBytes = Test-ApkFile $customerApk
$customerDist = Join-Path $dist "curatering-customer-release.apk"
Copy-Item -Force $customerApk $customerDist
$customerZip = Join-Path $dist "curatering-customer-release.zip"
if (Test-Path $customerZip) { Remove-Item -Force $customerZip }
Compress-Archive -Path $customerDist -DestinationPath $customerZip
Write-Host "  OK  $customerDist  ($([math]::Round($customerBytes/1MB, 2)) MB)"
Write-Host "  ZIP $customerZip"

Write-Host ""
Write-Host "Building STAFF release APK..."
flutter build apk --flavor staff --release `
    --dart-define=APP_FLAVOR=staff `
    --dart-define=POS_LOGIN=true
$staffApk = Join-Path $apkOut "app-staff-release.apk"
$staffBytes = Test-ApkFile $staffApk
$staffDist = Join-Path $dist "curatering-staff-release.apk"
Copy-Item -Force $staffApk $staffDist
$staffZip = Join-Path $dist "curatering-staff-release.zip"
if (Test-Path $staffZip) { Remove-Item -Force $staffZip }
Compress-Archive -Path $staffDist -DestinationPath $staffZip
Write-Host "  OK  $staffDist  ($([math]::Round($staffBytes/1MB, 2)) MB)"
Write-Host "  ZIP $staffZip"

Write-Host ""
Write-Host "Done. Upload the .zip files to Google Drive (recommended) or the .apk files."
Write-Host "On Android, open the .zip in Drive, extract, then install the .apk."
Write-Host "Enable 'Install unknown apps' for Drive or Files if prompted."
