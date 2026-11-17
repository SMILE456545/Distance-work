# -*- coding: utf-8 -*-
"""Server side of «разблокировка экрана»: is Windows locked, is the SYSTEM helper
(unlock_agent.py / RemoteDeskUnlock.exe) installed, and asking it to type the PIN."""
import json
import os
import socket
import sys
import threading
import time

import unlock_agent as ua

_attempts = []
_lock = threading.Lock()
MAX_TRIES, WINDOW = 5, 300  # 5 tries per 5 minutes


def locked():
    return ua.is_locked()


def _key():
    try:
        with open(ua.KEY_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _ask(req, timeout=40):
    key = _key()
    if not key:
        raise ConnectionError("not installed")
    with socket.create_connection(("127.0.0.1", ua.PORT), timeout=timeout) as s:
        s.sendall((json.dumps({"key": key, **req}) + "\n").encode("utf-8"))
        raw = b""
        while not raw.endswith(b"\n"):
            part = s.recv(4096)
            if not part:
                break
            raw += part
    return json.loads(raw.decode("utf-8"))


def agent_version():
    """Version of the running helper, or None when it is not installed / not running."""
    try:
        r = _ask({"op": "ping"}, timeout=2)
        return r.get("version") if r.get("ok") else None
    except (OSError, ValueError):
        return None


def installed_version():
    try:
        with open(os.path.join(ua.INSTALL_DIR, "version.txt"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def state():
    return {"locked": locked(), "agent": agent_version() is not None}


def unlock(pin):
    """Types the PIN on the lock screen and waits until Windows opens."""
    now = time.time()
    with _lock:
        _attempts[:] = [t for t in _attempts if now - t < WINDOW]
        if len(_attempts) >= MAX_TRIES:
            wait = int(WINDOW - (now - _attempts[0])) // 60 + 1
            return {"ok": False, "error": f"Слишком много попыток. Подождите {wait} мин."}
        _attempts.append(now)
    if not locked():
        return {"ok": True, "already": True}
    try:
        r = _ask({"op": "unlock", "pin": pin})
    except (OSError, ValueError):
        return {"ok": False, "agent": False,
                "error": "Разблокировка не настроена на компьютере"}
    if not r.get("ok"):
        if r.get("code") == 3:
            return {"ok": True, "already": True}
        return {"ok": False, "error": r.get("error") or "Не получилось"}
    for _ in range(40):  # Windows needs a moment to open the desktop
        time.sleep(0.25)
        if not locked():
            with _lock:
                _attempts.clear()
            return {"ok": True}
    return {"ok": False, "error": "Компьютер всё ещё заблокирован — проверьте PIN или пароль"}


def agent_exe():
    """Where the helper ships: next to RemoteDesk.exe (release) or this folder (source)."""
    if getattr(sys, "frozen", False):
        exe = os.path.join(os.path.dirname(sys.executable), "RemoteDeskUnlock", "RemoteDeskUnlock.exe")
        return (exe, "") if os.path.exists(exe) else (None, None)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "unlock_agent.py")
    return sys.executable.replace("pythonw.exe", "python.exe"), f'"{script}"'
