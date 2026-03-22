@echo off
echo [%date% %time%] Starting SetupComplete processes >> %WINDIR%\Logs\SetupComplete.log

echo [%date% %time%] Ensuring network services are running >> %WINDIR%\Logs\SetupComplete.log
sc start dhcp >> %WINDIR%\Logs\SetupComplete.log
sc start dnscache >> %WINDIR%\Logs\SetupComplete.log
sc start nlasvc >> %WINDIR%\Logs\SetupComplete.log

REM Initialize Office deployment
echo [%date% %time%] Initializing Office deployment... >> %WINDIR%\Logs\SetupComplete.log
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Copy-OfficeSources.ps1" >> %WINDIR%\Logs\OfficeCopy-SetupComplete.log 2>&1

REM Run Windows Updates
echo [%date% %time%] Running Windows Updates >> %WINDIR%\Logs\SetupComplete.log
powershell.exe -ExecutionPolicy Bypass -File "%~dp0SetupComplete.ps1" >> %WINDIR%\Logs\SetupComplete.log 2>&1

REM Clean up OSDCloud folders
echo [%date% %time%] Cleaning up OSDCloud folders >> %WINDIR%\Logs\SetupComplete.log
powershell.exe -ExecutionPolicy Bypass -Command "Remove-Item -Path 'C:\OSDCloud' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -Path 'C:\ProgramData\OSDCloud' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -Path 'C:\Temp\OSDCloud' -Recurse -Force -ErrorAction SilentlyContinue" >> %WINDIR%\Logs\OSDCloud-Cleanup.log 2>&1

echo [%date% %time%] SetupComplete finished >> %WINDIR%\Logs\SetupComplete.log