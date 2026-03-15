@echo off
setlocal

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File ".\scripts\deploy_release_to_phone.ps1" -LaunchAfterInstall

if errorlevel 1 (
  echo Deployment failed.
  exit /b 1
)

echo Deployment complete.
exit /b 0
