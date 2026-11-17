# -*- coding: utf-8 -*-
"""RemoteDesk Unlock — types the Windows PIN / password on the lock screen.

The lock screen lives on a protected desktop ("Winlogon") that normal programs can neither
see nor type into, so this small helper runs as SYSTEM (a scheduled task started at boot).
Only the standard library is used: it is built into its own small RemoteDeskUnlock.exe and
installed into Program Files, where ordinary programs can't replace it.

  RemoteDeskUnlock.exe --install USER   (as admin) copy to Program Files, create the task, start it
  RemoteDeskUnlock.exe --uninstall      (as admin) stop and remove everything
  RemoteDeskUnlock.exe --agent          the SYSTEM process: waits for requests on 127.0.0.1
  RemoteDeskUnlock.exe --type           started by the agent on the lock screen; reads the
                                        PIN from its input and types it there

Protocol (one JSON line each way, 127.0.0.1 only, secret key from unlock.key):
  {"key": "...", "op": "ping"}               -> {"ok": true, "version": "..."}
  {"key": "...", "op": "unlock", "pin": "…"} -> {"ok": true} / {"ok": false, "error": "…"}

The PIN is never written anywhere. It is only typed when the lock screen really is the active
desktop: if Windows is already unlocked nothing is typed (so it can't land in an open window).
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time

VERSION = "1.0.0"
PORT = 47865
TASK = "RemoteDesk Unlock"
FROZEN = getattr(sys, "frozen", False)
PROGRAM_DATA = os.path.join(os.environ.get("ProgramData") or r"C:\ProgramData", "RemoteDesk")
KEY_FILE = os.path.join(PROGRAM_DATA, "unlock.key")
LOG_FILE = os.path.join(PROGRAM_DATA, "unlock.log")
INSTALL_DIR = os.path.join(os.environ.get("ProgramFiles") or r"C:\Program Files", "RemoteDesk Unlock")
NO_WINDOW = 0x08000000

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)


def log(text):
    try:
        os.makedirs(PROGRAM_DATA, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- desktops
user32.OpenInputDesktop.restype = wt.HANDLE
user32.OpenInputDesktop.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
user32.GetUserObjectInformationW.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD,
                                             ctypes.POINTER(wt.DWORD)]
user32.SetThreadDesktop.argtypes = [wt.HANDLE]
user32.CloseDesktop.argtypes = [wt.HANDLE]
DESKTOP_READOBJECTS = 0x0001
GENERIC_ALL = 0x10000000


def input_desktop_name(access=DESKTOP_READOBJECTS):
    """Name of the desktop that gets the keyboard now: "Default" = normal Windows,
    "Winlogon" = lock / sign-in screen. None = can't open it (normal programs can't
    open Winlogon, so for them None also means locked)."""
    h = user32.OpenInputDesktop(0, False, access)
    if not h:
        return None
    try:
        buf = ctypes.create_unicode_buffer(256)
        need = wt.DWORD()
        if not user32.GetUserObjectInformationW(h, 2, buf, ctypes.sizeof(buf), ctypes.byref(need)):
            return None
        return buf.value
    finally:
        user32.CloseDesktop(h)


def is_locked():
    name = input_desktop_name()
    return name is None or name.lower() != "default"


# ---------------------------------------------------------------- typing (used by --type)
ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class _U(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _U)]


KEYUP, UNICODE = 0x2, 0x4
VK_BACK, VK_RETURN, VK_CONTROL, VK_A = 0x08, 0x0D, 0x11, 0x41


def _send(*items):
    arr = (INPUT * len(items))(*items)
    return user32.SendInput(len(items), arr, ctypes.sizeof(INPUT))


def _key(vk=0, scan=0, flags=0):
    i = INPUT(type=1)
    i.u.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return i


def _tap(vk):
    return _send(_key(vk), _key(vk, 0, KEYUP))


def _wiggle():
    """A tiny mouse move: wakes the screen if it is off."""
    for dx in (1, -1):
        i = INPUT(type=0)
        i.u.mi = MOUSEINPUT(dx, 0, 0, 0x0001, 0, 0)  # MOUSEEVENTF_MOVE (relative)
        _send(i)
        time.sleep(0.05)


def _on_lock_screen():
    name = input_desktop_name(GENERIC_ALL)
    return bool(name) and name.lower() == "winlogon"


def type_pin(pin):
    """Runs on the Winlogon desktop as SYSTEM. Exit codes: 0 typed, 3 not locked, 4 can't attach."""
    h = user32.OpenInputDesktop(0, False, GENERIC_ALL)
    if not h or not user32.SetThreadDesktop(h):
        log(f"type: can't attach to the input desktop (error {ctypes.get_last_error()})")
        return 4
    if not _on_lock_screen():
        log("type: Windows is not locked - nothing typed")
        return 3
    _wiggle()
    time.sleep(0.4)
    _tap(VK_CONTROL)  # lifts the lock-screen picture and shows the sign-in field
    time.sleep(1.3)
    if not _on_lock_screen():
        return 3
    # clear whatever is in the field
    _send(_key(VK_CONTROL), _key(VK_A), _key(VK_A, 0, KEYUP), _key(VK_CONTROL, 0, KEYUP))
    time.sleep(0.05)
    _tap(VK_BACK)
    time.sleep(0.1)
    for ch in pin:
        # Unicode input does not depend on the keyboard layout of the lock screen (EN/RU)
        code = ord(ch)
        _send(_key(0, code, UNICODE), _key(0, code, UNICODE | KEYUP))
        time.sleep(0.03)
    time.sleep(0.6)
    # a Windows Hello PIN signs in by itself; Enter only if we are still on the lock screen
    # (otherwise it would go into the window that is open on the desktop)
    if _on_lock_screen():
        _tap(VK_RETURN)
    log("type: done")
    return 0


# ---------------------------------------------------------------- starting --type on the lock screen
class STARTUPINFO(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("lpReserved", wt.LPWSTR), ("lpDesktop", wt.LPWSTR),
                ("lpTitle", wt.LPWSTR), ("dwX", wt.DWORD), ("dwY", wt.DWORD), ("dwXSize", wt.DWORD),
                ("dwYSize", wt.DWORD), ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD),
                ("dwFillAttribute", wt.DWORD), ("dwFlags", wt.DWORD), ("wShowWindow", wt.WORD),
                ("cbReserved2", wt.WORD), ("lpReserved2", ctypes.c_void_p), ("hStdInput", wt.HANDLE),
                ("hStdOutput", wt.HANDLE), ("hStdError", wt.HANDLE)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wt.HANDLE), ("hThread", wt.HANDLE),
                ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wt.DWORD), ("lpSecurityDescriptor", ctypes.c_void_p),
                ("bInheritHandle", wt.BOOL)]


kernel32.GetCurrentProcess.restype = wt.HANDLE
kernel32.WTSGetActiveConsoleSessionId.restype = wt.DWORD
kernel32.CreatePipe.argtypes = [ctypes.POINTER(wt.HANDLE), ctypes.POINTER(wt.HANDLE),
                                ctypes.POINTER(SECURITY_ATTRIBUTES), wt.DWORD]
kernel32.SetHandleInformation.argtypes = [wt.HANDLE, wt.DWORD, wt.DWORD]
kernel32.WriteFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
kernel32.CloseHandle.argtypes = [wt.HANDLE]
kernel32.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
kernel32.GetExitCodeProcess.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]
kernel32.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]
advapi32.OpenProcessToken.argtypes = [wt.HANDLE, wt.DWORD, ctypes.POINTER(wt.HANDLE)]
advapi32.DuplicateTokenEx.argtypes = [wt.HANDLE, wt.DWORD, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                      ctypes.POINTER(wt.HANDLE)]
advapi32.SetTokenInformation.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
advapi32.CreateProcessAsUserW.argtypes = [wt.HANDLE, wt.LPCWSTR, wt.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                                          wt.BOOL, wt.DWORD, ctypes.c_void_p, wt.LPCWSTR,
                                          ctypes.POINTER(STARTUPINFO), ctypes.POINTER(PROCESS_INFORMATION)]


def self_command(arg):
    if FROZEN:
        return sys.executable, f'"{sys.executable}" {arg}'
    script = os.path.abspath(__file__)
    return sys.executable, f'"{sys.executable}" "{script}" {arg}'


def run_on_lock_screen(pin, timeout=25):
    """Starts `--type` in the console session on the Winlogon desktop with our SYSTEM rights
    and hands it the PIN through a pipe. Returns the helper's exit code."""
    session = kernel32.WTSGetActiveConsoleSessionId()
    if session == 0xFFFFFFFF:
        return 5
    tok, dup = wt.HANDLE(), wt.HANDLE()
    if not advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), 0xF01FF, ctypes.byref(tok)):
        raise OSError(ctypes.get_last_error(), "OpenProcessToken")
    try:
        if not advapi32.DuplicateTokenEx(tok, 0x02000000, None, 2, 1, ctypes.byref(dup)):
            raise OSError(ctypes.get_last_error(), "DuplicateTokenEx")
    finally:
        kernel32.CloseHandle(tok)
    sid = wt.DWORD(session)
    if not advapi32.SetTokenInformation(dup, 12, ctypes.byref(sid), 4):  # TokenSessionId
        kernel32.CloseHandle(dup)
        raise OSError(ctypes.get_last_error(), "SetTokenInformation (нужны права SYSTEM)")

    sa = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), None, True)
    rd, wr = wt.HANDLE(), wt.HANDLE()
    kernel32.CreatePipe(ctypes.byref(rd), ctypes.byref(wr), ctypes.byref(sa), 0)
    kernel32.SetHandleInformation(wr, 1, 0)  # our end is not inherited

    si = STARTUPINFO()
    si.cb = ctypes.sizeof(si)
    si.lpDesktop = "winsta0\\winlogon"
    si.dwFlags = 0x100  # STARTF_USESTDHANDLES
    si.hStdInput = rd
    pi = PROCESS_INFORMATION()
    app, cmd = self_command("--type")
    ok = advapi32.CreateProcessAsUserW(dup, app, ctypes.create_unicode_buffer(cmd), None, None, True,
                                       NO_WINDOW, None, None, ctypes.byref(si), ctypes.byref(pi))
    err = ctypes.get_last_error()
    kernel32.CloseHandle(rd)
    kernel32.CloseHandle(dup)
    if not ok:
        kernel32.CloseHandle(wr)
        raise OSError(err, "CreateProcessAsUser")
    data = (json.dumps({"pin": pin}) + "\n").encode("utf-8")
    written = wt.DWORD()
    kernel32.WriteFile(wr, data, len(data), ctypes.byref(written), None)
    kernel32.CloseHandle(wr)
    try:
        if kernel32.WaitForSingleObject(pi.hProcess, timeout * 1000) != 0:
            kernel32.TerminateProcess(pi.hProcess, 9)
            return 9
        code = wt.DWORD()
        kernel32.GetExitCodeProcess(pi.hProcess, ctypes.byref(code))
        return code.value
    finally:
        kernel32.CloseHandle(pi.hProcess)
        kernel32.CloseHandle(pi.hThread)


# ---------------------------------------------------------------- agent (SYSTEM)
ERRORS = {
    3: "Компьютер уже разблокирован",
    4: "Не удалось открыть экран блокировки",
    5: "Никто не вошёл в Windows на этом компьютере",
    9: "Экран блокировки не ответил",
}


def handle(conn, key, lock):
    conn.settimeout(10)
    raw = b""
    while not raw.endswith(b"\n") and len(raw) < 8192:
        part = conn.recv(4096)
        if not part:
            break
        raw += part
    try:
        req = json.loads(raw.decode("utf-8"))
    except ValueError:
        return {"ok": False, "error": "bad request"}
    if not secrets.compare_digest(str(req.get("key", "")).encode(), key.encode()):
        log("agent: wrong key")
        time.sleep(1)
        return {"ok": False, "error": "wrong key"}
    op = req.get("op")
    if op == "ping":
        return {"ok": True, "version": VERSION}
    if op == "unlock":
        pin = str(req.get("pin", ""))
        if not pin or len(pin) > 256 or any(ord(c) < 32 for c in pin):
            return {"ok": False, "error": "Пустой или неверный PIN"}
        with lock:  # one at a time
            try:
                code = run_on_lock_screen(pin)
            except OSError as e:
                log(f"agent: {e}")
                return {"ok": False, "error": f"Ошибка запуска: {e}"}
        log(f"agent: unlock -> code {code}")
        return {"ok": code == 0, "code": code, **({} if code == 0 else {"error": ERRORS.get(code, f"код {code}")})}
    return {"ok": False, "error": "unknown op"}


def agent():
    with open(KEY_FILE, encoding="utf-8") as f:
        key = f.read().strip()
    lock = threading.Lock()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(4)
    log(f"agent {VERSION} started, port {PORT}")

    def serve(conn):
        with conn:
            try:
                reply = handle(conn, key, lock)
                conn.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode("utf-8"))
            except Exception as e:
                log(f"agent: {e!r}")

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


# ---------------------------------------------------------------- install / uninstall (admin)
TASK_XML = """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>RemoteDesk: разблокировка экрана с телефона</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>{cmd}</Command><Arguments>{args}</Arguments></Exec></Actions>
</Task>
"""


def _xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _run(args):
    return subprocess.run(args, capture_output=True, creationflags=NO_WINDOW).returncode


def _stop_task():
    _run(["schtasks", "/end", "/tn", TASK])
    _run(["schtasks", "/delete", "/tn", TASK, "/f"])
    time.sleep(0.5)


def install(user):
    """Copies the helper to Program Files (only admins can change it there), makes the secret
    key readable by SYSTEM, admins and `user`, registers the SYSTEM task and starts it."""
    _stop_task()
    if FROZEN:
        src = os.path.dirname(sys.executable)
        if os.path.normcase(src) != os.path.normcase(INSTALL_DIR):
            shutil.rmtree(INSTALL_DIR, ignore_errors=True)
            shutil.copytree(src, INSTALL_DIR)
        cmd, args = os.path.join(INSTALL_DIR, os.path.basename(sys.executable)), "--agent"
    else:  # from source (developer): the script is copied, Python itself stays where it is
        os.makedirs(INSTALL_DIR, exist_ok=True)
        shutil.copy2(os.path.abspath(__file__), os.path.join(INSTALL_DIR, "unlock_agent.py"))
        exe = sys.executable.replace("python.exe", "pythonw.exe")
        cmd, args = exe, f'"{os.path.join(INSTALL_DIR, "unlock_agent.py")}" --agent'

    os.makedirs(PROGRAM_DATA, exist_ok=True)
    # the folder: full rights for SYSTEM and admins, the person may only read
    dir_grants = ["/grant:r", "*S-1-5-18:(OI)(CI)F", "/grant:r", "*S-1-5-32-544:(OI)(CI)F"]
    if user:
        dir_grants += ["/grant:r", f"{user}:(OI)(CI)RX"]
    _run(["icacls", PROGRAM_DATA, "/inheritance:r", *dir_grants])
    _run(["icacls", PROGRAM_DATA, "/setowner", "*S-1-5-32-544", "/T"])
    if not os.path.exists(KEY_FILE):
        with open(KEY_FILE, "w", encoding="utf-8") as f:
            f.write(secrets.token_urlsafe(32))
    grants = ["/grant:r", "*S-1-5-18:F", "/grant:r", "*S-1-5-32-544:F"]
    if user:
        grants += ["/grant:r", f"{user}:R"]
    _run(["icacls", KEY_FILE, "/inheritance:r", *grants])
    with open(os.path.join(INSTALL_DIR, "version.txt"), "w", encoding="utf-8") as f:
        f.write(VERSION)

    xml_path = os.path.join(PROGRAM_DATA, "unlock-task.xml")
    with open(xml_path, "w", encoding="utf-16") as f:
        f.write(TASK_XML.format(cmd=_xml(cmd), args=_xml(args)))
    code = _run(["schtasks", "/create", "/tn", TASK, "/xml", xml_path, "/f"])
    os.remove(xml_path)
    if code != 0:
        log(f"install: schtasks /create failed ({code})")
        return 2
    _run(["schtasks", "/run", "/tn", TASK])
    log(f"installed {VERSION} for {user}")
    return 0


def uninstall():
    _stop_task()
    shutil.rmtree(INSTALL_DIR, ignore_errors=True)
    try:
        os.remove(KEY_FILE)
    except OSError:
        pass
    log("uninstalled")
    return 0


def read_stdin(limit=8192):
    """Reads the pipe the agent gave us. The windowed exe has no sys.stdin, so the Windows
    handle is read directly."""
    kernel32.GetStdHandle.restype = wt.HANDLE
    h = kernel32.GetStdHandle(wt.DWORD(-10 & 0xFFFFFFFF))  # STD_INPUT_HANDLE
    kernel32.ReadFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
    out = b""
    buf = ctypes.create_string_buffer(4096)
    got = wt.DWORD()
    while len(out) < limit and not out.endswith(b"\n"):
        if not kernel32.ReadFile(h, buf, 4096, ctypes.byref(got), None) or not got.value:
            break
        out += buf.raw[:got.value]
    return out


def main(argv):
    if "--type" in argv:
        try:
            pin = json.loads(read_stdin().decode("utf-8")).get("pin", "")
        except Exception as e:
            log(f"type: no PIN ({e!r})")
            return 6
        return type_pin(pin)
    if "--agent" in argv:
        agent()
        return 0
    if "--install" in argv:
        i = argv.index("--install")
        user = argv[i + 1] if len(argv) > i + 1 else ""
        return install(user)
    if "--uninstall" in argv:
        return uninstall()
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
