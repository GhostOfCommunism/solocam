@echo off
setlocal
rem Registers the vvvv virtual camera media source. Must run as administrator.
rem
rem The DLL is copied to ProgramData because the Windows Frame Server service
rem (Local Service) cannot read files inside a user profile. Registering the DLL
rem from a user folder makes IMFVirtualCamera::Start fail with Access Denied.

net session >nul 2>&1
if errorlevel 1 (
    echo This script must be run as administrator.
    pause
    exit /b 1
)

if not exist "%~dp0VL.Video.VCamSource.dll" (
    echo VL.Video.VCamSource.dll not found next to this script.
    echo Run publish-vcamsource.cmd first or reinstall the package.
    pause
    exit /b 1
)

set TARGET=%ProgramData%\vvvv\VirtualCamera
if not exist "%TARGET%" mkdir "%TARGET%"

copy /y "%~dp0VL.Video.VCamSource.dll" "%TARGET%\" >nul
if errorlevel 1 (
    echo Failed to copy the DLL to "%TARGET%".
    pause
    exit /b 1
)

rem Everyone gets read and execute so the Frame Server services can load the DLL
icacls "%TARGET%" /grant *S-1-1-0:(OI)(CI)RX >nul

"%SystemRoot%\System32\regsvr32.exe" "%TARGET%\VL.Video.VCamSource.dll"
if errorlevel 1 (
    echo Registration failed.
    pause
    exit /b 1
)

echo The vvvv virtual camera media source is registered.

