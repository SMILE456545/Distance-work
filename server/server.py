# -*- coding: utf-8 -*-
"""RemoteDesk server: shares this Windows PC's screen, mouse, keyboard and a
command line with the RemoteDesk Flutter app over the local network."""
import ctypes
import ctypes.wintypes as wt
import hashlib
import io
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    ctypes.windll.user32.SetProcessDPIAware()

import struct

import mss
from PIL import Image, ImageChops, ImageDraw

import unlock
import pty_win

HERE = os.path.dirname(os.path.abspath(__file__))
# Packed into RemoteDesk.exe: the phone app is inside the exe, and settings (the key) live in
# %APPDATA%\RemoteDesk so every person who runs the exe gets their own key.
FROZEN = getattr(sys, "frozen", False)
if FROZEN:
    HERE = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "RemoteDesk")
    os.makedirs(HERE, exist_ok=True)
CONFIG = os.path.join(HERE, "config.json")
WEB_DIR = (os.path.join(sys._MEIPASS, "web") if FROZEN
           else os.path.join(os.path.dirname(HERE), "web"))
PORT = 8765

user32 = ctypes.windll.user32


# ---------------------------------------------------------------- config
KEY_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L — easy to type


KEY_LEN = 32


def new_key():
    """32 characters ≈ 158 bits (typed once — after that the QR code in the PC window logs in)."""
    raw = "".join(secrets.choice(KEY_ALPHABET) for _ in range(KEY_LEN))
    return "-".join(raw[i:i + 4] for i in range(0, KEY_LEN, 4))


def save_config(cfg):
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def load_config():
    cfg = {}
    if os.path.exists(CONFIG):
        try:
            with open(CONFIG, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            cfg = {}
    # older, shorter keys are replaced by a 32-character one
    if len(cfg.get("key", "").replace("-", "")) < KEY_LEN:
        cfg["key"] = new_key()
    cfg.setdefault("port", PORT)
    cfg.setdefault("domain", "")          # e.g. mydesk.duckdns.org
    cfg.setdefault("duckdns_token", "")
    cfg.setdefault("https_port", 8443)    # forwarded on the router (TCP)
    cfg.setdefault("rtc_port", 8766)      # forwarded on the router (UDP), video
    save_config(cfg)
    return cfg


CFG = load_config()


# ---------------------------------------------------------------- protection from guessing the key
LOG_FILE = os.path.join(HERE, "access.log")


class Guard:
    """After 5 different wrong keys from one address it is blocked for 15 minutes,
    then for longer and longer (up to a day). Only *different* keys count: a phone
    that keeps retrying with an old saved key is not guessing and isn't blocked.
    Too many wrong keys from everywhere together slow every wrong attempt down."""

    MAX_FAILS, WINDOW, BAN = 5, 600, 900

    def __init__(self):
        self.lock = threading.Lock()
        self.fails = {}       # ip -> [times]
        self.banned = {}      # ip -> until
        self.strikes = {}     # ip -> how many times banned
        self.all_fails = []
        self.known = set()

    def blocked(self, ip):
        with self.lock:
            until = self.banned.get(ip, 0)
            return max(0, int(until - time.time()))

    def fail(self, ip, path, key):
        now = time.time()
        tag = hashlib.sha256(key.encode()).hexdigest()[:16]
        with self.lock:
            f = {k: t for k, t in self.fails.get(ip, {}).items() if now - t < self.WINDOW}
            repeat = tag in f
            f[tag] = now
            self.fails[ip] = f
            self.all_fails = [t for t in self.all_fails if now - t < 3600] + [now]
            banned = len(f) >= self.MAX_FAILS
            if banned:
                n = self.strikes[ip] = self.strikes.get(ip, 0) + 1
                self.banned[ip] = now + min(86400, self.BAN * 4 ** (n - 1))
                self.fails[ip] = {}
            many = len(self.all_fails)
        if repeat and not banned:
            time.sleep(0.5)
            return
        log(f"НЕВЕРНЫЙ КЛЮЧ  {ip}  {path}" + ("  → заблокирован" if banned else ""))
        if banned:
            print(f"  [!] {time.strftime('%H:%M')} адрес {ip} заблокирован: много неверных ключей")
        time.sleep(0.5 if many < 20 else 3)

    def ok(self, ip):
        with self.lock:
            self.fails.pop(ip, None)
            new = ip not in self.known
            self.known.add(ip)
        if new:
            log(f"ВХОД  {ip}")
            print(f"  [+] {time.strftime('%H:%M')} подключение с адреса {ip}")


def log(text):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {text}\n")
    except OSError:
        pass


GUARD = Guard()


# ---------------------------------------------------------------- internet address (DuckDNS)
PUBLIC = {"ip": None}


def fetch_public_ip():
    import urllib.request
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                ip = r.read().decode().strip()
                socket.inet_aton(ip)
                return ip
        except Exception:
            continue
    return None


def duckdns_loop():
    """Keeps <name>.duckdns.org pointing at this laptop when the provider changes the IP."""
    import urllib.request
    last = None
    while True:
        ip = fetch_public_ip()
        if ip:
            PUBLIC["ip"] = ip
            if CFG.get("domain") and CFG.get("duckdns_token") and ip != last:
                name = CFG["domain"].split(".")[0]
                url = (f"https://www.duckdns.org/update?domains={name}"
                       f"&token={CFG['duckdns_token']}&ip={ip}")
                try:
                    with urllib.request.urlopen(url, timeout=10) as r:
                        if r.read().strip() == b"OK":
                            last = ip
                            log(f"DuckDNS: {CFG['domain']} → {ip}")
                        else:
                            print("  [!] DuckDNS не принял обновление — проверьте домен и токен в config.json")
                except Exception:
                    pass
        time.sleep(300)


# ---------------------------------------------------------------- HTTPS (Caddy)
CADDY = os.path.join(HERE, "bin", "caddy.exe")


def start_caddy():
    """Caddy gets a free Let's Encrypt certificate for the DuckDNS name, renews it
    by itself and passes HTTPS traffic to this server."""
    if not (CFG.get("domain") and CFG.get("duckdns_token") and os.path.isfile(CADDY)):
        return None
    caddyfile = os.path.join(HERE, "bin", "Caddyfile")
    with open(caddyfile, "w", encoding="utf-8") as f:
        f.write(f"""{{
	admin off
	http_port 18080
	https_port {CFG['https_port']}
	auto_https disable_redirects
}}

{CFG['domain']}:{CFG['https_port']} {{
	tls {{
		dns duckdns {{env.DUCKDNS_TOKEN}}
		resolvers 1.1.1.1 8.8.8.8
	}}
	header Strict-Transport-Security "max-age=31536000"
	reverse_proxy 127.0.0.1:{CFG['port']} {{
		flush_interval -1
	}}
}}
""")
    env = dict(os.environ, DUCKDNS_TOKEN=CFG["duckdns_token"])
    logf = open(os.path.join(HERE, "bin", "caddy.log"), "ab")
    p = subprocess.Popen([CADDY, "run", "--config", caddyfile, "--adapter", "caddyfile"],
                         cwd=os.path.join(HERE, "bin"), env=env, stdout=logf, stderr=logf,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    _kill_with_us(p)
    return p


def _kill_with_us(proc):
    """Caddy closes together with this window (even when it is closed with the cross)."""
    k = ctypes.windll.kernel32
    k.CreateJobObjectW.restype = wt.HANDLE
    k.OpenProcess.restype = wt.HANDLE
    job = k.CreateJobObjectW(None, None)

    class LIMITS(ctypes.Structure):
        _fields_ = [("a", ctypes.c_int64), ("b", ctypes.c_int64), ("flags", wt.DWORD),
                    ("c", ctypes.c_size_t), ("d", ctypes.c_size_t), ("e", wt.DWORD),
                    ("f", ctypes.c_size_t), ("g", wt.DWORD), ("h", wt.DWORD)]

    class EXT(ctypes.Structure):
        _fields_ = [("basic", LIMITS), ("io", ctypes.c_uint64 * 6), ("x", ctypes.c_size_t * 4)]

    info = EXT()
    info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    k.SetInformationJobObject(wt.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info))
    h = k.OpenProcess(0x1F0FFF, False, proc.pid)
    k.AssignProcessToJobObject(wt.HANDLE(job), wt.HANDLE(h))
    _JOBS.append(job)


_JOBS = []


# ---------------------------------------------------------------- input (SendInput)
ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]


class _U(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _U)]


MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP = 0x0008, 0x0010
MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP = 0x0020, 0x0040
MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x0800, 0x1000
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x1, 0x2, 0x4

BUTTONS = {
    "left": (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
    "right": (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
    "middle": (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
}

VK = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "shift": 0x10, "ctrl": 0x11,
    "alt": 0x12, "pause": 0x13, "capslock": 0x14, "esc": 0x1B, "space": 0x20,
    "pageup": 0x21, "pagedown": 0x22, "end": 0x23, "home": 0x24, "left": 0x25,
    "up": 0x26, "right": 0x27, "down": 0x28, "printscreen": 0x2C, "insert": 0x2D,
    "delete": 0x2E, "win": 0x5B, "menu": 0x5D,
    "volumemute": 0xAD, "volumedown": 0xAE, "volumeup": 0xAF,
    "medianext": 0xB0, "mediaprev": 0xB1, "mediaplay": 0xB3,
}
for i in range(1, 13):
    VK[f"f{i}"] = 0x6F + i
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B, 0x5D}


def _send(*inputs):
    arr = (INPUT * len(inputs))(*inputs)
    user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))


def _mouse(flags, data=0):
    i = INPUT(type=0)
    i.u.mi = MOUSEINPUT(0, 0, ctypes.c_ulong(data & 0xFFFFFFFF).value, flags, 0, 0)
    return i


def _key(vk=0, scan=0, flags=0):
    i = INPUT(type=1)
    i.u.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return i


def vk_of(name):
    name = name.lower()
    if name in VK:
        return VK[name]
    if len(name) == 1:
        r = user32.VkKeyScanW(ord(name))
        if r != -1:
            return r & 0xFF
    raise ValueError(f"unknown key {name}")


def press_combo(keys):
    vks = [vk_of(k) for k in keys]
    downs = [_key(v, 0, KEYEVENTF_EXTENDEDKEY if v in EXTENDED else 0) for v in vks]
    ups = [_key(v, 0, KEYEVENTF_KEYUP | (KEYEVENTF_EXTENDEDKEY if v in EXTENDED else 0))
           for v in reversed(vks)]
    _send(*downs)
    time.sleep(0.02)
    _send(*ups)


def type_text(text):
    seq = []
    for ch in text:
        if ch == "\n":
            seq += [_key(0x0D), _key(0x0D, 0, KEYEVENTF_KEYUP)]
            continue
        code = ord(ch)
        units = [code] if code <= 0xFFFF else [
            0xD800 + ((code - 0x10000) >> 10), 0xDC00 + ((code - 0x10000) & 0x3FF)]
        for u in units:
            seq.append(_key(0, u, KEYEVENTF_UNICODE))
            seq.append(_key(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP))
    if seq:
        _send(*seq)


# ---------------------------------------------------------------- screen
_MSS = getattr(mss, "MSS", None) or mss.mss
_tls = threading.local()


def sct():
    if not hasattr(_tls, "sct"):
        _tls.sct = _MSS()
    return _tls.sct


_MONITORS = None


def monitors():
    global _MONITORS
    if _MONITORS is None:
        _MONITORS = sct().monitors[1:]  # skip the "all monitors" entry
    return _MONITORS


def monitor(idx):
    mons = monitors()
    return mons[max(0, min(idx, len(mons) - 1))]


def to_screen(mon, nx, ny):
    x = mon["left"] + int(max(0.0, min(1.0, nx)) * (mon["width"] - 1))
    y = mon["top"] + int(max(0.0, min(1.0, ny)) * (mon["height"] - 1))
    return x, y


CURSOR = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)]


def capture(mon_idx, max_w):
    mon = monitor(mon_idx)
    shot = sct().grab(mon)
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    pt = wt.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    cx, cy = pt.x - mon["left"], pt.y - mon["top"]
    if 0 <= cx < mon["width"] and 0 <= cy < mon["height"]:
        k = max(1.0, mon["width"] / 1600)
        poly = [(cx + x * k, cy + y * k) for x, y in CURSOR]
        d = ImageDraw.Draw(img)
        d.polygon(poly, fill=(255, 255, 255), outline=(0, 0, 0), width=max(1, int(k)))
    if max_w and img.width > max_w:
        img = img.resize((max_w, int(img.height * max_w / img.width)), Image.BILINEAR)
    return img


def jpeg(img, quality):
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def grab(mon_idx, max_w, quality):
    data = jpeg(capture(mon_idx, max_w), quality)
    return data, hashlib.md5(data).hexdigest()[:12]


def changed_rects(prev, cur, cell=240):
    """Bounding boxes of what changed, one per grid cell, padded and aligned to 16px."""
    diff = ImageChops.difference(prev, cur)
    W, H = cur.size
    rects = []
    for y0 in range(0, H, cell):
        for x0 in range(0, W, cell):
            x1, y1 = min(W, x0 + cell), min(H, y0 + cell)
            bb = diff.crop((x0, y0, x1, y1)).getbbox()
            if not bb:
                continue
            l = max(0, (x0 + bb[0] - 2) // 16 * 16)
            t = max(0, (y0 + bb[1] - 2) // 16 * 16)
            r = min(W, -(-(x0 + bb[2] + 2) // 16) * 16)
            b = min(H, -(-(y0 + bb[3] + 2) // 16) * 16)
            rects.append((l, t, r, b))
    return rects


class Streamer:
    """Captures the screen continuously in one thread and hands out only the
    parts that changed since the client's last update."""

    FPS = 25
    HISTORY = 40

    def __init__(self):
        self.cond = threading.Condition()
        self.seq = 0
        self.updates = []          # [(seq, [(x, y, w, h, jpeg)] or None for full)]
        self.img = None
        self.settings = None       # (monitor, width, quality)
        self.last_req = 0.0
        self.thread = None
        self.key = (-1, b"")

    def _touch(self, settings):
        self.last_req = time.time()
        if settings != self.settings:
            self.settings = settings
            self.img = None
            self.updates = []
        if not self.thread or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def _run(self):
        period = 1.0 / self.FPS
        while time.time() - self.last_req < 15:
            t0 = time.time()
            settings = self.settings
            mon_idx, width, quality = settings
            try:
                img = capture(mon_idx, width)
            except Exception:
                time.sleep(0.5)
                continue
            prev = self.img
            patch = None
            if prev is not None and prev.size == img.size:
                rects = changed_rects(prev, img)
                if not rects:
                    time.sleep(max(0.0, period - (time.time() - t0)))
                    continue
                area = sum((r - l) * (b - t) for l, t, r, b in rects)
                if area < img.width * img.height * 0.6:
                    patch = [(l, t, r - l, b - t, jpeg(img.crop((l, t, r, b)), quality))
                             for l, t, r, b in rects]
            with self.cond:
                if settings != self.settings:
                    continue
                self.img = img
                self.seq += 1
                self.updates.append((self.seq, patch))
                del self.updates[:-self.HISTORY]
                self.cond.notify_all()
            time.sleep(max(0.0, period - (time.time() - t0)))

    def get(self, after, settings, want_key, timeout=2.0):
        deadline = time.time() + timeout
        with self.cond:
            self._touch(settings)
            while self.img is None or self.seq <= after:
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.cond.wait(left)
                self.last_req = time.time()
            img, seq = self.img, self.seq
            pending = [u for u in self.updates if u[0] > after]
            first = self.updates[0][0] if self.updates else seq + 1
            full = (want_key or after < first - 1 or any(p is None for _, p in pending)
                    or sum(len(r[4]) for _, p in pending for r in p) > 400_000)
            if full:
                if self.key[0] != seq:
                    self.key = (seq, jpeg(img, settings[2]))
                rects = [(0, 0, img.width, img.height, self.key[1])]
            else:
                rects = [r for _, p in pending for r in p]
        meta = {"seq": seq, "w": img.width, "h": img.height, "key": full,
                "rects": [[x, y, w, h, len(d)] for x, y, w, h, d in rects]}
        head = json.dumps(meta).encode()
        return struct.pack(">I", len(head)) + head + b"".join(r[4] for r in rects)


STREAM = Streamer()


# ---------------------------------------------------------------- easy commands
HOME = os.path.expanduser("~")
DESKTOP = os.path.join(HOME, "Desktop")
LOCAL = os.environ.get("LOCALAPPDATA", "")
NEW_CONSOLE = subprocess.CREATE_NEW_CONSOLE

# name -> (aliases, how to open)
BUILTIN_APPS = [
    ("Opera", ["opera", "опера", "браузер", "browser"],
     os.path.join(LOCAL, "Programs", "Opera", "opera.exe")),
    ("Streak", ["streak", "стрик"],
     os.path.join(HOME, r"Downloads\streak-main\streak-main\build\windows\x64\runner\Release\Streak.exe")),
    ("VS Code", ["vscode", "vsc", "code", "вскод", "visual studio code"],
     os.path.join(LOCAL, "Programs", "Microsoft VS Code", "Code.exe")),
    ("CMD (консоль)", ["cmd", "консоль", "командная строка"], "cmd"),
    ("PowerShell", ["powershell", "пш"], "powershell"),
    ("Рабочий стол", ["desktop", "рабочий стол", "стол"], ("folder", DESKTOP)),
    ("Проводник", ["проводник", "explorer", "папки"], ("folder", HOME)),
    ("Загрузки", ["загрузки", "downloads"], ("folder", os.path.join(HOME, "Downloads"))),
    ("Документы", ["документы", "documents"], ("folder", os.path.join(HOME, "Documents"))),
    ("Unity Hub", ["unity hub", "юнити хаб", "хаб"], os.path.join(DESKTOP, "Unity Hub.lnk")),
    ("Claude Code", ["claude", "клод"], ("claude", None)),
    ("Блокнот", ["блокнот", "notepad"], "notepad.exe"),
    ("Калькулятор", ["калькулятор", "calc"], "calc.exe"),
    ("Диспетчер задач", ["диспетчер задач", "диспетчер", "taskmgr"], "taskmgr.exe"),
    ("Параметры", ["параметры", "настройки", "settings"], "ms-settings:"),
]


def _shortcuts():
    """Start Menu and Desktop shortcuts: lowercase name -> path."""
    roots = [
        os.path.join(os.environ.get("APPDATA", ""), r"Microsoft\Windows\Start Menu\Programs"),
        os.path.join(os.environ.get("PROGRAMDATA", ""), r"Microsoft\Windows\Start Menu\Programs"),
        DESKTOP, os.path.join(os.environ.get("PUBLIC", ""), "Desktop"),
    ]
    found = {}
    for root in roots:
        for dirpath, _, files in os.walk(root):
            for f in files:
                name, ext = os.path.splitext(f)
                if ext.lower() in (".lnk", ".url") and not re_skip(name):
                    found.setdefault(name.lower(), os.path.join(dirpath, f))
    return found


def all_apps():
    """Every program the phone can open: the main ones first, then all Start Menu / Desktop shortcuts."""
    out, seen = [], set()
    for title, aliases, target in BUILTIN_APPS:
        if isinstance(target, str) and os.path.isabs(target) and not os.path.exists(target):
            continue  # not installed on this PC
        out.append({"name": title, "cmd": aliases[0], "main": True})
        seen.add(title.lower())
        seen.update(a.lower() for a in aliases)
    names = sorted({os.path.splitext(os.path.basename(p))[0] for p in _shortcuts().values()}, key=str.lower)
    for n in names:
        if n.lower() not in seen:
            seen.add(n.lower())
            out.append({"name": n, "cmd": "open " + n, "main": False})
    return out


def re_skip(name):
    n = name.lower()
    return any(w in n for w in ("uninstall", "удал", "readme", "help", "documentation", "release notes",
                                 "manual", "report a problem", "website"))


def find_app(query):
    q = query.strip().lower()
    if not q:
        return None
    for title, aliases, target in BUILTIN_APPS:
        if q == title.lower() or q in aliases:
            return title, target
    sc = _shortcuts()
    if q in sc:
        return query, sc[q]
    for title, aliases, target in BUILTIN_APPS:
        if any(a.startswith(q) or q in a for a in aliases):
            return title, target
    for name, path in sc.items():
        if name.startswith(q):
            return os.path.splitext(os.path.basename(path))[0], path
    for name, path in sc.items():
        if q in name:
            return os.path.splitext(os.path.basename(path))[0], path
    return None


def unity_editor(project=None):
    base = r"C:\Program Files\Unity\Hub\Editor"
    if not os.path.isdir(base):
        return None
    versions = sorted(os.listdir(base), reverse=True)
    if project:
        try:
            with open(os.path.join(project, "ProjectSettings", "ProjectVersion.txt"), encoding="utf-8") as f:
                for line in f:
                    if line.startswith("m_EditorVersion:"):
                        v = line.split(":", 1)[1].strip()
                        if v in versions:
                            versions.insert(0, v)
        except OSError:
            pass
    for v in versions:
        exe = os.path.join(base, v, "Editor", "Unity.exe")
        if os.path.isfile(exe):
            return exe
    return None


def is_unity(path):
    return os.path.isdir(os.path.join(path, "Assets")) and os.path.isdir(os.path.join(path, "ProjectSettings"))


PROJECT_MARKERS = (".git", "pubspec.yaml", "package.json", "CLAUDE.md", "ProjectSettings", "pyproject.toml",
                   "requirements.txt", "index.html", "project.godot")


def places():
    """Folders and projects the user is likely to open, numbered."""
    items = [("Рабочий стол", DESKTOP), ("Загрузки", os.path.join(HOME, "Downloads")),
             ("Документы", os.path.join(HOME, "Documents"))]
    extra = os.path.join(HERE, "places.json")
    if os.path.exists(extra):
        try:
            with open(extra, encoding="utf-8") as f:
                items += [(p.get("name") or os.path.basename(p["path"]), p["path"]) for p in json.load(f)]
        except Exception:
            pass
    containers = [os.path.join(DESKTOP, "PROJECTS-2026"), os.path.join(DESKTOP, "ИГРЫ")]
    for c in containers:
        if os.path.isdir(c):
            items.append((os.path.basename(c), c))
            for d in sorted(os.listdir(c)):
                p = os.path.join(c, d)
                if os.path.isdir(p) and not d.startswith("."):
                    items.append((d, p))
    for d in sorted(os.listdir(HOME)):
        p = os.path.join(HOME, d)
        if d.startswith(".") or not os.path.isdir(p) or p in [i[1] for i in items]:
            continue
        try:
            if any(os.path.exists(os.path.join(p, m)) for m in PROJECT_MARKERS):
                items.append((d, p))
        except OSError:
            pass
    streak = os.path.join(HOME, r"Downloads\streak-main\streak-main")
    if os.path.isdir(streak):
        items.append(("Streak (исходники)", streak))
    seen, out = set(), []
    for name, p in items:
        if os.path.isdir(p) and p.lower() not in seen:
            seen.add(p.lower())
            out.append({"n": len(out) + 1, "name": name, "path": p, "unity": is_unity(p)})
    return out


def resolve_place(arg, cwd):
    a = arg.strip().strip('"')
    if not a:
        return cwd
    pl = places()
    if a.isdigit():
        i = int(a)
        if 1 <= i <= len(pl):
            return pl[i - 1]["path"]
    p = a if os.path.isabs(a) else os.path.join(cwd, a)
    if os.path.exists(p):
        return os.path.normpath(p)
    al = a.lower()
    for item in pl:
        if item["name"].lower() == al:
            return item["path"]
    for item in pl:
        if al in item["name"].lower():
            return item["path"]
    return None


def launch(target, arg=None):
    if isinstance(target, tuple):
        kind, val = target
        if kind == "folder":
            os.startfile(val)
        elif kind == "claude":
            open_claude(arg or HOME)
        return
    if target in ("cmd", "powershell"):
        subprocess.Popen([target], cwd=arg or HOME, creationflags=NEW_CONSOLE)
        return
    if target.lower().endswith("code.exe") and arg:
        subprocess.Popen([target, arg])
        return
    os.startfile(target)


def claude_exe():
    import shutil
    return shutil.which("claude") or os.path.join(HOME, r".local\bin\claude.exe")


def open_claude(path):
    subprocess.Popen(["cmd", "/k", f"title Claude Code - {os.path.basename(path)} && \"{claude_exe()}\""],
                     cwd=path, creationflags=NEW_CONSOLE)


CLAUDE_CHATS = set()   # folders where a phone chat with Claude was started


def ask_claude(text, cwd):
    args = [claude_exe(), "-p", text, "--permission-mode", "acceptEdits"]
    cont = cwd.lower() in CLAUDE_CHATS
    try:
        p = subprocess.run(args + (["--continue"] if cont else []), cwd=cwd, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=600, creationflags=subprocess.CREATE_NO_WINDOW)
        out = (p.stdout or b"").decode("utf-8", "replace").strip()
        err = (p.stderr or b"").decode("utf-8", "replace").strip()
        if cont and p.returncode != 0 and "conversation" in (out + err).lower():
            p = subprocess.run(args, cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, timeout=600,
                               creationflags=subprocess.CREATE_NO_WINDOW)
            out = (p.stdout or b"").decode("utf-8", "replace").strip()
            err = (p.stderr or b"").decode("utf-8", "replace").strip()
    except subprocess.TimeoutExpired:
        return "[Claude думал дольше 10 минут — ответ не дождались]"
    CLAUDE_CHATS.add(cwd.lower())
    return out or err or "[пустой ответ]"


# ---------------------------------------------------------------- real consoles (Claude Code on the phone)
PTYS = pty_win.Sessions()
UPLOAD_DIR = os.path.join(HOME, "Downloads", "RemoteDesk")
UPLOAD_MAX = 500 * 1024 * 1024


def pty_start(data):
    cwd = str(data.get("cwd") or HOME)
    if not os.path.isdir(cwd):
        cwd = HOME
    cols = max(20, min(400, int(data.get("cols", 80))))
    rows = max(5, min(200, int(data.get("rows", 24))))
    kind = data.get("kind", "claude")
    if kind == "claude":
        exe = claude_exe()
        if not os.path.exists(exe):
            raise RuntimeError("Claude Code не найден на компьютере (claude.exe)")
        cmdline, title = f'"{exe}"', "Claude Code"
    else:
        cmdline, title = "powershell.exe -NoLogo", "Windows PowerShell"
    p = PTYS.start(cmdline, cwd, cols, rows, title,
                   env={"COLORTERM": "truecolor", "TERM": "xterm-256color"})
    log(f"  [>] консоль «{title}» в {cwd}")
    return {"id": p.id, "title": title, "cwd": cwd}


def save_upload(name, rfile, length):
    """A file sent from the phone goes to Downloads/RemoteDesk; returns the full path."""
    if length <= 0 or length > UPLOAD_MAX:
        raise RuntimeError("Файл пустой или больше 500 МБ")
    name = os.path.basename(name.replace("\\", "/")).strip() or "file"
    name = "".join("_" if c in r'<>:"/\|?*' or ord(c) < 32 or c == " " else c for c in name)[:120]
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    stem, ext = os.path.splitext(name)
    path, n = os.path.join(UPLOAD_DIR, name), 1
    while os.path.exists(path):
        n += 1
        path = os.path.join(UPLOAD_DIR, f"{stem}_{n}{ext}")
    left = length
    with open(path + ".part", "wb") as f:
        while left > 0:
            chunk = rfile.read(min(left, 1 << 20))
            if not chunk:
                break
            f.write(chunk)
            left -= len(chunk)
    if left:
        os.remove(path + ".part")
        raise RuntimeError("Файл пришёл не полностью")
    os.replace(path + ".part", path)
    log(f"  [↓] файл с телефона: {path}")
    TRANSFERS.add("sent", os.path.basename(path), length, path)
    return path


# ---------------------------------------------------------------- file exchange: history, PC folders, download
class Transfers:
    """What the phone sent to the PC and what it took from the PC (newest first, kept in transfers.json)."""
    FILE = os.path.join(HERE, "transfers.json")
    LIMIT = 300

    def __init__(self):
        self.lock = threading.Lock()
        try:
            with open(self.FILE, encoding="utf-8") as f:
                self.items = json.load(f)
        except Exception:
            self.items = []

    def add(self, kind, name, size, path):
        with self.lock:
            now = time.time()
            # Safari asks for the same file a few times (range requests) — that is one download
            if kind == "recv" and any(i["kind"] == kind and i["path"] == path and now - i["time"] < 120
                                      for i in self.items[:20]):
                return
            self.items.insert(0, {"kind": kind, "name": name, "size": size, "path": path, "time": now})
            del self.items[self.LIMIT:]
            try:
                with open(self.FILE, "w", encoding="utf-8") as f:
                    json.dump(self.items, f, ensure_ascii=False)
            except Exception:
                pass

    def list(self):
        with self.lock:
            return [dict(i, exists=os.path.isfile(i["path"])) for i in self.items]

    def clear(self, kind):
        with self.lock:
            self.items = [i for i in self.items if kind and i["kind"] != kind]
            try:
                with open(self.FILE, "w", encoding="utf-8") as f:
                    json.dump(self.items, f, ensure_ascii=False)
            except Exception:
                pass


TRANSFERS = Transfers()


def fs_roots():
    roots = [("Рабочий стол", DESKTOP), ("Загрузки", os.path.join(HOME, "Downloads")),
             ("Документы", os.path.join(HOME, "Documents")), ("Изображения", os.path.join(HOME, "Pictures")),
             ("Видео", os.path.join(HOME, "Videos")), ("Музыка", os.path.join(HOME, "Music")),
             ("С телефона", UPLOAD_DIR), ("Папка пользователя", HOME)]
    out = [{"name": n, "path": p, "dir": True} for n, p in roots if os.path.isdir(p)]
    for d in "CDEFGH":
        if os.path.isdir(d + ":\\"):
            out.append({"name": f"Диск {d}:", "path": d + ":\\", "dir": True})
    return out


def fs_list(path):
    """Folders first, then files; hidden and system entries are skipped."""
    if not path:
        return {"path": "", "parent": None, "items": fs_roots()}
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        raise RuntimeError("Папка не найдена")
    items = []
    with os.scandir(path) as it:
        for e in it:
            try:
                st = e.stat()
                attrs = getattr(st, "st_file_attributes", 0)
                if attrs & 0x6 or e.name.startswith(("$", "~$")) or e.name.lower() in ("desktop.ini", "thumbs.db"):
                    continue
                isdir = e.is_dir()
                items.append({"name": e.name, "path": e.path, "dir": isdir,
                              "size": 0 if isdir else st.st_size, "time": st.st_mtime})
            except OSError:
                continue
    items.sort(key=lambda i: (not i["dir"], i["name"].lower()))
    parent = os.path.dirname(path.rstrip("\\/"))
    if not parent or parent == path or len(path) <= 3:
        parent = ""
    return {"path": path, "parent": parent, "items": items}


# ---------------------------------------------------------------- open windows / closing
kernel32 = ctypes.windll.kernel32
dwmapi = ctypes.windll.dwmapi
kernel32.OpenProcess.restype = wt.HANDLE
kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
kernel32.CloseHandle.argtypes = [wt.HANDLE]
kernel32.QueryFullProcessImageNameW.argtypes = [wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
kernel32.GetConsoleWindow.restype = wt.HWND
user32.GetWindow.restype = wt.HWND
user32.GetWindow.argtypes = [wt.HWND, wt.UINT]
user32.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.IsWindow.argtypes = [wt.HWND]
WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

# which program files belong to each friendly name (for «закрыть …»)
CLOSE_RULES = {
    "Opera": {"exe": ["opera.exe"]},
    "Streak": {"exe": ["streak.exe"]},
    "VS Code": {"exe": ["code.exe"]},
    "CMD (консоль)": {"exe": ["cmd.exe", "conhost.exe"]},
    "PowerShell": {"exe": ["powershell.exe", "pwsh.exe"], "title": ["powershell"]},
    "Проводник": {"exe": ["explorer.exe"]},
    "Рабочий стол": {"exe": ["explorer.exe"], "title": ["рабочий стол", "desktop"]},
    "Загрузки": {"exe": ["explorer.exe"], "title": ["загрузки", "downloads"]},
    "Документы": {"exe": ["explorer.exe"], "title": ["документы", "documents"]},
    "Unity Hub": {"exe": ["unity hub.exe"]},
    "Claude Code": {"title": ["claude"]},
    "Блокнот": {"exe": ["notepad.exe"]},
    "Калькулятор": {"title": ["калькулятор", "calculator"]},
    "Диспетчер задач": {"exe": ["taskmgr.exe"]},
    "Параметры": {"title": ["параметры", "settings"]},
}
NEVER_FORCE = {"explorer.exe", "python.exe", "pythonw.exe", "dwm.exe", "csrss.exe", "winlogon.exe",
               "tailscale-ipn.exe", "tailscaled.exe"}
LAST_WINDOWS = []


def _exe_of(pid):
    h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wt.DWORD(1024)
        if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value)
        return ""
    finally:
        kernel32.CloseHandle(h)


def open_windows():
    """Visible top-level windows the user can see on the taskbar (except the server's own window)."""
    own = kernel32.GetConsoleWindow()
    found = []

    def cb(hwnd, _):
        if not user32.IsWindowVisible(hwnd) or user32.GetWindow(hwnd, 4):  # GW_OWNER
            return True
        if user32.GetWindowLongW(hwnd, -20) & 0x80:  # WS_EX_TOOLWINDOW
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if not n:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        title = buf.value
        cloaked = wt.DWORD(0)
        dwmapi.DwmGetWindowAttribute(wt.HWND(hwnd), 14, ctypes.byref(cloaked), 4)  # DWMWA_CLOAKED
        if cloaked.value or title == "Program Manager" or (own and hwnd == own) or "RemoteDesk" in title:
            return True
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        found.append({"hwnd": hwnd, "pid": pid.value, "exe": _exe_of(pid.value), "title": title})
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return found


def _app_name(w):
    exe = w["exe"].lower()
    if exe == "windowsterminal.exe":
        return "Windows Terminal (все его вкладки)"
    if exe == "unity.exe":
        return "Unity"
    for name, rule in CLOSE_RULES.items():
        if exe in rule.get("exe", []) and not rule.get("title"):
            return name
    return os.path.splitext(w["exe"])[0] or "?"


def match_windows(query, wins):
    q = query.strip().lower()
    if not q:
        return []
    if q.isdigit():
        i = int(q)
        if 1 <= i <= len(LAST_WINDOWS):
            hw = LAST_WINDOWS[i - 1]["hwnd"]
            return [w for w in wins if w["hwnd"] == hw]
        return []
    for title, aliases, _ in BUILTIN_APPS:
        if q == title.lower() or q in aliases:
            rule = CLOSE_RULES.get(title, {})
            exes, words = rule.get("exe"), rule.get("title")
            return [w for w in wins
                    if (not exes or w["exe"].lower() in exes)
                    and (not words or any(k in w["title"].lower() for k in words))]
    if q in ("unity", "юнити"):
        return [w for w in wins if w["exe"].lower() == "unity.exe"]
    return [w for w in wins if q in os.path.splitext(w["exe"])[0].lower() or q in w["title"].lower()]


def list_windows():
    global LAST_WINDOWS
    LAST_WINDOWS = open_windows()
    if not LAST_WINDOWS:
        return "Открытых окон нет."
    lines = [f"  {i:>2}. {_app_name(w)} — {w['title'][:70]}" for i, w in enumerate(LAST_WINDOWS, 1)]
    return ("ОТКРЫТЫЕ ОКНА:\n" + "\n".join(lines)
            + "\n\nЗакрыть:  close 2   ·   close opera   ·   если зависло: close force 2")


def close_windows(query, force=False):
    wins = open_windows()
    targets = match_windows(query, wins)
    if not targets:
        return (f"Не нашёл открытое окно «{query}».\n"
                "Напишите «windows», чтобы увидеть список, и закройте по номеру:  close 3")
    names = sorted({_app_name(w) for w in targets})
    if force:
        exes = {w["exe"].lower() for w in targets}
        bad = exes & NEVER_FORCE
        if bad:
            return ("Проводник и служебные программы принудительно не закрываю — пропадёт панель задач "
                    "или связь с ноутбуком.\nЗакройте обычно:  close " + query)
        out = []
        for pid in sorted({w["pid"] for w in targets}):
            p = subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True,
                               creationflags=subprocess.CREATE_NO_WINDOW)
            out.append(pid if p.returncode == 0 else None)
        ok = [p for p in out if p]
        return (f"Принудительно закрыл: {', '.join(names)}  ({len(ok)} из {len(out)} процессов)"
                + ("" if len(ok) == len(out) else "\nЧасть не закрылась — возможно, нужны права администратора."))
    for w in targets:
        user32.PostMessageW(w["hwnd"], 0x0010, 0, 0)  # WM_CLOSE — like pressing ✕
    time.sleep(1.5)
    still = [w for w in targets if user32.IsWindow(w["hwnd"]) and user32.IsWindowVisible(w["hwnd"])]
    msg = f"Закрываю: {', '.join(names)}  (окон: {len(targets)})"
    if still:
        msg += (f"\n{len(still)} окно(а) ещё открыто — программа, наверное, спрашивает «Сохранить?».\n"
                "Ответьте во вкладке «Экран» или закройте без сохранения:  close force " + query)
    else:
        msg += "\nГотово, закрыто."
    return msg


HELP = """КОМАНДЫ (на английском; русские тоже работают)

  apps                 — список программ, которые можно открыть
  open <программа>     — открыть программу:  open opera,  open streak
  <программа>          — то же самое коротко:  opera,  vscode,  cmd,  unity hub

  windows              — какие окна сейчас открыты (с номерами)
  close <программа>    — закрыть, как крестиком:  close opera,  close 3
  close force <программа> — если программа зависла (без сохранения!)

  projects             — список папок и проектов с номерами
  go <номер>           — зайти в папку проекта (тут будут выполняться команды)
  files                — что лежит в текущей папке
  folder [номер]       — открыть папку в Проводнике
  open <файл>          — открыть файл из текущей папки

  vscode <номер>       — открыть проект в VS Code
  claude <номер>       — открыть Claude Code в окне на ноутбуке (смотрите во вкладке «Экран»)
  ask <вопрос>         — спросить Claude прямо здесь, в текущей папке
                         (он может читать и менять файлы проекта)
  new chat             — следующий «ask» начнёт разговор с Claude заново

  unity                — открыть Unity Hub
  unity <номер>        — открыть проект в Unity

  Вместо номера можно писать название:  claude RemoteDesk,  unity My project
  Любые другие команды выполняются в PowerShell:  dir,  cd ..,  ipconfig"""


def friendly(cmd, cwd):
    """Easy Russian commands. Returns {'output', 'cwd'} or None to fall back to PowerShell."""
    text = cmd.strip()
    low = text.lower()
    word, _, rest = text.partition(" ")
    w = word.lower()
    rest = rest.strip()

    def res(out, new_cwd=cwd):
        return {"output": out, "cwd": new_cwd}

    if low in ("помощь", "help", "команды", "?"):
        return res(HELP)
    if low in ("программы", "приложения", "apps", "programs"):
        names = [f"  {t:<18} — {', '.join(a[:3])}" for t, a, _ in BUILTIN_APPS]
        sc = sorted({os.path.splitext(os.path.basename(p))[0] for p in _shortcuts().values()})
        return res("ГЛАВНЫЕ (open <имя>):\n" + "\n".join(names)
                   + "\n\nВСЕ ЯРЛЫКИ ИЗ МЕНЮ ПУСК (open <имя>):\n  " + ", ".join(sc))
    if low in ("проекты", "папки проектов", "места", "projects"):
        lines = [f"  {p['n']:>2}. {p['name']}{'  [Unity]' if p['unity'] else ''}\n      {p['path']}"
                 for p in places()]
        return res("ПАПКИ И ПРОЕКТЫ:\n" + "\n".join(lines)
                   + "\n\nНапример:  go 4   ·   claude 4   ·   vscode 4   ·   folder 4")
    if low in ("файлы", "ls", "список", "files"):
        try:
            entries = sorted((n for n in os.listdir(cwd) if not n.startswith((".", "$"))
                              and n not in ("Application Data", "Local Settings", "NTUSER.DAT", "ntuser.ini",
                                            "Cookies", "NetHood", "PrintHood", "Recent", "SendTo",
                                            "Главное меню", "Шаблоны", "Мои документы")
                              and not n.lower().startswith("ntuser")), key=lambda n: (not os.path.isdir(os.path.join(cwd, n)), n.lower()))
        except OSError as e:
            return res(str(e))
        lines = [("📁 " if os.path.isdir(os.path.join(cwd, n)) else "   ") + n for n in entries[:200]]
        return res(f"{cwd}\n" + ("\n".join(lines) or "(пусто)"))
    if low in ("открытые", "окна", "запущено", "что открыто", "открытые окна", "windows", "opened", "open windows"):
        return res(list_windows())
    if w in ("закрыть", "закрой", "close", "убить", "kill"):
        force = w in ("убить", "kill")
        q = rest
        for word in ("принудительно", "насильно", "force"):
            if q.lower().startswith(word):
                force, q = True, q[len(word):].strip()
        if not q:
            return res("Что закрыть? Например:  close opera   ·   «windows» — список окон с номерами")
        return res(close_windows(q, force))
    if low in ("новый чат", "new chat"):
        CLAUDE_CHATS.discard(cwd.lower())
        return res("Следующий вопрос «ask …» начнёт новый разговор с Claude.")
    if w in ("спроси", "ask", "claude:"):
        if not rest:
            return res("Напишите вопрос после слова «ask», например:  ask что делает этот проект?")
        return res(ask_claude(rest, cwd))
    if w in ("перейти", "зайти", "go"):
        p = resolve_place(rest, cwd)
        if not p or not os.path.isdir(p):
            return res(f"Не нашёл папку «{rest}». Напишите «projects», чтобы увидеть список.")
        return res(f"Теперь вы в папке: {p}", p)
    if w in ("папка", "folder"):
        p = resolve_place(rest, cwd)
        if not p:
            return res(f"Не нашёл папку «{rest}». Напишите «projects».")
        os.startfile(p)
        return res(f"Открыл в Проводнике: {p}")
    if w in ("vscode", "vsc", "code") and rest:
        p = resolve_place(rest, cwd)
        if not p:
            return res(f"Не нашёл «{rest}». Напишите «projects».")
        launch(BUILTIN_APPS[2][2], p)
        return res(f"Открываю в VS Code: {p}")
    if w in ("claude", "клод"):
        p = resolve_place(rest, cwd) if rest else cwd
        if not p:
            return res(f"Не нашёл «{rest}». Напишите «projects».")
        open_claude(p)
        return res(f"Открыл Claude Code в папке {p}\nОкно появилось на ноутбуке — работайте с ним во вкладке «Экран».\n"
                   "Или задавайте вопросы прямо отсюда:  ask <вопрос>")
    if w in ("unity", "юнити") and low not in ("unity hub", "юнити хаб"):
        if not rest:
            p = cwd if is_unity(cwd) else None
            if not p:
                launch(os.path.join(DESKTOP, "Unity Hub.lnk")
                       if os.path.exists(os.path.join(DESKTOP, "Unity Hub.lnk")) else r"C:\Program Files\Unity Hub\Unity Hub.exe")
                return res("Открываю Unity Hub.  Чтобы открыть проект сразу:  unity <номер>")
        else:
            p = resolve_place(rest, cwd)
        if not p or not is_unity(p):
            return res(f"«{rest}» — не проект Unity (нет папок Assets и ProjectSettings). Проекты Unity "
                       "в списке «projects» помечены [Unity].")
        exe = unity_editor(p)
        if not exe:
            return res("Не нашёл установленный редактор Unity.")
        subprocess.Popen([exe, "-projectPath", p])
        return res(f"Открываю в Unity: {p}\n(загрузка может занять минуту)")
    if w in ("открыть", "открой", "запусти", "запустить", "open", "start"):
        if not rest:
            return res("Что открыть? Например:  open opera   ·   «apps» — весь список")
        f = os.path.join(cwd, rest.strip('"'))
        if os.path.exists(f):
            os.startfile(f)
            return res(f"Открываю: {f}")
        app = find_app(rest)
        if not app:
            return res(f"Не нашёл программу «{rest}». Напишите «apps», чтобы увидеть список.")
        launch(app[1], cwd)
        return res(f"Открываю {app[0]}")
    if " " not in low or any(low == a for _, aliases, _ in BUILTIN_APPS for a in aliases):
        for title, aliases, target in BUILTIN_APPS:
            if low == title.lower() or low in aliases:
                launch(target, cwd)
                return res(f"Открываю {title}")
    return None


# ---------------------------------------------------------------- terminal
MARK = "__RD_CWD__"


def run_command(cmd, cwd, timeout=120):
    if not cwd or not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")
    try:
        easy = friendly(cmd, cwd)
    except Exception as e:
        easy = {"output": f"Ошибка: {e}", "cwd": cwd}
    if easy is not None:
        return easy
    script = (
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;"
        "$OutputEncoding=[Text.Encoding]::UTF8;"
        f"Set-Location -LiteralPath '{cwd.replace(chr(39), chr(39) * 2)}';"
        f"try {{ {cmd} | Out-String -Width 160 }} catch {{ $_ | Out-String }};"
        f"'{MARK}' + (Get-Location).Path"
    )
    try:
        p = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True, timeout=timeout, cwd=cwd,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        out = p.stdout.decode("utf-8", "replace")
        err = p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return {"output": f"[превышено время ожидания {timeout} с]", "cwd": cwd}
    new_cwd = cwd
    if MARK in out:
        out, _, tail = out.rpartition(MARK)
        new_cwd = tail.strip() or cwd
    text = out.rstrip()
    if err.strip():
        text += ("\n" if text else "") + err.rstrip()
    return {"output": text, "cwd": new_cwd}


# ---------------------------------------------------------------- static files
COMPRESSIBLE = {".js", ".mjs", ".wasm", ".html", ".json", ".css", ".otf", ".ttf", ".svg"}
_static_cache = {}
_static_lock = threading.Lock()


def static_body(path, st, gz):
    """File contents, gzip-compressed once and kept in memory (makes the first load ~3× smaller)."""
    import gzip
    key = (path, st.st_mtime, st.st_size, gz)
    with _static_lock:
        if key in _static_cache:
            return _static_cache[key]
    with open(path, "rb") as f:
        data = f.read()
    if gz:
        data = gzip.compress(data, compresslevel=6)
    with _static_lock:
        _static_cache[key] = data
    return data


# ---------------------------------------------------------------- connected devices
class Devices:
    """Who is connected (for the PC window): address, model from the app's X-Device header
    («phone; iPhone 15 Pro»), traffic of the HTTP requests and when it connected."""

    IDLE = 60  # seconds without requests (and without live video) = gone

    def __init__(self):
        self.lock = threading.Lock()
        self.by_ip = {}
        self.kicked = set()  # turned off in the PC window: refused until the phone logs in again

    def kick(self, ip):
        with self.lock:
            self.kicked.add(ip)
            self.by_ip.pop(ip, None)
        print(f"  [-] {time.strftime('%H:%M')} устройство {ip} отключено")
        if RTC and RTC.peer_ip == ip:
            RTC.drop()

    def is_kicked(self, ip, login):
        with self.lock:
            if ip in self.kicked and login:
                self.kicked.discard(ip)  # the user connected again on the phone on purpose
            return ip in self.kicked

    @staticmethod
    def _parse(tag, ua):
        kind, _, model = (tag or "").partition(";")
        kind, model = kind.strip(), model.split(";")[0].strip()  # «phone; iPhone 15; 393x852@3»
        if kind not in ("phone", "tablet", "laptop"):
            if "iPhone" in ua:
                kind, model = "phone", "iPhone"
            elif "iPad" in ua:
                kind, model = "tablet", "iPad"
            elif "Android" in ua or "Dart/" in ua:
                kind, model = "phone", "Android"
            else:
                kind, model = "laptop", "Компьютер"
        return kind, model[:40] or "Устройство"

    def seen(self, ip, tag, ua):
        now = time.time()
        kind, model = self._parse(tag, ua or "")
        with self.lock:
            d = self.by_ip.get(ip)
            if not d or now - d["last"] > self.IDLE:
                d = self.by_ip[ip] = {"ip": ip, "since": now, "sent": 0, "recv": 0}
                print(f"  [i] устройство {ip}: X-Device «{tag}» · {ua}")
            d.update(last=now, kind=kind, model=model)

    def traffic(self, ip, sent, recv):
        with self.lock:
            d = self.by_ip.get(ip)
            if d:
                d["sent"] += sent
                d["recv"] += recv

    def snapshot(self, live_ips=()):
        """Connected devices, newest first. live_ips = addresses with live WebRTC video."""
        now = time.time()
        with self.lock:
            for ip in live_ips:
                if ip in self.by_ip:
                    self.by_ip[ip]["last"] = now
            out = [dict(d) for d in self.by_ip.values() if now - d["last"] <= self.IDLE]
        return sorted(out, key=lambda d: -d["since"])


DEVICES = Devices()


class _Counted:
    """Wraps the request's socket file to count bytes (traffic per device)."""

    def __init__(self, f):
        self.f, self.n = f, 0

    def read(self, *a):
        b = self.f.read(*a)
        self.n += len(b)
        return b

    def readline(self, *a):
        b = self.f.readline(*a)
        self.n += len(b)
        return b

    def write(self, b):
        self.n += len(b)
        return self.f.write(b)

    def __getattr__(self, name):
        return getattr(self.f, name)


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    server_version = "RemoteDesk/1.0"

    def setup(self):
        super().setup()
        self.rfile, self.wfile = _Counted(self.rfile), _Counted(self.wfile)

    def handle_one_request(self):
        try:
            super().handle_one_request()
        finally:
            if self.wfile.n or self.rfile.n:
                try:
                    DEVICES.traffic(self._ip(), self.wfile.n, self.rfile.n)
                except Exception:
                    pass
                self.wfile.n = self.rfile.n = 0

    def log_message(self, fmt, *args):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Key, X-Device, X-Login")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ip(self):
        peer = self.client_address[0]
        # requests from the internet come through Caddy, which says who really sent them
        if peer in ("127.0.0.1", "::1") and self.headers.get("X-Forwarded-For"):
            return self.headers["X-Forwarded-For"].split(",")[-1].strip()
        return peer

    def _authed(self, q):
        ip = self._ip()
        left = GUARD.blocked(ip)
        if left:
            self._json({"error": f"Слишком много неверных ключей. Доступ с этого адреса закрыт "
                                 f"ещё на {left // 60 + 1} мин."}, 429)
            return False
        def norm(k):
            return "".join(k.split()).replace("-", "").upper().encode()
        key = self.headers.get("X-Key") or q.get("key", [""])[0]
        ok = secrets.compare_digest(norm(key), norm(CFG["key"]))
        if ok and DEVICES.is_kicked(ip, self.headers.get("X-Login") == "1"):
            self._json({"error": "Компьютер отключил это устройство", "kicked": True}, 403)
            return False
        if ok:
            GUARD.ok(ip)
            DEVICES.seen(ip, self.headers.get("X-Device", ""), self.headers.get("User-Agent", ""))
        else:
            GUARD.fail(ip, urlparse(self.path).path, key)
            self._json({"error": "неверный ключ"}, 401)
        return ok

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path.startswith("/api/"):
            if not self._authed(q):
                return
            if u.path == "/api/info":
                mons = monitors()
                return self._json({
                    "name": socket.gethostname(),
                    "monitors": [{"width": m["width"], "height": m["height"]} for m in mons],
                    "home": os.path.expanduser("~"),
                })
            if u.path == "/api/pty/read":
                try:
                    p = PTYS.get(q.get("id", [""])[0])
                except KeyError as e:
                    return self._json({"error": str(e), "gone": True}, 404)
                text, end, exited = p.read(int(q.get("after", ["0"])[0]), wait=20.0)
                return self._json({"data": text, "end": end, "exited": exited})
            if u.path == "/api/lock":
                return self._json(unlock.state())
            if u.path == "/api/files/list":
                try:
                    return self._json(fs_list(q.get("path", [""])[0]))
                except Exception as e:
                    return self._json({"error": str(e)}, 400)
            if u.path == "/api/files/get":
                return self._send_file(q.get("path", [""])[0])
            if u.path == "/api/transfers":
                return self._json(TRANSFERS.list())
            if u.path == "/api/places":
                return self._json(places())
            if u.path == "/api/apps":
                return self._json(all_apps())
            if u.path == "/api/stream":
                settings = (int(q.get("m", ["0"])[0]), int(q.get("w", ["1280"])[0]),
                            max(10, min(95, int(q.get("q", ["60"])[0]))))
                body = STREAM.get(int(q.get("after", ["0"])[0]), settings,
                                  q.get("kf", ["0"])[0] == "1")
                if body is None:
                    self.send_response(204)
                    self._cors()
                    self.end_headers()
                    return
                self.send_response(200)
                self._cors()
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if u.path == "/api/frame":
                mon = int(q.get("m", ["0"])[0])
                w = int(q.get("w", ["1280"])[0])
                quality = max(10, min(95, int(q.get("q", ["60"])[0])))
                last = q.get("last", [""])[0]
                data, tag = grab(mon, w, quality)
                if tag == last:
                    self.send_response(204)
                    self._cors()
                    self.end_headers()
                    return
                self.send_response(200)
                self._cors()
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("X-Frame", tag)
                self.send_header("Access-Control-Expose-Headers", "X-Frame")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            return self._json({"error": "not found"}, 404)
        self._static(u.path)

    def _send_file(self, path):
        """A PC file for the phone: Safari saves it to «Файлы» (Content-Disposition: attachment).
        Range requests are answered, so big videos and resumed downloads work."""
        path = os.path.abspath(path) if path else ""
        if not path or not os.path.isfile(path):
            return self._json({"error": "Файл не найден"}, 404)
        size = os.path.getsize(path)
        start, end, code = 0, size - 1, 200
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            a, _, b = rng[6:].split(",")[0].strip().partition("-")
            try:
                if a:
                    start, end = int(a), (int(b) if b else size - 1)
                elif b:
                    start = max(0, size - int(b))
                end = min(end, size - 1)
                code = 206
            except ValueError:
                pass
            if start > end:
                self.send_response(416)
                self._cors()
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        name = os.path.basename(path)
        from urllib.parse import quote
        ascii_name = "".join(c if 32 <= ord(c) < 127 and c not in '"\\' else "_" for c in name)
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition",
                         f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(end - start + 1))
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if start == 0:
            TRANSFERS.add("recv", name, size, path)
            log(f"  [↑] файл на телефон: {path}")
        left = end - start + 1
        try:
            with open(path, "rb") as f:
                f.seek(start)
                while left > 0:
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            pass

    def _static(self, path):
        if not os.path.isdir(WEB_DIR):
            body = "RemoteDesk server is running.".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        rel = path.lstrip("/") or "index.html"
        full = os.path.normpath(os.path.join(WEB_DIR, rel))
        if not full.startswith(os.path.normpath(WEB_DIR)) or not os.path.isfile(full):
            full = os.path.join(WEB_DIR, "index.html")
        types = {".html": "text/html; charset=utf-8", ".js": "text/javascript",
                 ".json": "application/json", ".png": "image/png", ".wasm": "application/wasm",
                 ".css": "text/css", ".ico": "image/x-icon", ".otf": "font/otf",
                 ".ttf": "font/ttf", ".mjs": "text/javascript"}
        ext = os.path.splitext(full)[1].lower()
        ctype = types.get(ext, "application/octet-stream")
        st = os.stat(full)
        etag = f'"{int(st.st_mtime)}-{st.st_size}"'
        # the phone keeps files it already has; it only asks whether they changed
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        gz = "gzip" in (self.headers.get("Accept-Encoding") or "") and ext in COMPRESSIBLE
        body = static_body(full, st, gz)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("ETag", etag)
        self.send_header("Cache-Control", "no-cache")
        if gz:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._authed(q):
            return
        n = int(self.headers.get("Content-Length") or 0)
        if u.path == "/api/upload":
            try:
                return self._json({"path": save_upload(q.get("name", ["file"])[0], self.rfile, n)})
            except Exception as e:
                return self._json({"error": str(e)}, 400)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json({"error": "bad json"}, 400)
        try:
            if u.path == "/api/transfers/clear":
                TRANSFERS.clear(str(data.get("kind") or ""))
                return self._json({"ok": True})
            if u.path == "/api/input":
                for ev in (data if isinstance(data, list) else [data]):
                    handle_input(ev)
                return self._json({"ok": True})
            if u.path == "/api/pty/start":
                return self._json(pty_start(data))
            if u.path in ("/api/pty/write", "/api/pty/resize", "/api/pty/kill"):
                sid = str(data.get("id", ""))
                if u.path == "/api/pty/kill":
                    PTYS.kill(sid)
                    return self._json({"ok": True})
                try:
                    p = PTYS.get(sid)
                except KeyError as e:
                    return self._json({"error": str(e), "gone": True}, 404)
                if u.path == "/api/pty/write":
                    p.write(str(data.get("data", "")))
                else:
                    p.resize(int(data.get("cols", 80)), int(data.get("rows", 24)))
                return self._json({"ok": True})
            if u.path == "/api/unlock":
                return self._json(unlock.unlock(str(data.get("pin", ""))))
            if u.path == "/api/cmd":
                return self._json(run_command(data.get("cmd", ""), data.get("cwd", "")))
            if u.path == "/api/rtc":
                if RTC is None:
                    return self._json({"error": "видео WebRTC недоступно: " + RTC_ERROR}, 501)
                RTC.peer_ip = self._ip()
                return self._json(RTC.answer(data))
        except Exception as e:
            return self._json({"error": str(e)}, 500)
        self._json({"error": "not found"}, 404)


def handle_input(ev):
    t = ev.get("t")
    mon = monitor(int(ev.get("m", 0)))
    if "x" in ev and "y" in ev:
        x, y = to_screen(mon, float(ev["x"]), float(ev["y"]))
        user32.SetCursorPos(x, y)
    if t == "move":
        pass
    elif t == "rel":
        pt = wt.POINT()
        user32.GetCursorPos(ctypes.byref(pt))
        user32.SetCursorPos(pt.x + int(ev.get("dx", 0)), pt.y + int(ev.get("dy", 0)))
    elif t == "click":
        down, up = BUTTONS[ev.get("b", "left")]
        for _ in range(int(ev.get("n", 1))):
            _send(_mouse(down), _mouse(up))
    elif t == "down":
        _send(_mouse(BUTTONS[ev.get("b", "left")][0]))
    elif t == "up":
        _send(_mouse(BUTTONS[ev.get("b", "left")][1]))
    elif t == "scroll":
        dy, dx = int(ev.get("dy", 0)), int(ev.get("dx", 0))
        if dy:
            _send(_mouse(MOUSEEVENTF_WHEEL, dy))
        if dx:
            _send(_mouse(MOUSEEVENTF_HWHEEL, dx))
    elif t == "text":
        type_text(ev.get("s", ""))
    elif t == "key":
        press_combo(ev.get("k", []))


def local_ips():
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except Exception:
        pass
    return sorted(i for i in ips if not i.startswith("127."))


RTC, RTC_ERROR = None, ""


def start_rtc():
    global RTC, RTC_ERROR
    try:
        import rtc
        rtc.RTC_PORT = int(CFG.get("rtc_port", rtc.RTC_PORT))
        rtc._PIN["port"] = rtc.RTC_PORT
        RTC = rtc.RtcHub(handle_input, public_ip=lambda: PUBLIC["ip"])
    except Exception as e:  # missing aiortc etc. — the picture stream still works
        RTC_ERROR = str(e)
        print(f"  [!] Быстрое видео выключено ({e}). Установите: pip install aiortc")


TAILSCALE_URL = "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe"


def tailscale_exe():
    for base in (os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("ProgramFiles(x86)", "")):
        p = os.path.join(base, "Tailscale", "tailscale.exe")
        if base and os.path.exists(p):
            return p
    return None


def install_tailscale():
    """Downloads the official Tailscale installer (always the newest) and starts it."""
    import urllib.request
    dst = os.path.join(os.environ.get("TEMP") or HERE, "tailscale-setup.exe")
    print("  Скачиваю Tailscale с официального сайта (pkgs.tailscale.com)…")
    try:
        urllib.request.urlretrieve(TAILSCALE_URL, dst)
    except Exception as e:
        print(f"  [!] Не получилось скачать ({e}). Скачайте вручную: https://tailscale.com/download")
        return
    print("  Запускаю установщик — следуйте шагам, затем войдите в Tailscale (значок у часов).")
    print("  Тот же аккаунт Tailscale включите на телефоне — и адрес 100.x.x.x будет работать откуда угодно.")
    try:
        os.startfile(dst)
    except Exception as e:
        print(f"  [!] Не удалось запустить установщик: {e}")


def tailscale_hint():
    """Explains remote access and offers to install Tailscale when it is missing."""
    if tailscale_exe():
        if not any(ip.startswith("100.") for ip in local_ips()):
            print("  НЕ ИЗ ДОМА: Tailscale установлен, но не подключён — войдите в него (значок у часов).")
            print("=" * 60)
        return
    print("  НЕ ИЗ ДОМА (мобильный интернет, другой Wi-Fi): нужен бесплатный Tailscale.")
    print("  Нажмите Enter в этом окне — программа скачает и установит его.")
    print("=" * 60)

    def wait_enter():
        try:
            input()
        except Exception:
            return
        install_tailscale()

    threading.Thread(target=wait_enter, daemon=True, name="tailscale").start()


def main():
    try:  # show every line at once, also when the window output is redirected
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    if FROZEN:
        os.system("title RemoteDesk")
    port = int(CFG.get("port", PORT))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.daemon_threads = True
    start_rtc()
    threading.Thread(target=duckdns_loop, daemon=True).start()
    caddy = start_caddy()
    print("=" * 60)
    print("  RemoteDesk — сервер удалённого доступа запущен")
    print("=" * 60)
    print(f"  Ключ:   {CFG['key']}")
    print()
    if caddy:
        print("  ИЗ ЛЮБОГО МЕСТА (интернет, без Tailscale):")
        print(f"     https://{CFG['domain']}:{CFG['https_port']}")
        print()
    print("  ДОМА (та же сеть Wi-Fi) или через Tailscale:")
    for ip in local_ips():
        print(f"     http://{ip}:{port}")
    print()
    print("  Видео экрана: " + ("быстрое (H.264 / WebRTC)" if RTC else "обычное (картинки)"))
    print(f"  Журнал входов: {LOG_FILE}")
    print("  Закройте это окно, чтобы выключить доступ.")
    print("=" * 60)
    tailscale_hint()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if caddy:
            caddy.terminate()


if __name__ == "__main__":
    main()
