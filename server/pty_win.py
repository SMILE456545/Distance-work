# -*- coding: utf-8 -*-
"""Real Windows console sessions (ConPTY) for the phone: a program such as Claude Code runs
exactly as in Windows Terminal — colors, logo, menus, questions — and the phone shows it with
a terminal emulator. Only ctypes, no extra packages (Windows 10 1809+).

The phone reads the output with long polling (GET /api/pty/read?after=N) and sends keys with
POST /api/pty/write; see server.py."""
import ctypes
import ctypes.wintypes as wt
import os
import secrets
import threading
import time

k32 = ctypes.WinDLL("kernel32", use_last_error=True)

HPCON = ctypes.c_void_p


class COORD(ctypes.Structure):
    _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("lpReserved", wt.LPWSTR), ("lpDesktop", wt.LPWSTR),
                ("lpTitle", wt.LPWSTR), ("dwX", wt.DWORD), ("dwY", wt.DWORD), ("dwXSize", wt.DWORD),
                ("dwYSize", wt.DWORD), ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD),
                ("dwFillAttribute", wt.DWORD), ("dwFlags", wt.DWORD), ("wShowWindow", wt.WORD),
                ("cbReserved2", wt.WORD), ("lpReserved2", ctypes.c_void_p), ("hStdInput", wt.HANDLE),
                ("hStdOutput", wt.HANDLE), ("hStdError", wt.HANDLE)]


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [("StartupInfo", STARTUPINFOW), ("lpAttributeList", ctypes.c_void_p)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wt.HANDLE), ("hThread", wt.HANDLE),
                ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]


k32.CreatePipe.argtypes = [ctypes.POINTER(wt.HANDLE), ctypes.POINTER(wt.HANDLE), ctypes.c_void_p, wt.DWORD]
k32.CreatePseudoConsole.argtypes = [COORD, wt.HANDLE, wt.HANDLE, wt.DWORD, ctypes.POINTER(HPCON)]
k32.CreatePseudoConsole.restype = ctypes.c_long
k32.ResizePseudoConsole.argtypes = [HPCON, COORD]
k32.ResizePseudoConsole.restype = ctypes.c_long
k32.ClosePseudoConsole.argtypes = [HPCON]
k32.InitializeProcThreadAttributeList.argtypes = [ctypes.c_void_p, wt.DWORD, wt.DWORD, ctypes.POINTER(ctypes.c_size_t)]
k32.UpdateProcThreadAttribute.argtypes = [ctypes.c_void_p, wt.DWORD, ctypes.c_size_t, ctypes.c_void_p,
                                          ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p]
k32.DeleteProcThreadAttributeList.argtypes = [ctypes.c_void_p]
k32.CreateProcessW.argtypes = [wt.LPCWSTR, wt.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wt.BOOL, wt.DWORD,
                               ctypes.c_void_p, wt.LPCWSTR, ctypes.c_void_p, ctypes.POINTER(PROCESS_INFORMATION)]
k32.ReadFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.WriteFile.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.CloseHandle.argtypes = [wt.HANDLE]
k32.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
k32.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]

PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
CREATE_UNICODE_ENVIRONMENT = 0x00000400
KEEP = 2 * 1024 * 1024  # characters of output kept for re-reading (phone reconnects)


def _env_block(extra):
    env = dict(os.environ)
    env.update(extra)
    # Windows wants the block sorted (case-insensitive), "K=V\0...\0\0"
    items = sorted(env.items(), key=lambda kv: kv[0].upper())
    return ctypes.create_unicode_buffer("".join(f"{k}={v}\0" for k, v in items) + "\0")


class Pty:
    """One program in its own pseudo console."""

    def __init__(self, cmdline, cwd, cols=80, rows=24, env=None):
        self.id = secrets.token_hex(8)
        self.title = ""
        self.cwd = cwd
        self.text = ""          # output kept for reading
        self.base = 0           # offset of text[0] in the whole output
        self.exited = False
        self.code = None
        self.last_read = time.time()
        self._cond = threading.Condition()
        self._closed = False

        in_r, in_w, out_r, out_w = wt.HANDLE(), wt.HANDLE(), wt.HANDLE(), wt.HANDLE()
        if not k32.CreatePipe(ctypes.byref(in_r), ctypes.byref(in_w), None, 0) or \
                not k32.CreatePipe(ctypes.byref(out_r), ctypes.byref(out_w), None, 0):
            raise OSError(ctypes.get_last_error(), "CreatePipe")
        self.hpc = HPCON()
        hr = k32.CreatePseudoConsole(COORD(cols, rows), in_r, out_w, 0, ctypes.byref(self.hpc))
        if hr != 0:
            raise OSError(hr, "CreatePseudoConsole (нужна Windows 10 1809 или новее)")

        size = ctypes.c_size_t()
        k32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        self._attrs = ctypes.create_string_buffer(size.value)
        if not k32.InitializeProcThreadAttributeList(self._attrs, 1, 0, ctypes.byref(size)):
            raise OSError(ctypes.get_last_error(), "InitializeProcThreadAttributeList")
        if not k32.UpdateProcThreadAttribute(self._attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                             self.hpc, ctypes.sizeof(HPCON), None, None):
            raise OSError(ctypes.get_last_error(), "UpdateProcThreadAttribute")
        si = STARTUPINFOEXW()
        si.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        # empty std handles: otherwise the child takes the server's own (redirected) ones
        # and writes past the pseudo console
        si.StartupInfo.dwFlags = 0x100  # STARTF_USESTDHANDLES
        si.lpAttributeList = ctypes.cast(self._attrs, ctypes.c_void_p)
        self.pi = PROCESS_INFORMATION()
        envb = _env_block(env or {})
        ok = k32.CreateProcessW(None, ctypes.create_unicode_buffer(cmdline), None, None, False,
                                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                                envb, cwd, ctypes.byref(si), ctypes.byref(self.pi))
        err = ctypes.get_last_error()
        # the console owns its ends of the pipes now
        k32.CloseHandle(in_r)
        k32.CloseHandle(out_w)
        if not ok:
            k32.ClosePseudoConsole(self.hpc)
            k32.CloseHandle(in_w)
            k32.CloseHandle(out_r)
            raise OSError(err, f"не запускается: {cmdline}")
        self._in, self._out = in_w, out_r
        threading.Thread(target=self._reader, daemon=True, name=f"pty-{self.id}").start()
        threading.Thread(target=self._waiter, daemon=True, name=f"pty-wait-{self.id}").start()

    # ---- output
    def _reader(self):
        import codecs
        dec = codecs.getincrementaldecoder("utf-8")("replace")
        buf = ctypes.create_string_buffer(65536)
        got = wt.DWORD()
        while True:
            if not k32.ReadFile(self._out, buf, 65536, ctypes.byref(got), None) or not got.value:
                break
            s = dec.decode(buf.raw[:got.value])
            if s:
                with self._cond:
                    self.text += s
                    if len(self.text) > KEEP:
                        cut = len(self.text) - KEEP
                        self.text = self.text[cut:]
                        self.base += cut
                    self._cond.notify_all()
        with self._cond:
            self.exited = True
            self._cond.notify_all()

    def _waiter(self):
        k32.WaitForSingleObject(self.pi.hProcess, 0xFFFFFFFF)
        code = wt.DWORD()
        ctypes.windll.kernel32.GetExitCodeProcess(self.pi.hProcess, ctypes.byref(code))
        self.code = code.value
        time.sleep(0.3)  # let the last output through
        # closing the console ends the reader (ReadFile returns 0)
        self._close_console()
        with self._cond:
            self.exited = True
            self._cond.notify_all()

    def read(self, after, wait=20.0):
        """Output after character `after` (waits up to `wait` s for something new).
        Returns (text, end, exited)."""
        self.last_read = time.time()
        end_by = time.time() + wait
        with self._cond:
            while self.base + len(self.text) <= after and not self.exited:
                left = end_by - time.time()
                if left <= 0:
                    break
                self._cond.wait(left)
            start = max(after, self.base) - self.base
            return self.text[start:], self.base + len(self.text), self.exited

    # ---- input
    def write(self, s):
        if self.exited:
            return
        data = s.encode("utf-8")
        n = wt.DWORD()
        k32.WriteFile(self._in, data, len(data), ctypes.byref(n), None)

    def resize(self, cols, rows):
        if not self._closed:
            k32.ResizePseudoConsole(self.hpc, COORD(max(10, cols), max(4, rows)))

    def _close_console(self):
        if self._closed:
            return
        self._closed = True
        k32.ClosePseudoConsole(self.hpc)
        k32.CloseHandle(self._in)

    def kill(self):
        if not self.exited:
            k32.TerminateProcess(self.pi.hProcess, 1)
        self._close_console()


class Sessions:
    MAX = 8
    IDLE = 3 * 3600  # nobody read it for 3 hours -> closed

    def __init__(self):
        self.all = {}
        self.lock = threading.Lock()

    def start(self, cmdline, cwd, cols, rows, title, env=None):
        with self.lock:
            self._sweep()
            if len(self.all) >= self.MAX:
                raise RuntimeError("Открыто слишком много сессий — закройте лишние вкладки")
            p = Pty(cmdline, cwd, cols, rows, env)
            p.title = title
            self.all[p.id] = p
            return p

    def get(self, sid):
        p = self.all.get(sid)
        if not p:
            raise KeyError("Сессия закрыта")
        return p

    def kill(self, sid):
        with self.lock:
            p = self.all.pop(sid, None)
        if p:
            p.kill()

    def _sweep(self):
        now = time.time()
        for sid, p in list(self.all.items()):
            if (p.exited and now - p.last_read > 60) or now - p.last_read > self.IDLE:
                p.kill()
                del self.all[sid]
