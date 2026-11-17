# -*- mode: python ; coding: utf-8 -*-
# Small helper for unlocking the Windows lock screen from the phone (standard library only).
# Built into release\RemoteDesk\RemoteDeskUnlock\ ; RemoteDesk.exe copies it to Program Files.

a = Analysis(
    ['../../server/unlock_agent.py'],
    pathex=['../../server'],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'unittest', 'pydoc', 'email', 'http', 'xml', 'sqlite3'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='RemoteDeskUnlock',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['remotedesk.ico'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='RemoteDeskUnlock',
)
