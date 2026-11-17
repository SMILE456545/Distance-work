# -*- coding: utf-8 -*-
"""RemoteDesk.exe entry point: a window that shows what is happening while the server
starts (files, settings, video, Tailscale) and then the key and the addresses for the phone.

Also works from source:  python server\\launcher.py
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import webbrowser
import tkinter as tk
from tkinter import ttk

import art

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass
try:  # own taskbar button with our icon instead of the Python one
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("KrakenDigital.RemoteDesk")
except Exception:
    pass

FROZEN = getattr(sys, "frozen", False)
SRC = os.path.dirname(os.path.abspath(__file__))
BUNDLE = sys._MEIPASS if FROZEN else os.path.dirname(SRC)
DATA = (os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "RemoteDesk")
        if FROZEN else SRC)
os.makedirs(DATA, exist_ok=True)
ICON = (os.path.join(BUNDLE, "remotedesk.ico") if FROZEN
        else os.path.join(BUNDLE, "release", "build", "remotedesk.ico"))
NO_WINDOW = subprocess.CREATE_NO_WINDOW
VERSION = "1.3.0"
# Updates = published releases of the repo: a release with a higher tag (v1.4.0) and
# RemoteDeskSetup.exe (or a .zip of the program) lights the bell in every running RemoteDesk; its description is shown there.
FEED = (os.environ.get("REMOTEDESK_FEED")
        or "https://api.github.com/repos/SMILE456545/RemoteDesk/releases?per_page=10")
PAGE = "https://github.com/SMILE456545/RemoteDesk/releases/latest"

FONT = "Segoe UI"
MONO = "Cascadia Mono" if os.path.exists(r"C:\Windows\Fonts\CascadiaMono.ttf") else "Consolas"


# ---------------------------------------------------------------- log (the exe has no console)
class Log:
    """Replaces stdout/stderr: keeps the lines for the window and writes remotedesk.log."""

    def __init__(self, echo=None):
        self.lock = threading.Lock()
        self.lines, self.buf, self.echo = [], "", echo
        self.path = os.path.join(DATA, "remotedesk.log")
        try:
            with open(self.path, "w", encoding="utf-8") as f:
                f.write(f"RemoteDesk {VERSION} — {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        except Exception:
            pass

    def write(self, s):
        if not s:
            return 0
        if self.echo:
            try:
                self.echo.write(s)
            except Exception:
                pass
        with self.lock:
            self.buf += s
            *done, self.buf = self.buf.split("\n")
            for line in done:
                if line.strip():
                    self.lines.append(line.rstrip())
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(s)
            except Exception:
                pass
        return len(s)

    def flush(self):
        pass

    def reconfigure(self, **kw):  # server.main() calls this; harmless here
        pass


LOG = Log(echo=None if FROZEN else sys.__stdout__)
sys.stdout = sys.stderr = LOG


# ---------------------------------------------------------------- helpers
def run(args, timeout=20):
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout, creationflags=NO_WINDOW,
                           stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)


def home_ip():
    """The address of this PC in the home network (the one the default route goes through)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if not ip.startswith(("127.", "100.")):
            return ip
    except Exception:
        pass
    return None


class SHELLEXECUTEINFO(ctypes.Structure):
    _fields_ = [("cbSize", wt.DWORD), ("fMask", ctypes.c_ulong), ("hwnd", wt.HWND),
                ("lpVerb", wt.LPCWSTR), ("lpFile", wt.LPCWSTR), ("lpParameters", wt.LPCWSTR),
                ("lpDirectory", wt.LPCWSTR), ("nShow", ctypes.c_int), ("hInstApp", wt.HINSTANCE),
                ("lpIDList", ctypes.c_void_p), ("lpClass", wt.LPCWSTR), ("hkeyClass", wt.HKEY),
                ("dwHotKey", wt.DWORD), ("hIcon", wt.HANDLE), ("hProcess", wt.HANDLE)]


def run_as_admin(file, params):
    """Runs a program with the Windows admin prompt and waits. Returns its exit code,
    or None when the person pressed «Нет»."""
    info = SHELLEXECUTEINFO()
    info.cbSize = ctypes.sizeof(info)
    info.fMask = 0x40  # SEE_MASK_NOCLOSEPROCESS
    info.lpVerb, info.lpFile, info.lpParameters, info.nShow = "runas", file, params, 0
    if not ctypes.windll.shell32.ShellExecuteExW(ctypes.byref(info)):
        return None
    ctypes.windll.kernel32.WaitForSingleObject(info.hProcess, 0xFFFFFFFF)
    code = wt.DWORD()
    ctypes.windll.kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
    ctypes.windll.kernel32.CloseHandle(info.hProcess)
    return code.value


# ---------------------------------------------------------------- Tailscale
TS_MSI = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-{}.msi"


def ts_exe(name="tailscale.exe"):
    for base in (os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("ProgramFiles(x86)", "")):
        p = os.path.join(base, "Tailscale", name)
        if base and os.path.exists(p):
            return p
    return None


def ts_status():
    """('Running' | 'NeedsLogin' | 'Stopped' | '' , ipv4 or None)"""
    exe = ts_exe()
    if not exe:
        return "", None
    _, out = run([exe, "status", "--json"], timeout=10)
    try:
        j = json.loads(out[out.index("{"):])
    except Exception:
        return "", None
    ips = [ip for ip in ((j.get("Self") or {}).get("TailscaleIPs") or []) if "." in ip]
    return j.get("BackendState", ""), (ips[0] if ips else None)


def firewall_ok():
    if not FROZEN:
        return True  # from source python.exe already has its own rule
    code, _ = run(["netsh", "advfirewall", "firewall", "show", "rule", "name=RemoteDesk"])
    return code == 0


# ---------------------------------------------------------------- updates
def ver_tuple(s):
    v = [int(x) for x in re.findall(r"\d+", s or "")[:3]]
    return tuple(v + [0] * (3 - len(v)))


def http_get(url, timeout=20):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "RemoteDesk"}),
                                  timeout=timeout)


def clean_notes(s):
    """Release description as plain text (the window has no markdown)."""
    out = []
    for line in (s or "").replace("\r", "").split("\n"):
        line = re.sub(r"^\s*#+\s*", "", line)
        line = re.sub(r"^\s*[-*]\s+", "• ", line)
        out.append(re.sub(r"[*`]", "", line).rstrip())
    lines = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip().split("\n")
    if len(lines) > 14:
        lines = lines[:14] + ["…"]
    return "\n".join(lines)[:900]


def find_update():
    """The newest published release with a .zip that is newer than this program, or None."""
    with http_get(FEED) as r:
        rels = json.loads(r.read().decode("utf-8-sig"))
    best = None
    for rel in rels if isinstance(rels, list) else [rels]:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        v = ver_tuple(rel.get("tag_name"))
        # RemoteDeskSetup.exe (a starter with the zip glued to it) or a plain .zip — both unpack the same
        zips = sorted((a for a in rel.get("assets") or []
                       if (a.get("name") or "").lower().endswith((".exe", ".zip"))),
                      key=lambda a: a["name"].lower().endswith(".zip"))
        if not zips or v <= ver_tuple(VERSION) or (best and v <= best["v"]):
            continue
        day = (rel.get("published_at") or "")[:10].split("-")
        best = {"v": v, "ver": ".".join(map(str, v)), "title": (rel.get("name") or "").strip(),
                "notes": clean_notes(rel.get("body")), "date": ".".join(reversed(day)),
                "url": zips[0]["browser_download_url"], "size": int(zips[0].get("size") or 0)}
    return best


def download_update(upd, progress):
    """Downloads and unpacks the release; returns the folder with the new RemoteDesk.exe."""
    import zipfile
    base = os.path.join(DATA, "update")
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base, exist_ok=True)
    zpath = os.path.join(base, "package.bin")
    with http_get(upd["url"], timeout=30) as r, open(zpath, "wb") as f:
        total, done = int(r.headers.get("Content-Length") or upd["size"] or 0), 0
        while True:
            chunk = r.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            progress(done, total)
    if total and done != total:
        raise RuntimeError("файл скачался не полностью")
    new = os.path.join(base, "new")
    root = os.path.realpath(new)
    with zipfile.ZipFile(zpath) as z:
        for n in z.namelist():
            if not os.path.realpath(os.path.join(new, n)).startswith(root + os.sep):
                raise RuntimeError("неправильный архив")
        z.extractall(new)
    os.remove(zpath)
    for d, _, names in os.walk(new):
        if "RemoteDesk.exe" in names and os.path.isdir(os.path.join(d, "_internal")):
            return d
    raise RuntimeError("в архиве нет RemoteDesk.exe")


def swap_files(src, target):
    """Puts everything from src over target — all or nothing. Returns the error text or None."""
    def drop(p):
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass

    names, moved = [], []
    try:
        names = os.listdir(src)
        # old files aside first: this fails right here, with nothing changed, while one is in use
        for n in names:
            d = os.path.join(target, n)
            if os.path.exists(d):
                drop(d + ".old")
                os.replace(d, d + ".old")
                moved.append(d)
        for n in names:
            s, d = os.path.join(src, n), os.path.join(target, n)
            if os.path.isdir(s):
                shutil.copytree(s, d)
            else:
                shutil.copy2(s, d)
    except OSError as e:
        for n in names:
            d = os.path.join(target, n)
            if d in moved:
                drop(d)
                try:
                    os.replace(d + ".old", d)
                except OSError:
                    pass
            else:
                drop(d)
        return str(e)
    for d in moved:
        drop(d + ".old")
    return None


def spawn(exe, *args):
    """Starts another copy of the program as an independent one (not a child of this bundle)."""
    env = dict(os.environ, PYINSTALLER_RESET_ENVIRONMENT="1")
    return subprocess.Popen([exe, *args], cwd=os.path.dirname(exe), env=env)


def apply_update(target, pid, src=None, start=True):
    """`RemoteDesk.exe --apply-update <folder> <pid>` — runs from the freshly downloaded copy:
    waits until the old program closes, copies itself over it and starts it again."""
    src = src or os.path.dirname(sys.executable)
    print(f"  Обновление: {src} -> {target}")
    k = ctypes.windll.kernel32
    k.OpenProcess.restype = ctypes.c_void_p
    h = k.OpenProcess(0x100000, False, int(pid))  # SYNCHRONIZE
    if h:
        k.WaitForSingleObject(ctypes.c_void_p(h), 30000)
        k.CloseHandle(ctypes.c_void_p(h))
    err = None
    for _ in range(30):  # the files stay locked for a moment after the program closes
        err = swap_files(src, target)
        if not err:
            break
        time.sleep(0.5)
    print("  Обновление: " + (f"не удалось — {err}" if err else "готово"))
    if err:
        ctypes.windll.user32.MessageBoxW(
            None, f"Не удалось обновить RemoteDesk:\n{err}\n\nОстаётся прежняя версия.", "RemoteDesk", 0x30)
    if start:
        spawn(os.path.join(target, "RemoteDesk.exe"))
    return not err


# ---------------------------------------------------------------- small helpers for the window
def pc_model():
    """«ASUS TUF Gaming F15» from the BIOS info, or the computer name."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS") as k:
            maker = winreg.QueryValueEx(k, "SystemManufacturer")[0].strip()
            model = winreg.QueryValueEx(k, "SystemProductName")[0].strip()
        bad = ("to be filled", "system product", "default string", "o.e.m", "")
        if model.lower() not in bad:
            maker = maker.split()[0] if maker and maker.lower() not in bad else ""
            if maker.lower().startswith("asustek"):
                maker = "ASUS"
            return (maker + " " + model).strip() if maker.lower() not in model.lower() else model
    except Exception:
        pass
    return socket.gethostname()


def size_text(n):
    for unit, k in (("ГБ", 1 << 30), ("МБ", 1 << 20), ("КБ", 1 << 10)):
        if n >= k:
            return f"{n / k:.1f} {unit}".replace(".", ",")
    return f"{int(n)} Б"


def rate_text(n):
    return size_text(n) + "/с"


def time_text(sec):
    sec = int(sec)
    h, m, s = sec // 3600, sec // 60 % 60, sec % 60
    if h:
        return f"{h} ч {m:02d} мин"
    if m:
        return f"{m} мин {s:02d} с"
    return f"{s} с"


def bind_tree(widget, event, fn):
    widget.bind(event, fn)
    for c in widget.winfo_children():
        bind_tree(c, event, fn)


def set_cursor(widget, cursor):
    try:
        widget.configure(cursor=cursor)
    except tk.TclError:
        pass
    for c in widget.winfo_children():
        set_cursor(c, cursor)


class Round(tk.Canvas):
    """A block with smooth rounded corners; put widgets into `.inner`."""

    def __init__(self, parent, app, fill, outer, r=16, pad=14):
        super().__init__(parent, bg=outer, highlightthickness=0, bd=0, height=1)
        self.app, self.fill, self.outer, self.r, self.p = app, fill, outer, app.px(r), app.px(pad)
        self.inner = tk.Frame(self, bg=fill)
        self.win = self.create_window(self.p, self.p, window=self.inner, anchor="nw")
        self.bind("<Configure>", self._draw)
        self._size = None
        app.rounds.append(self)
        app.reflow()

    def fit(self):
        """Height = content height (the content sits in a canvas, so Tk can't do it itself)."""
        h = self.inner.winfo_reqheight() + 2 * self.p
        if int(float(self.cget("height"))) != h:
            self.configure(height=h)
            return True
        return False

    def _draw(self, _=None):
        w, h = self.winfo_width(), self.winfo_height()
        if w < 4 or h < 4:
            return
        self.itemconfigure(self.win, width=w - 2 * self.p)
        if self._size == (w, h):
            return
        self._size = (w, h)
        from PIL import ImageTk
        self._img = ImageTk.PhotoImage(art.rounded(w, h, self.r, self.fill, self.outer))
        self.delete("bg")
        self.create_image(0, 0, image=self._img, anchor="nw", tags="bg")
        self.tag_lower("bg")


# ---------------------------------------------------------------- window
KEY = "#010102"                      # transparent color of the rounded corners (near the black window, so no light edge)
HEAD, BODY, WHITE = "#000000", "#000000", "#FFFFFF"   # the whole window is black
SOFT, CARD2, LINE = "#161618", "#232327", "#2E2E33"       # blocks, cards inside blocks, lines
INK, MUTED, HMUTED = "#F4F4F5", "#8E8E93", "#6B6B73"      # text, quiet text, quieter text
GREEN, WARN, BAD = "#22C55E", "#FBBF24", "#F87171"
W_LOGICAL, RADIUS = 480, 22


class App:
    def __init__(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.root.title("RemoteDesk")
        try:
            self.root.iconbitmap(default=ICON)
        except Exception:
            pass
        self.k = self.root.winfo_fpixels("1i") / 96  # screen scale (125%, 150%…)
        self.root.overrideredirect(True)
        self.root.configure(bg=KEY)
        self.root.attributes("-transparentcolor", KEY)
        self.ui, self.ui_lock = [], threading.Lock()
        self.server = self.httpd = self.caddy = None
        self.ts_ip, self.ts_url, self.ts_skip = None, None, threading.Event()
        self.problem, self.can_retry, self.ready = None, False, False
        self.devs, self.dev_sig, self.overlay = [], None, None
        self.pc = pc_model()
        self._reflow_pending, self._bg_size, self._shown = False, None, False
        self.rounds = []
        self.qr_px = self.px(120)
        self.upd, self.upd_state, self.upd_busy, self.upd_error = None, "checking", None, None
        self.build()
        self.root.after(30, self.pump)
        self.root.after(10, self.reflow)
        threading.Thread(target=self.work, daemon=True, name="start").start()
        threading.Thread(target=self.update_loop, daemon=True, name="updates").start()

    def px(self, n):
        return max(1, int(round(n * self.k)))

    # ---- frame of the window: rounded, dragged by the black header, own buttons
    def build(self):
        r = self.root
        self.inset = int(self.px(RADIUS) * 0.3) + 1
        self.W = self.px(W_LOGICAL)
        self.bgc = tk.Canvas(r, bg=KEY, highlightthickness=0, bd=0)
        self.bgc.place(x=0, y=0, relwidth=1, relheight=1)

        self.head = tk.Frame(r, bg=HEAD)
        top = tk.Frame(self.head, bg=HEAD)
        top.pack(fill="x", padx=self.px(14), pady=(self.px(6), self.px(8)))
        self.logo = None
        try:
            from PIL import Image, ImageTk
            im = Image.open(ICON)
            if (256, 256) in im.info.get("sizes", ()):
                im.size = (256, 256)
            n = self.px(40)
            self.logo = ImageTk.PhotoImage(im.convert("RGBA").resize((n, n), Image.LANCZOS))
            tk.Label(top, image=self.logo, bg=HEAD).pack(side="left")
        except Exception:
            pass
        tk.Label(top, text="RemoteDesk", font=(FONT, 16, "bold"), fg=WHITE, bg=HEAD).pack(
            side="left", padx=(self.px(10), 0))
        tk.Label(top, text=VERSION, font=(FONT, 8), fg="#6B6B73", bg=HEAD).pack(
            side="left", anchor="s", padx=(self.px(6), 0), pady=(0, self.px(9)))
        # the bell: new versions of the program arrive here
        self.bell = tk.Label(top, bg=HEAD, cursor="hand2", bd=0)
        self.bell.pack(side="left", padx=(self.px(10), 0))
        self.bell.bind("<Button-1>", lambda e: self.open_updates())
        self.bell.bind("<Enter>", lambda e: self.draw_bell(True))
        self.bell.bind("<Leave>", lambda e: self.draw_bell())
        self.draw_bell()
        btns = tk.Frame(top, bg=HEAD)
        btns.pack(side="right", anchor="n")
        for text, cmd in (("—", self.minimize), ("✕", self.quit)):
            b = tk.Label(btns, text=text, font=(FONT, 11), fg=HMUTED, bg=HEAD, cursor="hand2",
                         padx=self.px(7))
            b.pack(side="left")
            b.bind("<Button-1>", lambda e, c=cmd: c())
            b.bind("<Enter>", lambda e, w=b: w.configure(fg=WHITE))
            b.bind("<Leave>", lambda e, w=b: w.configure(fg=HMUTED))
        self.btns = btns
        self.drag_bind(self.head, skip=(btns, self.bell))

        self.body = tk.Frame(r, bg=BODY)
        self.wrap = self.W - 2 * self.inset - self.px(40)

        # progress: what is happening (left), percent (right), the bar under them
        self.prog = tk.Frame(self.body, bg=BODY)
        self.step = tk.Label(self.prog, text="Запуск…", font=(FONT, 10, "bold"), fg=INK, bg=BODY, anchor="w")
        self.step.grid(row=0, column=0, sticky="w")
        self.pct = tk.Label(self.prog, text="", font=(FONT, 9), fg=MUTED, bg=BODY)
        self.pct.grid(row=0, column=1, sticky="e")
        self.what = tk.Label(self.prog, text="", font=(MONO, 8), fg=MUTED, bg=BODY, anchor="w")
        self.what.grid(row=1, column=0, columnspan=2, sticky="we", pady=(self.px(1), self.px(7)))
        self.prog.columnconfigure(0, weight=1)
        st = ttk.Style()
        st.theme_use("clam")
        st.configure("RD.Horizontal.TProgressbar", troughcolor=SOFT, background=INK, bordercolor=SOFT,
                     lightcolor=INK, darkcolor=INK, thickness=self.px(6))
        self.bar = ttk.Progressbar(self.prog, style="RD.Horizontal.TProgressbar", maximum=100)
        self.bar.grid(row=2, column=0, columnspan=2, sticky="we")
        self.pbtns = tk.Frame(self.prog, bg=BODY)
        self.pbtns.grid(row=3, column=0, columnspan=2, sticky="w")
        self.prog.pack(fill="x", padx=self.px(20), pady=(self.px(22), self.px(6)))

    def drag_bind(self, widget, skip=None, also=None):
        def press(e):
            self._drag = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y())

        def move(e):
            x, y = e.x_root - self._drag[0], e.y_root - self._drag[1]
            self.root.geometry(f"+{x}+{y}")
            if self.overlay:
                self.overlay.follow()

        def walk(w):
            if skip and w in skip:
                return
            w.bind("<ButtonPress-1>", press, add="+")
            w.bind("<B1-Motion>", move, add="+")
            for c in w.winfo_children():
                walk(c)
        walk(widget)

    def hwnd(self, win=None):
        return ctypes.windll.user32.GetParent((win or self.root).winfo_id())

    def as_app_window(self, win=None):
        """A window without the Windows frame still gets its taskbar button."""
        h = self.hwnd(win)
        u = ctypes.windll.user32
        st = u.GetWindowLongW(h, -20)
        u.SetWindowLongW(h, -20, (st & ~0x80) | 0x40000)  # -TOOLWINDOW +APPWINDOW

    def minimize(self):
        ctypes.windll.user32.ShowWindow(self.hwnd(), 6)  # SW_MINIMIZE

    def reflow(self):
        """Fits the window to its content and redraws the rounded background."""
        if self._reflow_pending:
            return
        self._reflow_pending = True
        self.root.after_idle(self._reflow)

    def _reflow(self):
        self._reflow_pending = False
        self.root.update_idletasks()
        self.rounds = [b for b in self.rounds if b.winfo_exists()]
        for _ in range(3):  # inner blocks first, then the blocks around them
            if not any([b.fit() for b in self.rounds]):
                break
            self.root.update_idletasks()
        ins, W = self.inset, self.W
        hh = self.head.winfo_reqheight()
        bh = self.body.winfo_reqheight()
        H = ins + hh + bh + self.px(RADIUS) // 2 + ins
        wa = wt.RECT()
        ctypes.windll.user32.SystemParametersInfoW(0x30, 0, ctypes.byref(wa), 0)  # work area
        if self.ready and H > wa.bottom - wa.top - self.px(12) and self.qr_px > self.px(96):
            self.qr_px -= self.px(14)  # small screen: smaller QR code so everything fits
            self.draw_qr()
            return self.reflow()
        self.head.place(x=ins, y=ins, width=W - 2 * ins, height=hh)
        self.body.place(x=ins, y=ins + hh, width=W - 2 * ins, height=bh)
        if self._bg_size != (W, H):
            self._bg_size = (W, H)
            from PIL import ImageTk
            self._bg = ImageTk.PhotoImage(art.window_bg(W, H, self.px(RADIUS), ins + hh, KEY, BODY, HEAD))
            self.bgc.delete("all")
            self.bgc.create_image(0, 0, image=self._bg, anchor="nw")
        if not self._shown:
            self._shown = True
            sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
            self.root.geometry(f"{W}x{H}+{(sw - W) // 2}+{max(8, (sh - max(H, self.px(640))) // 2)}")
            self.root.deiconify()
            self.root.update_idletasks()
            self.as_app_window()
            self.root.withdraw()
            self.root.after(10, self.root.deiconify)
        else:
            x, y = self.root.winfo_x(), self.root.winfo_y()
            if y + H > wa.bottom:
                y = max(wa.top, wa.bottom - H)
            self.root.geometry(f"{W}x{H}+{x}+{y}")
        if self.overlay:
            self.overlay.follow()

    # ---- thread-safe updates
    def later(self, fn):
        with self.ui_lock:
            self.ui.append(fn)

    def pump(self):
        with self.ui_lock:
            todo, self.ui = self.ui, []
        for fn in todo:
            try:
                fn()
            except Exception:
                traceback.print_exc()
        if todo:
            self.reflow()
        self.root.after(30, self.pump)

    def set(self, pct=None, step=None, what=None):
        def go():
            if pct is not None:
                if str(self.bar["mode"]) != "determinate":
                    self.bar.stop()
                    self.bar.configure(mode="determinate")
                self.bar["value"] = pct
                self.pct.configure(text=f"{int(pct)}%")
            if step is not None:
                self.step.configure(text=step)
            if what is not None:
                self.what.configure(text=what if len(what) < 60 else "…" + what[-58:])
        self.later(go)

    def busy(self, step, what=""):
        def go():
            self.step.configure(text=step)
            self.what.configure(text=what)
            self.pct.configure(text="")
            self.bar.configure(mode="indeterminate")
            self.bar.start(12)
        self.later(go)

    def buttons(self, items):
        def go():
            for w in self.pbtns.winfo_children():
                w.destroy()
            for text, cmd in items:
                self.pill(self.pbtns, text, cmd).pack(side="left", padx=(0, self.px(8)), pady=(self.px(10), 0))
        self.later(go)

    def pill(self, parent, text, cmd, dark=False):
        b = tk.Label(parent, text=text, font=(FONT, 9, "bold" if dark else "normal"), cursor="hand2",
                     fg=HEAD if dark else INK, bg=WHITE if dark else SOFT,
                     padx=self.px(12), pady=self.px(5))
        b.bind("<Button-1>", lambda e: cmd())
        return b

    # ---- start-up steps (worker thread)
    def work(self):
        try:
            self.check_files(0, 30)
            self.start_server(30, 60)
            self.later(self.show_ready)
            threading.Thread(target=self.poll_devices, daemon=True, name="devices").start()
            self.unlock_setup()
            self.tailscale(60, 100)
        except SystemExit:
            pass
        except Exception as e:
            traceback.print_exc()
            self.later(lambda: self.show_error(str(e)))

    def check_files(self, a, b):
        """Reads every file of the program once: a broken/blocked file shows up here with its
        name, and everything after starts faster (it is already in memory)."""
        root = BUNDLE if FROZEN else os.path.dirname(SRC)
        dirs = [root] if FROZEN else [SRC, os.path.join(root, "web")]
        files = []
        for d in dirs:
            for base, _, names in os.walk(d):
                if "__pycache__" in base:
                    continue
                files += [os.path.join(base, n) for n in names]
        total = sum(os.path.getsize(f) for f in files) or 1
        done, last = 0, 0
        for f in files:
            rel = os.path.relpath(f, root)
            now = time.time()
            if now - last > 0.03:
                last = now
                self.set(a + (b - a) * done / total, "Проверяю файлы программы", rel)
            try:
                with open(f, "rb") as fh:
                    while fh.read(1 << 20):
                        pass
            except OSError as e:
                raise RuntimeError(f"Не читается файл {rel} ({e.strerror}). "
                                   "Возможно, его заблокировал антивирус.")
            done += os.path.getsize(f)
        self.set(b, "Файлы в порядке", f"{len(files)} файлов")

    def start_server(self, a, b):
        self.set(a + 2, "Загружаю настройки", "config.json — ключ доступа")
        sys.path.insert(0, SRC)
        import server
        self.server = server
        self.set(a + 10, "Загружаю видео экрана и звук", "aiortc · av (H.264) · dxcam · pyaudiowpatch")
        server.start_rtc()
        port = int(server.CFG.get("port", server.PORT))
        self.set(a + 22, "Открываю доступ", f"порт {port}")
        try:
            self.httpd = server.ThreadingHTTPServer(("0.0.0.0", port), server.Handler)
        except OSError:
            raise RuntimeError(f"Порт {port} занят — похоже, RemoteDesk уже запущен (проверьте другие окна).")
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True, name="http").start()
        threading.Thread(target=server.duckdns_loop, daemon=True).start()
        self.caddy = server.start_caddy()
        print(f"  Сервер запущен, порт {port}")
        self.set(b, "Сервер запущен", f"http://{home_ip() or '127.0.0.1'}:{port}")

    def unlock_setup(self):
        """Screen unlock from the phone needs a small helper running as SYSTEM (only it can type
        on the Windows lock screen). Installed once with one Windows prompt; after «Нет» it asks
        again on the next start."""
        try:
            import unlock
            import unlock_agent
            if unlock.installed_version() == unlock_agent.VERSION and unlock.agent_version():
                print("  Разблокировка экрана с телефона: включена")
                return
            exe, args = unlock.agent_exe()
            if not exe:
                print("  [!] RemoteDeskUnlock.exe не найден — разблокировка экрана недоступна")
                return
            domain, name = os.environ.get("USERDOMAIN", ""), os.environ.get("USERNAME", "")
            user = f"{domain}\\{name}" if domain else name
            print("  Включаю разблокировку экрана с телефона — Windows спросит разрешение")
            code = run_as_admin(exe, f'{args} --install "{user}"'.strip())
            if code is None:
                print("  Разблокировка экрана: отменено (спрошу при следующем запуске)")
                return
            for _ in range(20):
                if unlock.agent_version():
                    print("  Разблокировка экрана с телефона: включена")
                    return
                time.sleep(0.5)
            print(f"  [!] Разблокировка экрана не запустилась (код {code})")
        except Exception:
            traceback.print_exc()

    def tailscale(self, a, b):
        """Installs Tailscale when it is missing (one Windows prompt), connects it and opens the
        sign-in page — after that the 100.x.x.x address works from anywhere."""
        self.later(lambda: self.prog.pack(fill="x", padx=self.px(20), pady=(self.px(14), 0),
                                          before=self.devbox))
        need_install, need_fw = not ts_exe(), not firewall_ok()
        if need_install:
            arch = "arm64" if platform.machine().upper() in ("ARM64", "AARCH64") else "amd64"
            url = TS_MSI.format(arch)
            msi = os.path.join(os.environ.get("TEMP") or DATA, f"tailscale-setup-{arch}.msi")
            self.set(a, "Скачиваю Tailscale (доступ не из дома)", "pkgs.tailscale.com — официальный сайт")
            try:
                with urllib.request.urlopen(url, timeout=30) as resp, open(msi, "wb") as out:
                    size = int(resp.headers.get("Content-Length") or 0)
                    name = os.path.basename(resp.geturl())
                    got = 0
                    while True:
                        chunk = resp.read(1 << 16)
                        if not chunk:
                            break
                        out.write(chunk)
                        got += len(chunk)
                        if size:
                            self.set(a + 15 * got / size, None,
                                     f"{name} — {got / 1048576:.1f} из {size / 1048576:.1f} МБ")
            except Exception as e:
                print(f"  [!] Tailscale не скачался: {e}")
                return self.ts_done("Tailscale не скачался — дома по Wi-Fi всё работает", retry=True)
        if need_install or need_fw:
            self.set(a + 16, "Устанавливаю Tailscale" if need_install else "Разрешаю доступ в брандмауэре",
                     "Windows спросит разрешение — нажмите «Да»")
            cmd = os.path.join(os.environ.get("TEMP") or DATA, "remotedesk-setup.cmd")
            lines = ["@echo off", "set rc=0"]
            if need_install:
                lines += [f'start "" /wait msiexec /i "{msi}" /quiet /norestart TS_NOLAUNCH=1', "set rc=%errorlevel%"]
            if need_fw:
                lines += ['netsh advfirewall firewall delete rule name="RemoteDesk" >nul 2>&1',
                          f'netsh advfirewall firewall add rule name="RemoteDesk" dir=in action=allow '
                          f'program="{sys.executable}" enable=yes profile=any >nul']
            lines += ["exit /b %rc%"]
            with open(cmd, "w", encoding="cp866", errors="replace") as f:
                f.write("\r\n".join(lines) + "\r\n")
            code = run_as_admin(cmd, "")
            if code is None:
                print("  [!] Установка отменена")
                if need_install:
                    return self.ts_done("Установка отменена — пока только дома по Wi-Fi", retry=True)
            elif need_install and code not in (0, 3010):
                print(f"  [!] Установщик Tailscale вернул код {code}")
                return self.ts_done(f"Tailscale не установился (код {code})", retry=True)
        if not ts_exe():
            return self.ts_done("Tailscale не установлен — пока только дома по Wi-Fi", retry=True)

        self.set(a + 24, "Подключаю Tailscale", "служба Tailscale")
        state, ip = "", None
        for _ in range(30):  # the service needs a few seconds after installation
            state, ip = ts_status()
            if state and state != "NoState":
                break
            time.sleep(1)
        if not (state == "Running" and ip):
            self.ts_login()
            state, ip = ts_status()
        ipn = ts_exe("tailscale-ipn.exe")  # the tray icon (it also starts with Windows)
        if ipn and "tailscale-ipn.exe" not in run(["tasklist", "/FI", "IMAGENAME eq tailscale-ipn.exe"])[1]:
            try:
                subprocess.Popen([ipn], creationflags=NO_WINDOW)
            except Exception:
                pass
        if state == "Running" and ip:
            self.ts_ip = ip
            print(f"  Tailscale подключён: {ip}")
            return self.ts_done(None)
        self.ts_done("Tailscale не подключён — пока только дома по Wi-Fi", retry=True)

    def ts_login(self):
        """`tailscale up` prints a sign-in link: open it in the browser and wait."""
        self.busy("Войдите в Tailscale в браузере", "страница входа откроется сама…")
        try:
            p = subprocess.Popen([ts_exe(), "up"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
        except Exception as e:
            print(f"  [!] tailscale up: {e}")
            return

        def read():
            for raw in p.stdout:
                line = raw.decode("utf-8", "replace").strip()
                m = re.search(r"https://login\.tailscale\.com/\S+", line)
                if m and not self.ts_url:
                    self.ts_url = m.group(0)
                    webbrowser.open(self.ts_url)
                    self.busy("Войдите в Tailscale в браузере", "Google / Microsoft / Apple / GitHub — бесплатно")
                    self.buttons([("Открыть вход снова", lambda: webbrowser.open(self.ts_url)),
                                  ("Пропустить", self.ts_skip.set)])
        threading.Thread(target=read, daemon=True).start()
        self.buttons([("Пропустить", self.ts_skip.set)])
        end = time.time() + 900
        while time.time() < end and not self.ts_skip.is_set():
            if p.poll() is not None:
                break
            state, ip = ts_status()
            if state == "Running" and ip:
                break
            time.sleep(2)
        if p.poll() is None:
            p.terminate()
        self.buttons([])

    def ts_done(self, problem, retry=False):
        def go():
            self.bar.stop()
            self.prog.pack_forget()
            for w in self.pbtns.winfo_children():
                w.destroy()
            self.problem, self.can_retry = problem, retry
            self.fill_addresses()
        self.later(go)

    def retry_tailscale(self):
        self.problem, self.can_retry, self.ts_url = None, False, None
        self.ts_skip.clear()
        self.fill_addresses()
        threading.Thread(target=lambda: self.tailscale(60, 100), daemon=True).start()

    # ---- ready: QR, key, addresses, devices
    def copy(self, text, label, back):
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        label.configure(text="Скопировано", fg=GREEN)
        self.root.after(1300, lambda: label.configure(text=back, fg=MUTED))

    def login_url(self):
        s = self.server
        port = int(s.CFG.get("port", s.PORT))
        return f"http://{home_ip() or '127.0.0.1'}:{port}/?k={s.CFG['key'].replace('-', '')}"

    def show_ready(self):
        self.ready = True
        s = self.server
        self.prog.pack_forget()
        b = self.body
        # QR code: the phone camera opens the app and logs in by itself
        qr = tk.Frame(b, bg=BODY)
        qr.pack(pady=(self.px(6), 0))
        self.qr_label = tk.Label(qr, bg=BODY)
        self.qr_label.pack()
        self.draw_qr()
        tk.Label(b, text="Отсканируйте камерой телефона — вход без ввода ключа",
                 font=(FONT, 9), fg=MUTED, bg=BODY).pack(pady=(self.px(3), self.px(8)))

        box = Round(b, self, SOFT, BODY, r=16, pad=10)
        box.pack(fill="x", padx=self.px(20))
        i = box.inner
        top = tk.Frame(i, bg=SOFT)
        top.pack(fill="x")
        tk.Label(top, text="Ключ доступа", font=(FONT, 9), fg=MUTED, bg=SOFT).pack(side="left")
        kc = tk.Label(top, text="копировать", font=(FONT, 9), fg=MUTED, bg=SOFT, cursor="hand2")
        kc.pack(side="right")
        raw = s.CFG["key"]
        kl = tk.Label(i, text=raw, font=(MONO, 11, "bold"), fg=INK, bg=SOFT, justify="left",
                      cursor="hand2")
        kl.pack(anchor="w", pady=(self.px(2), 0))
        for w in (kc, kl):
            w.bind("<Button-1>", lambda e: self.copy(raw, kc, "копировать"))
        # each network in its own block under the key block
        self.addr_box = tk.Frame(b, bg=BODY)
        self.addr_box.pack(fill="x", padx=self.px(20))
        self.fill_addresses()

        self.devbox = tk.Frame(b, bg=BODY)
        self.devbox.pack(fill="x", padx=self.px(20), pady=(self.px(8), 0))
        self.update_devices(force=True)

    def draw_qr(self):
        try:
            import qrcode
            from PIL import Image, ImageTk
            q = qrcode.QRCode(border=1, error_correction=qrcode.constants.ERROR_CORRECT_M)
            q.add_data(self.login_url())
            q.make(fit=True)
            n = len(q.get_matrix())
            box = max(2, self.qr_px // n)
            img = q.make_image(fill_color="black", back_color="white").get_image().convert("RGB")
            img = img.resize((n * box, n * box), Image.NEAREST)
            pad = self.px(10)
            tile = art.rounded(img.width + 2 * pad, img.height + 2 * pad, self.px(16), WHITE, BODY)
            tile.paste(img, (pad, pad))
            self._qr = ImageTk.PhotoImage(tile)
            self.qr_label.configure(image=self._qr)
        except Exception as e:
            self.qr_label.configure(text=f"QR недоступен: {e}", fg=MUTED)

    def fill_addresses(self):
        if not self.ready:
            return
        for w in self.addr_box.winfo_children():
            w.destroy()
        s = self.server
        port = int(s.CFG.get("port", s.PORT))
        hip = home_ip()

        def row(title, url=None, note=None, action=None):
            blk = Round(self.addr_box, self, SOFT, BODY, r=16, pad=10)
            blk.pack(fill="x", pady=(self.px(6), 0))
            f = blk.inner
            tk.Label(f, text=title, font=(FONT, 9), fg=MUTED, bg=SOFT).grid(row=0, column=0, sticky="w")
            f.columnconfigure(0, weight=1)
            if url:
                v = tk.Label(f, text=url, font=(MONO, 10), fg=INK, bg=SOFT, cursor="hand2")
                v.grid(row=1, column=0, sticky="w")
                c = tk.Label(f, text="копировать", font=(FONT, 9), fg=MUTED, bg=SOFT, cursor="hand2")
                c.grid(row=0, column=1, sticky="e")
                for w in (v, c):
                    w.bind("<Button-1>", lambda e, u=url, c=c: self.copy(u, c, "копировать"))
            else:
                tk.Label(f, text=note, font=(FONT, 9), fg=WARN, bg=SOFT, wraplength=self.wrap - self.px(110),
                         justify="left").grid(row=1, column=0, sticky="w")
                if action:
                    self.pill(f, action[0], action[1], dark=True).grid(row=0, column=1, rowspan=2, sticky="e")

        row("Дома (тот же Wi-Fi)", f"http://{hip}:{port}" if hip else None, "Нет подключения к сети")
        if self.ts_ip:
            row("Вне дома (через Tailscale)", f"http://{self.ts_ip}:{port}")
        elif self.problem:
            row("Вне дома (через Tailscale)", None, self.problem,
                ("Подключить", self.retry_tailscale) if self.can_retry else None)
        else:
            row("Вне дома (через Tailscale)", None, "Подключаю Tailscale…")
        self.reflow()

    # ---- connected devices
    def poll_devices(self):
        prev = {}
        while True:
            try:
                s = self.server
                peer, live, rs, rr = s.RTC.stats() if s.RTC else (None, False, 0, 0)
                devs = s.DEVICES.snapshot([peer] if live and peer else [])
                now = time.time()
                for d in devs:
                    extra = d["ip"] == peer
                    d["tx"] = d["sent"] + (rs if extra else 0)
                    d["rx"] = d["recv"] + (rr if extra else 0)
                    d["video"] = bool(extra and live)
                    p = prev.get(d["ip"])
                    if p and now > p[0]:
                        dt = now - p[0]
                        d["tx_rate"] = max(0, d["tx"] - p[1]) / dt
                        d["rx_rate"] = max(0, d["rx"] - p[2]) / dt
                    else:
                        d["tx_rate"] = d["rx_rate"] = 0
                    prev[d["ip"]] = (now, d["tx"], d["rx"])
                self.devs = devs
                self.later(self.update_devices)
            except Exception:
                traceback.print_exc()
            time.sleep(1)

    def update_devices(self, force=False):
        if not self.ready:
            return
        sig = tuple((d["ip"], d["kind"], d["model"]) for d in self.devs)
        if self.overlay:
            self.overlay.refresh()
        if sig == self.dev_sig and not force:
            return
        self.dev_sig = sig
        for w in self.devbox.winfo_children():
            w.destroy()
        if not self.devs:
            return
        tk.Label(self.devbox, text="Подключено", font=(FONT, 9), fg=MUTED, bg=BODY).pack(anchor="w")
        from PIL import ImageTk
        self._avatars = []
        for d in self.devs:
            card = Round(self.devbox, self, SOFT, BODY, r=20, pad=9)
            card.pack(fill="x", pady=(self.px(6), 0))
            i = card.inner
            av = ImageTk.PhotoImage(art.avatar(d["kind"], self.px(40)))
            self._avatars.append(av)
            tk.Label(i, image=av, bg=SOFT).pack(side="left")
            mid = tk.Frame(i, bg=SOFT)
            mid.pack(side="left", padx=(self.px(12), 0), fill="x", expand=True)
            tk.Label(mid, text=d["model"], font=(FONT, 11, "bold"), fg=INK, bg=SOFT, anchor="w").pack(anchor="w")
            tk.Label(mid, text=d["ip"], font=(FONT, 9), fg=MUTED, bg=SOFT, anchor="w").pack(anchor="w")
            tk.Label(i, text="›", font=(FONT, 18), fg=MUTED, bg=SOFT).pack(side="right", padx=(0, self.px(4)))
            set_cursor(card, "hand2")
            bind_tree(card, "<Button-1>", lambda e, ip=d["ip"]: self.open_details(ip))

    def open_details(self, ip):
        if self.overlay:
            return
        self.overlay = Details(self, ip)

    # ---- updates: the bell in the header
    def draw_bell(self, hover=False):
        from PIL import ImageTk
        new = self.upd_state == "available"
        self._bell = ImageTk.PhotoImage(art.bell(self.px(22), WHITE if hover or new else HMUTED,
                                                 GREEN if new else None, HEAD))
        self.bell.configure(image=self._bell)

    def update_loop(self):
        time.sleep(3)
        if FROZEN:  # what the previous update left behind
            shutil.rmtree(os.path.join(DATA, "update"), ignore_errors=True)
        while True:
            self.check_updates()
            time.sleep(3 * 3600)

    def check_updates(self):
        try:
            self.upd = find_update()
            self.upd_state = "available" if self.upd else "none"
        except Exception as e:
            print(f"  Проверка обновлений не удалась: {e}")
            if self.upd_state != "available":
                self.upd_state = "error"
        self.later(self.refresh_updates)

    def recheck_updates(self):
        if self.upd_state == "checking":
            return
        self.upd_state = "checking"
        self.refresh_updates()
        threading.Thread(target=self.check_updates, daemon=True).start()

    def refresh_updates(self):
        self.draw_bell()
        if isinstance(self.overlay, Updates):
            self.overlay.fill()

    def open_updates(self):
        if self.overlay or not self._shown:
            return
        self.overlay = Updates(self)

    def start_update(self):
        if self.upd_busy or not self.upd:
            return
        if not FROZEN:  # started from the source code: nothing to replace
            webbrowser.open(PAGE)
            return
        self.upd_busy, self.upd_error = "Скачиваю…", None
        self.refresh_updates()
        threading.Thread(target=self._update, daemon=True, name="update").start()

    def _update(self):
        upd, last = self.upd, [0.0]

        def note(text):
            self.upd_busy = text
            self.later(lambda: isinstance(self.overlay, Updates) and self.overlay.note(text))

        def progress(done, total):
            if time.time() - last[0] > 0.2:
                last[0] = time.time()
                note("Скачиваю… " + (f"{done * 100 // total}%" if total else size_text(done)))
        try:
            new = download_update(upd, progress)
            note("Устанавливаю…")
            spawn(os.path.join(new, "RemoteDesk.exe"), "--apply-update",
                  os.path.dirname(sys.executable), str(os.getpid()))
            time.sleep(0.6)
            self.later(self.quit)
        except Exception as e:
            traceback.print_exc()
            self.upd_busy, self.upd_error = None, f"Не удалось обновить: {e}"
            self.later(self.refresh_updates)

    def show_error(self, msg):
        self.bar.stop()
        self.bar.configure(mode="determinate")
        self.step.configure(text="Не удалось запустить", fg=BAD)
        self.what.configure(text="")
        tk.Label(self.body, text=msg, font=(FONT, 10), fg=INK, bg=BODY, wraplength=self.wrap,
                 justify="left").pack(anchor="w", padx=self.px(20), pady=(self.px(12), 0))
        tk.Label(self.body, text=f"Подробности: {LOG.path}", font=(FONT, 8), fg=MUTED, bg=BODY,
                 wraplength=self.wrap, justify="left").pack(anchor="w", padx=self.px(20), pady=(self.px(8), self.px(10)))
        self.reflow()

    def quit(self):
        try:
            if self.caddy:
                self.caddy.terminate()
        except Exception:
            pass
        os._exit(0)


class Details:
    """Connection details: a window exactly over the main one that fades and slides in."""

    def __init__(self, app, ip):
        self.app, self.ip = app, ip
        px = app.px
        t = self.top = tk.Toplevel(app.root)
        t.withdraw()
        t.overrideredirect(True)
        t.configure(bg=KEY)
        t.attributes("-transparentcolor", KEY)
        t.attributes("-alpha", 0.0)
        r = app.root
        self.W, self.H = r.winfo_width(), r.winfo_height()
        from PIL import ImageTk
        self._bg = ImageTk.PhotoImage(art.window_bg(self.W, self.H, px(RADIUS), 0, KEY, BODY, HEAD))
        c = tk.Canvas(t, bg=KEY, highlightthickness=0, bd=0)
        c.place(x=0, y=0, relwidth=1, relheight=1)
        c.create_image(0, 0, image=self._bg, anchor="nw")
        ins = app.inset
        f = self.f = tk.Frame(t, bg=BODY)
        f.place(x=ins, y=ins, width=self.W - 2 * ins, height=self.H - 2 * ins - px(RADIUS) // 3)

        bar = tk.Frame(f, bg=BODY)
        bar.pack(fill="x", padx=px(14), pady=(px(10), 0))
        n = px(34)
        self._close = ImageTk.PhotoImage(art.rounded(n, n, n // 2, SOFT, BODY))
        x = tk.Label(bar, image=self._close, text="✕", compound="center", font=(FONT, 10), fg=INK,
                     bg=BODY, cursor="hand2", bd=0)
        x.pack(side="right")
        x.bind("<Button-1>", lambda e: self.close())
        tk.Label(f, text="Подключение", font=(FONT, 15, "bold"), fg=INK, bg=BODY).pack(pady=(px(2), 0))
        self.status = tk.Label(f, text="", font=(FONT, 9), fg=GREEN, bg=BODY)
        self.status.pack()
        self.drag(bar)

        self.space = tk.Frame(f, bg=BODY, height=px(10))
        self.space.pack()
        d = self.dev() or {"kind": "phone", "model": "Устройство"}
        # the picture: phone … Wi-Fi … laptop
        pic = tk.Frame(f, bg=BODY)
        pic.pack()
        left = tk.Frame(pic, bg=BODY)
        left.grid(row=0, column=0, sticky="s")
        mid = tk.Frame(pic, bg=BODY)
        mid.grid(row=0, column=1, padx=px(6))
        right = tk.Frame(pic, bg=BODY)
        right.grid(row=0, column=2, sticky="s")
        kind = d["kind"]
        size = {"phone": (52, 104), "tablet": (78, 104)}.get(kind, (130, 84))
        self._imgs = [ImageTk.PhotoImage(art.device(kind, px(size[0]), px(size[1]))),
                      ImageTk.PhotoImage(art.laptop(px(150), px(96))),
                      ImageTk.PhotoImage(art.wifi(px(26)))]
        tk.Label(left, image=self._imgs[0], bg=BODY).pack()
        tk.Label(right, image=self._imgs[1], bg=BODY).pack()
        self.dots = tk.Canvas(mid, bg=BODY, width=px(84), height=px(30), highlightthickness=0)
        self.dots.pack()
        self.dots.create_image(px(42), px(15), image=self._imgs[2])
        self.dot_ids = []
        for k, xx in enumerate((6, 16, 26, 58, 68, 78)):
            self.dot_ids.append(self.dots.create_oval(px(xx) - px(2), px(15) - px(2), px(xx) + px(2),
                                                      px(15) + px(2), fill=LINE, outline=""))
        cap = tk.Frame(pic, bg=BODY)
        for col, small, big in ((0, "Подключено с", d["model"]), (2, "Подключено к", app.pc)):
            g = tk.Frame(pic, bg=BODY)
            g.grid(row=1, column=col, pady=(px(8), 0))
            tk.Label(g, text=small, font=(FONT, 8), fg=MUTED, bg=BODY).pack()
            tk.Label(g, text=big, font=(FONT, 9, "bold"), fg=INK, bg=BODY,
                     wraplength=px(150)).pack()
        del cap

        # details block
        box = Round(f, app, SOFT, BODY, r=20, pad=6)
        box.pack(fill="x", padx=px(22), pady=(px(26), 0))
        tk.Label(box.inner, text="ⓘ  Детали подключения", font=(FONT, 10, "bold"), fg=INK, bg=SOFT).pack(
            pady=(px(6), px(8)))
        inner = Round(box.inner, app, CARD2, SOFT, r=16, pad=14)
        inner.pack(fill="x")
        self.vals = {}
        rows = [("speed", "Скорость передачи"), ("tx", "Передано на устройство"),
                ("rx", "Принято с устройства"), ("time", "Время работы"),
                ("model", "Модель устройства"), ("ip", "IP-адрес"), ("net", "Канал")]
        for n, (k, title) in enumerate(rows):
            tk.Label(inner.inner, text=title, font=(FONT, 9), fg=MUTED, bg=CARD2).grid(
                row=n, column=0, sticky="w", pady=px(3))
            v = tk.Label(inner.inner, text="—", font=(FONT, 9), fg=INK, bg=CARD2)
            v.grid(row=n, column=1, sticky="e", pady=px(3))
            self.vals[k] = v
        inner.inner.columnconfigure(0, weight=1)

        # turn this device off: the server refuses it until the phone connects again on purpose
        bw, bh = self.W - 2 * ins - 2 * px(22), px(42)
        self._kick = ImageTk.PhotoImage(art.rounded(bw, bh, px(16), SOFT, BODY))
        kb = tk.Label(f, image=self._kick, text="Отключить устройство", compound="center",
                      font=(FONT, 10, "bold"), fg=BAD, bg=BODY, cursor="hand2", bd=0)
        kb.pack(pady=(px(12), 0))
        kb.bind("<Button-1>", lambda e: self.kick())
        self.refresh()

        t.update_idletasks()
        need = f.winfo_reqheight() - self.space.winfo_reqheight()
        tail = px(RADIUS) // 3 + px(18)  # room under the last button
        if self.H < need + 2 * ins + tail + px(12):
            # taller than the main window: grow so the «Отключить устройство» button is visible
            self.H = need + 2 * ins + tail + px(12)
            self._bg = ImageTk.PhotoImage(art.window_bg(self.W, self.H, px(RADIUS), 0, KEY, BODY, HEAD))
            c.delete("all")
            c.create_image(0, 0, image=self._bg, anchor="nw")
            f.place_configure(height=self.H - 2 * ins - px(RADIUS) // 3)
        free = self.H - 2 * ins - need - tail
        self.space.configure(height=max(px(6), int(free * 0.32)))
        self.base = (r.winfo_x(), r.winfo_y())
        self.lift = px(26)
        t.geometry(f"{self.W}x{self.H}+{self.base[0]}+{self.base[1] + self.lift}")
        t.deiconify()
        t.lift()
        self.tick, self.closing = 0, False
        self.animate(0, opening=True)
        self.spin()

    def dev(self):
        return next((d for d in self.app.devs if d["ip"] == self.ip), None)

    def drag(self, w):
        def press(e):
            self._d = (e.x_root - self.top.winfo_x(), e.y_root - self.top.winfo_y())

        def move(e):
            x, y = e.x_root - self._d[0], e.y_root - self._d[1]
            self.top.geometry(f"+{x}+{y}")
            self.app.root.geometry(f"+{x}+{y}")
        w.bind("<ButtonPress-1>", press)
        w.bind("<B1-Motion>", move)

    def follow(self):
        r = self.app.root
        self.top.geometry(f"+{r.winfo_x()}+{r.winfo_y()}")

    def animate(self, i, opening):
        n = 14
        t = i / n
        e = 1 - (1 - t) ** 3
        k = e if opening else 1 - e
        try:
            self.top.attributes("-alpha", k)
            r = self.app.root
            self.top.geometry(f"+{r.winfo_x()}+{r.winfo_y() + int(self.lift * (1 - k))}")
        except tk.TclError:
            return
        if i < n:
            self.top.after(16, lambda: self.animate(i + 1, opening))
        elif not opening:
            self.top.destroy()
            self.app.overlay = None

    def spin(self):
        """Dots run from the phone to the computer while it is connected."""
        if self.closing:
            return
        self.tick += 1
        on = self.dev() is not None
        for k, oid in enumerate(self.dot_ids):
            lit = on and (self.tick % 6) == k
            self.dots.itemconfigure(oid, fill=INK if lit else LINE)
        self.top.after(160, self.spin)

    def refresh(self):
        d = self.dev()
        if not d:
            self.status.configure(text="Устройство отключилось", fg=BAD)
            return
        self.status.configure(text="● Подключено" + (" · видео экрана" if d.get("video") else ""), fg=GREEN)
        v = self.vals
        v["speed"].configure(text=f"↓ {rate_text(d.get('tx_rate', 0))}   ↑ {rate_text(d.get('rx_rate', 0))}")
        v["tx"].configure(text=size_text(d.get("tx", 0)))
        v["rx"].configure(text=size_text(d.get("rx", 0)))
        v["time"].configure(text=time_text(time.time() - d["since"]))
        v["model"].configure(text=d["model"])
        v["ip"].configure(text=d["ip"])
        v["net"].configure(text="Tailscale (зашифрован)" if d["ip"].startswith("100.") else "Домашняя сеть")

    def kick(self):
        try:
            self.app.server.DEVICES.kick(self.ip)
        except Exception:
            traceback.print_exc()
        self.app.devs = [d for d in self.app.devs if d["ip"] != self.ip]
        self.app.update_devices(force=True)
        self.app.reflow()
        self.close()

    def close(self):
        if self.closing:
            return
        self.closing = True
        self.animate(0, opening=False)


class Updates(Details):
    """The bell: the new version, what changed in it and the «Обновить» button.
    The same sliding window as Details."""

    def __init__(self, app):
        self.app, self.ip = app, None
        px = app.px
        t = self.top = tk.Toplevel(app.root)
        t.withdraw()
        t.overrideredirect(True)
        t.configure(bg=KEY)
        t.attributes("-transparentcolor", KEY)
        t.attributes("-alpha", 0.0)
        r = app.root
        self.W, self.H, self._h = r.winfo_width(), r.winfo_height(), None
        self.canvas = tk.Canvas(t, bg=KEY, highlightthickness=0, bd=0)
        self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
        f = self.f = tk.Frame(t, bg=BODY)

        bar = tk.Frame(f, bg=BODY)
        bar.pack(fill="x", padx=px(14), pady=(px(10), 0))
        from PIL import ImageTk
        n = px(34)
        self._close = ImageTk.PhotoImage(art.rounded(n, n, n // 2, SOFT, BODY))
        x = tk.Label(bar, image=self._close, text="✕", compound="center", font=(FONT, 10), fg=INK,
                     bg=BODY, cursor="hand2", bd=0)
        x.pack(side="right")
        x.bind("<Button-1>", lambda e: self.close())
        tk.Label(f, text="Обновления", font=(FONT, 15, "bold"), fg=INK, bg=BODY).pack(pady=(px(2), 0))
        tk.Label(f, text=f"Установлена версия {VERSION}", font=(FONT, 9), fg=MUTED, bg=BODY).pack()
        self.drag(bar)
        self.box = tk.Frame(f, bg=BODY)
        self.box.pack(fill="x", padx=px(22), pady=(px(18), 0))
        self.btn = None
        self.fill()

        self.base = (r.winfo_x(), r.winfo_y())
        self.lift = px(26)
        t.geometry(f"{self.W}x{self.H}+{self.base[0]}+{self.base[1] + self.lift}")
        t.deiconify()
        t.lift()
        self.tick, self.closing = 0, False
        self.animate(0, opening=True)

    def refresh(self):  # the devices timer calls this on any open window
        pass

    def note(self, text):
        """Download progress on the button, without rebuilding the window."""
        if self.btn and self.btn.winfo_exists():
            self.btn.configure(text=text)

    def fill(self):
        app, px = self.app, self.app.px
        from PIL import ImageTk
        for w in self.box.winfo_children():
            w.destroy()
        self.btn = None
        u, st = app.upd, app.upd_state
        wide = self.W - 2 * app.inset - 2 * px(22)
        if st != "checking" and u:
            card = Round(self.box, app, SOFT, BODY, r=20, pad=16)
            card.pack(fill="x")
            i = card.inner
            head = tk.Frame(i, bg=SOFT)
            head.pack(fill="x")
            tk.Label(head, text=f"RemoteDesk {u['ver']}", font=(FONT, 12, "bold"), fg=INK, bg=SOFT).pack(side="left")
            tk.Label(head, text="●  новая версия", font=(FONT, 8, "bold"), fg=GREEN, bg=SOFT).pack(
                side="left", padx=(px(10), 0))
            tk.Label(head, text=u["date"], font=(FONT, 9), fg=MUTED, bg=SOFT).pack(side="right")
            text = u["notes"] or "Описание не указано."
            if u["title"] and u["ver"] not in u["title"] and u["title"] not in text:
                text = u["title"] + "\n\n" + text
            tk.Label(i, text=text, font=(FONT, 9), fg="#C7C7CC", bg=SOFT, justify="left", anchor="w",
                     wraplength=wide - 2 * px(16)).pack(fill="x", pady=(px(10), 0))
            busy = app.upd_busy
            self._btn = ImageTk.PhotoImage(art.rounded(wide, px(42), px(16), CARD2 if busy else WHITE, BODY))
            b = self.btn = tk.Label(self.box, image=self._btn, text=busy or f"Обновить до {u['ver']}",
                                    compound="center", font=(FONT, 10, "bold"), bd=0, bg=BODY,
                                    fg=MUTED if busy else HEAD, cursor="arrow" if busy else "hand2")
            b.pack(pady=(px(12), 0))
            if not busy:
                b.bind("<Button-1>", lambda e: app.start_update())
            if app.upd_error:
                tk.Label(self.box, text=app.upd_error, font=(FONT, 9), fg=BAD, bg=BODY, justify="left",
                         wraplength=wide).pack(anchor="w", pady=(px(8), 0))
            tk.Label(self.box, text="Программа закроется и откроется уже обновлённой.\n"
                                    "Ключ доступа и настройки сохранятся.",
                     font=(FONT, 8), fg=MUTED, bg=BODY, justify="center").pack(pady=(px(10), 0))
        else:
            big, small = {
                "checking": ("Проверяю обновления…", "Это займёт несколько секунд."),
                "error": ("Не удалось проверить обновления", "Проверьте подключение к интернету."),
            }.get(st, ("У вас последняя версия", "Когда выйдет новая, здесь появится уведомление,\n"
                                                   "а на колокольчике — зелёная точка."))
            card = Round(self.box, app, SOFT, BODY, r=20, pad=18)
            card.pack(fill="x")
            self._pic = ImageTk.PhotoImage(art.bell(px(40), MUTED, None, SOFT))
            tk.Label(card.inner, image=self._pic, bg=SOFT).pack()
            tk.Label(card.inner, text=big, font=(FONT, 11, "bold"), fg=INK, bg=SOFT).pack(pady=(px(8), 0))
            tk.Label(card.inner, text=small, font=(FONT, 9), fg=MUTED, bg=SOFT, justify="center").pack(
                pady=(px(2), 0))
            if st != "checking":
                self._btn = ImageTk.PhotoImage(art.rounded(wide, px(42), px(16), SOFT, BODY))
                b = tk.Label(self.box, image=self._btn, text="Проверить ещё раз", compound="center",
                             font=(FONT, 10, "bold"), fg=INK, bg=BODY, cursor="hand2", bd=0)
                b.pack(pady=(px(12), 0))
                b.bind("<Button-1>", lambda e: app.recheck_updates())
        self.size()

    def size(self):
        """As tall as the main window, taller when the text of the update needs it."""
        app, px = self.app, self.app.px
        app._reflow()  # fits the rounded blocks to their content
        self.top.update_idletasks()
        ins = app.inset
        need = self.f.winfo_reqheight() + 2 * ins + px(RADIUS) // 3 + px(18)
        H = max(app.root.winfo_height(), need)
        if H == self._h:
            return
        self._h = self.H = H
        from PIL import ImageTk
        self._bg = ImageTk.PhotoImage(art.window_bg(self.W, H, px(RADIUS), 0, KEY, BODY, HEAD))
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, image=self._bg, anchor="nw")
        self.f.place(x=ins, y=ins, width=self.W - 2 * ins, height=H - 2 * ins - px(RADIUS) // 3)
        self.top.geometry(f"{self.W}x{H}")


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--apply-update":
        apply_update(sys.argv[2], sys.argv[3])
        return
    App().root.mainloop()


if __name__ == "__main__":
    main()
