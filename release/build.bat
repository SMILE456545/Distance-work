@echo off
chcp 65001 >nul
rem Builds release\RemoteDesk\ (RemoteDesk.exe + _internal: server + phone web app inside)
rem and packs it with "Как пользоваться.txt" into release\RemoteDesk.zip.
rem Before: build the web app (app\  ->  flutter build web --no-web-resources-cdn, copy app\build\web to web\).
cd /d "%~dp0build"
python -m PyInstaller --noconfirm RemoteDesk.spec --distpath .. --workpath work || exit /b 1
rem the lock-screen helper goes inside the RemoteDesk folder
python -m PyInstaller --noconfirm RemoteDeskUnlock.spec --distpath ..\RemoteDesk --workpath work-unlock || exit /b 1
cd /d "%~dp0"
copy /y "Как пользоваться.txt" RemoteDesk\ >nul
rem zipped by Python: file names inside are UTF-8, the updater in the program unpacks them right
python -c "import shutil; shutil.make_archive('RemoteDesk', 'zip', '.', 'RemoteDesk')" || exit /b 1
del "RemoteDesk\Как пользоваться.txt"
rem the one file people download and click (and the update package): starter + the zip
python build\make_setup.py || exit /b 1
echo Done: release\RemoteDeskSetup.exe
