@echo off
rem One-time setup: venv + PyTorch (CUDA 12.6) + deps. Needs Python 3.12 and an NVIDIA GPU.
cd /d %~dp0
py -3.12 -m venv .venv 2>nul || python -m venv .venv || exit /b 1
.venv\Scripts\python.exe -m pip install -q -U pip
.venv\Scripts\python.exe -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu126 || exit /b 1
.venv\Scripts\python.exe -m pip install -r requirements.txt || exit /b 1
where ffmpeg >nul 2>nul || winget install -e --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
.venv\Scripts\python.exe -c "import torch; print('CUDA:', torch.cuda.is_available())"
