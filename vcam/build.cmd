@echo off
rem Rebuilds VL.Video.VCamSource.dll (the virtual camera media source) from source.
rem Needs git, .NET 8 SDK and VS 2022 Build Tools with the C++ workload + Windows 11 SDK:
rem   winget install Microsoft.DotNet.SDK.8 Microsoft.VisualStudio.2022.BuildTools
rem Pinned upstream commit, reviewed before use; bump deliberately.
setlocal
set COMMIT=256055b2d81a71ea2190dbd83fb79b82b133b3ce
set SRC=%TEMP%\vlvcam-src
if exist "%SRC%" rmdir /s /q "%SRC%"
git clone -q https://github.com/bj-rn/VL.Video.VirtualCamera "%SRC%" || exit /b 1
git -C "%SRC%" checkout -q %COMMIT% || exit /b 1
rem only nuget.org is needed for the media source; drop the vvvv feed
powershell -NoProfile -Command "(Get-Content '%SRC%\NuGet.config') -notmatch 'vvvv' | Set-Content '%SRC%\NuGet.config'"
call "%SRC%\publish-vcamsource.cmd" || exit /b 1
copy /y "%SRC%\virtualcam\VL.Video.VCamSource.dll" "%~dp0" >nul
echo Built %~dp0VL.Video.VCamSource.dll - now run register.cmd as administrator.
