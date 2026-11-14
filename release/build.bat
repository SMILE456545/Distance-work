@echo off
rem Builds release\RemoteDesk.exe (one file: server + phone web app inside).
rem Before: build the web app (app\  ->  flutter build web --no-web-resources-cdn, copy app\build\web to web\).
cd /d "%~dp0build"
python -m PyInstaller --noconfirm RemoteDesk.spec --distpath .. --workpath work
