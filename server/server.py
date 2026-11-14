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

import mss
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")
WEB_DIR = os.path.join(os.path.dirname(HERE), "web")
PORT = 8765

user32 = ctypes.windll.user32


# ---------------------------------------------------------------- config
def load_config():
    cfg = {}
    if os.path.exists(CONFIG):
        try:
            with open(CONFIG, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            cfg = {}
    if not cfg.get("key"):
        cfg["key"] = "".join(secrets.choice("0123456789") for _ in range(8))
    cfg.setdefault("port", PORT)
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return cfg


CFG = load_config()


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
_tls = threading.local()


def sct():
    if not hasattr(_tls, "sct"):
        _tls.sct = mss.mss()
    return _tls.sct


def monitors():
    return sct().monitors[1:]  # skip the "all monitors" entry


def monitor(idx):
    mons = monitors()
    return mons[max(0, min(idx, len(mons) - 1))]


def to_screen(mon, nx, ny):
    x = mon["left"] + int(max(0.0, min(1.0, nx)) * (mon["width"] - 1))
    y = mon["top"] + int(max(0.0, min(1.0, ny)) * (mon["height"] - 1))
    return x, y


CURSOR = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)]


def grab(mon_idx, max_w, quality):
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
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    data = buf.getvalue()
    return data, hashlib.md5(data).hexdigest()[:12]


# ---------------------------------------------------------------- terminal
MARK = "__RD_CWD__"


def run_command(cmd, cwd, timeout=120):
    if not cwd or not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")
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


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    server_version = "RemoteDesk/1.0"

    def log_message(self, fmt, *args):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self, q):
        key = self.headers.get("X-Key") or q.get("key", [""])[0]
        ok = secrets.compare_digest(key.encode(), CFG["key"].encode())
        if not ok:
            time.sleep(0.5)
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
        ctype = types.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        with open(full, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._authed(q):
            return
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json({"error": "bad json"}, 400)
        try:
            if u.path == "/api/input":
                for ev in (data if isinstance(data, list) else [data]):
                    handle_input(ev)
                return self._json({"ok": True})
            if u.path == "/api/cmd":
                return self._json(run_command(data.get("cmd", ""), data.get("cwd", "")))
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


def main():
    port = int(CFG.get("port", PORT))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.daemon_threads = True
    print("=" * 56)
    print("  RemoteDesk — сервер удалённого доступа запущен")
    print("=" * 56)
    for ip in local_ips():
        print(f"  Адрес:  {ip}    Порт: {port}")
    print(f"  Ключ:   {CFG['key']}")
    print()
    print("  В приложении на телефоне введите адрес, порт и ключ.")
    if os.path.isdir(WEB_DIR):
        for ip in local_ips():
            print(f"  Или в браузере телефона: http://{ip}:{port}")
    print("  Телефон и ноутбук должны быть в одной сети Wi-Fi.")
    print("  Закройте это окно, чтобы выключить доступ.")
    print("=" * 56)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
