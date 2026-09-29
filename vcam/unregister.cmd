@echo off
setlocal
rem Unregisters the vvvv virtual camera media source. Must run as administrator.

net session >nul 2>&1
if errorlevel 1 (
    echo This script must be run as administrator.
    pause
    exit /b 1
)

set TARGET=%ProgramData%\vvvv\VirtualCamera

if exist "%TARGET%\VL.Video.VCamSource.dll" (
    "%SystemRoot%\System32\regsvr32.exe" /u "%TARGET%\VL.Video.VCamSource.dll"
    del /q "%TARGET%\VL.Video.VCamSource.dll"
) else (
    echo Nothing to unregister at "%TARGET%".
)

echo Done.
pause
