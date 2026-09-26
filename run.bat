@echo off
rem Start solocam. ffmpeg: SOLOCAM_FFMPEG env, else PATH, else the winget Gyan build.
cd /d %~dp0
if not defined SOLOCAM_FFMPEG (
  where ffmpeg >nul 2>nul && set SOLOCAM_FFMPEG=ffmpeg
)
if not defined SOLOCAM_FFMPEG (
  for /d %%d in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*") do set SOLOCAM_FFMPEG=%%d\bin\ffmpeg.exe
)
.venv\Scripts\python.exe solocam.py %*
