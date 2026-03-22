@echo off
echo [%date% %time%] Starting OOBE processes >> C:\Windows\Logs\OOBE-Setup.log

REM Run PowerShell script for Windows updates, drivers, and Store apps
start /wait powershell.exe -NoL -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\OOBE\OOBEDeploy.ps1

exit