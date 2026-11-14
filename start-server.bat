@echo off
chcp 65001 >nul
title RemoteDesk - server
cd /d "%~dp0"
python -c "import mss, PIL, aiortc, dxcam" 2>nul || python -m pip install -r server\requirements.txt
python server\server.py
pause
