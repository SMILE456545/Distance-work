@echo off
if not "%~1"=="run" (start "" conhost.exe cmd /c ""%~f0" run" & exit /b)
chcp 65001 >nul
title RemoteDesk - server
cd /d "%~dp0"
python -c "import mss, PIL" 2>nul || python -m pip install -r server\requirements.txt
python server\server.py
pause
