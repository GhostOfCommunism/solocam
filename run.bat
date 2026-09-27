@echo off
rem Start solocam in a console. ffmpeg: SOLOCAM_FFMPEG env, PATH, or the winget Gyan build (found by solocam.py).
cd /d %~dp0
.venv\Scripts\python.exe solocam.py %*
