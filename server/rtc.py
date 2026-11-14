# -*- coding: utf-8 -*-
"""Fast screen video for RemoteDesk: the screen is sent as H.264 video over WebRTC
(like AnyDesk/Parsec) instead of separate JPEG pictures. Mouse and keyboard events
come back over a WebRTC data channel, so they skip HTTP round-trips.

Works on the local network, over Tailscale and over the internet: the video goes
straight between phone and laptop. For the internet, the router forwards one UDP
port (RTC_PORT) to this laptop."""
import asyncio
import ctypes
import ctypes.wintypes as wt
import fractions
import json
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import av
import mss
import numpy as np
try:
    import dxcam
except Exception:  # not installed / no DirectX — slower GDI capture is used
    dxcam = None
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
from aiortc.codecs import h264
from aiortc.mediastreams import MediaStreamError, MediaStreamTrack

user32 = ctypes.windll.user32
STUN = "stun:stun.l.google.com:19302"

# ---------------------------------------------------------------- encoder tuning
# aiortc's defaults (0.5–3 Mbit/s, x264 preset "medium") are made for webcams.
# A screen needs sharper text and a faster encoder.
h264.DEFAULT_BITRATE = 2_500_000
h264.MIN_BITRATE = 300_000
h264.MAX_BITRATE = 4_000_000       # changed per quality preset, see set_quality()


def _encode_frame(self, frame, force_keyframe):
    if self.codec and (frame.width != self.codec.width or frame.height != self.codec.height
                       # restarting the encoder costs a full picture, so only for big changes
                       or abs(self.target_bitrate - self.codec.bit_rate) / self.codec.bit_rate > 0.35):
        self.buffer_data = b""
        self.buffer_pts = None
        self.codec = None
    frame.pict_type = (av.video.frame.PictureType.I if force_keyframe
                       else av.video.frame.PictureType.NONE)
    if self.codec is None:
        c = av.CodecContext.create("libx264", "w")
        c.width, c.height = frame.width, frame.height
        c.bit_rate = self.target_bitrate
        c.pix_fmt = "yuv420p"
        c.framerate = fractions.Fraction(h264.MAX_FRAME_RATE, 1)
        c.time_base = fractions.Fraction(1, h264.MAX_FRAME_RATE)
        c.options = {
            "preset": "superfast",
            "tune": "zerolatency",
            # VBV keeps every frame small enough not to clog the connection
            "x264-params": f"vbv-maxrate={self.target_bitrate // 1000}:"
                           f"vbv-bufsize={self.target_bitrate // 1000 // 2}:keyint=300:threads=4",
        }
        c.profile = "Baseline"
        self.codec = c
    data = b"".join(bytes(p) for p in self.codec.encode(frame))
    if data:
        yield from self._split_bitstream(data)


h264.H264Encoder._encode_frame = _encode_frame


# ---------------------------------------------------------------- fixed UDP port
RTC_PORT = 8766
_PIN = {"host": None, "port": RTC_PORT}


def primary_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


class PinnedLoop(asyncio.SelectorEventLoop):
    """Binds the WebRTC socket on the main network card to RTC_PORT, so the router
    can forward that one port to this laptop. Other cards (Tailscale, …) stay random."""

    async def create_datagram_endpoint(self, protocol_factory, local_addr=None, **kw):
        if local_addr and local_addr[1] == 0 and local_addr[0] == _PIN["host"]:
            try:
                return await super().create_datagram_endpoint(
                    protocol_factory, local_addr=(local_addr[0], _PIN["port"]), **kw)
            except OSError:
                pass  # taken (second viewer) — fall back to a random port
        return await super().create_datagram_endpoint(protocol_factory, local_addr=local_addr, **kw)


# ---------------------------------------------------------------- screen track
CURSOR = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)]


def _cursor_sprite(scale):
    from PIL import Image, ImageDraw
    w, h = int(14 * scale) + 2, int(22 * scale) + 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).polygon([(x * scale + 1, y * scale + 1) for x, y in CURSOR],
                                fill=(255, 255, 255, 255), outline=(0, 0, 0, 255), width=max(1, int(scale)))
    a = np.asarray(img).astype(np.float32)
    bgr = a[:, :, [2, 1, 0]]
    alpha = a[:, :, 3:4] / 255.0
    return bgr, alpha


class ScreenTrack(MediaStreamTrack):
    kind = "video"

    def __init__(self, hub):
        super().__init__()
        self.hub = hub
        self.start = None
        self.next_at = 0.0
        self.pool = ThreadPoolExecutor(1, thread_name_prefix="capture")
        self._tls = threading.local()
        self._sprite = None

    def _shot(self, mon_idx):
        """Full-size BGRA picture of the monitor. DirectX capture (dxcam) takes ~1 ms and
        tells when nothing changed; the old GDI way (mss) takes ~30 ms and is the fallback."""
        tls = self._tls
        if not hasattr(tls, "sct"):
            tls.sct = (getattr(mss, "MSS", None) or mss.mss)()
            tls.cams, tls.last = {}, {}
        mons = tls.sct.monitors[1:]
        mon_idx = max(0, min(mon_idx, len(mons) - 1))
        mon = mons[mon_idx]
        if dxcam is not None and tls.cams.get(mon_idx) is not False:
            try:
                cam = tls.cams.get(mon_idx)
                if cam is None:
                    cam = tls.cams[mon_idx] = dxcam.create(output_idx=mon_idx, output_color="BGRA")
                img = cam.grab()
                if img is not None:
                    tls.last[mon_idx] = img
                if mon_idx in tls.last and tls.last[mon_idx].shape[:2] == (mon["height"], mon["width"]):
                    return mon, tls.last[mon_idx]
            except Exception:
                tls.cams[mon_idx] = False  # this monitor can't be captured with DirectX
        shot = tls.sct.grab(mon)
        return mon, np.frombuffer(shot.bgra, np.uint8).reshape(shot.height, shot.width, 4)

    def _grab(self, mon_idx, width):
        mon, full = self._shot(mon_idx)
        H, W = full.shape[:2]
        width = min(width, W) & ~1
        height = int(H * width / W) & ~1
        # shrink first, then draw the mouse pointer on the small copy (the captured picture has none)
        small = av.VideoFrame.from_ndarray(full, format="bgra").reformat(
            width=width, height=height, interpolation="AREA").to_ndarray()
        pt = wt.POINT()
        user32.GetCursorPos(ctypes.byref(pt))
        s = width / W
        cx, cy = int((pt.x - mon["left"]) * s), int((pt.y - mon["top"]) * s)
        if 0 <= cx < width and 0 <= cy < height:
            k = max(1.0, width / 1366)
            if self._sprite is None or self._sprite[0] != k:
                self._sprite = (k, *_cursor_sprite(k))
            _, bgr, alpha = self._sprite
            h, w = min(bgr.shape[0], height - cy), min(bgr.shape[1], width - cx)
            region = small[cy:cy + h, cx:cx + w, :3].astype(np.float32)
            small[cy:cy + h, cx:cx + w, :3] = (bgr[:h, :w] * alpha[:h, :w]
                                               + region * (1 - alpha[:h, :w])).astype(np.uint8)
        return av.VideoFrame.from_ndarray(small, format="bgra").reformat(format="yuv420p")

    async def recv(self):
        if self.readyState != "live":
            raise MediaStreamError
        hub = self.hub
        while hub.paused:
            await hub.resumed.wait()
        loop = asyncio.get_running_loop()
        now = time.time()
        if self.start is None:
            self.start = self.next_at = now
        self.next_at = max(self.next_at + 1.0 / hub.fps, now - 0.2)
        if self.next_at > now:
            await asyncio.sleep(self.next_at - now)
        frame = await loop.run_in_executor(self.pool, self._grab, hub.monitor, hub.width)
        frame.pts = int((time.time() - self.start) * 90000)
        frame.time_base = fractions.Fraction(1, 90000)
        return frame

    def stop(self):
        super().stop()
        self.pool.shutdown(wait=False)


# ---------------------------------------------------------------- sessions
def prefer_h264(sdp):
    """Moves H.264 to the front of the phone's codec list: phones decode it in
    hardware (less battery, smoother). VP8 stays as a fallback."""
    lines = sdp.split("\r\n")
    names, apt = {}, {}
    for ln in lines:
        if ln.startswith("a=rtpmap:"):
            pt, _, rest = ln[9:].partition(" ")
            names[pt] = rest.split("/")[0].upper()
        elif ln.startswith("a=fmtp:") and "apt=" in ln:
            pt, _, rest = ln[7:].partition(" ")
            apt[pt] = rest.split("apt=")[1].split(";")[0]
        elif ln.startswith("a=fmtp:") and "42e01f" in ln:
            names[ln[7:].partition(" ")[0] + "!"] = 1  # constrained baseline — the best match
    for i, ln in enumerate(lines):
        if ln.startswith("m=video "):
            head, pts = ln.split(" ")[:3], ln.split(" ")[3:]
            h264 = sorted([p for p in pts if names.get(p) == "H264"], key=lambda p: p + "!" not in names)
            rtx = [p for p in pts if apt.get(p) in h264]
            rest = [p for p in pts if p not in h264 and p not in rtx]
            lines[i] = " ".join(head + h264 + rtx + rest)
    return "\r\n".join(lines)


def _codec_rank(c):
    if c.mimeType == "video/H264":
        return 0 if str(c.parameters.get("profile-level-id", "")).startswith("42e0") else 1
    return 2 if c.mimeType == "video/rtx" else 3


# STUN answers come in a few ms; don't wait 5 s for network cards that can't reach it
try:
    import aioice.ice as _ice
    _ice.Connection.get_component_candidates.__defaults__ = (1.5,)
except Exception:
    pass


class RtcHub:
    def __init__(self, handle_input, public_ip=lambda: None):
        self.handle_input = handle_input
        self.public_ip = public_ip
        self.loop = PinnedLoop()
        self.pcs = set()
        self.input_pool = ThreadPoolExecutor(1, thread_name_prefix="input")
        self.monitor, self.width, self.fps = 0, 1366, 30
        self.paused = False
        self.resumed = None
        threading.Thread(target=self._run, daemon=True, name="rtc").start()

    def _run(self):
        asyncio.set_event_loop(self.loop)
        self.resumed = asyncio.Event()
        self.loop.run_forever()

    def set_quality(self, cfg):
        if "m" in cfg:
            self.monitor = int(cfg["m"])
        if "w" in cfg:
            self.width = max(320, min(3840, int(cfg["w"])))
        if "fps" in cfg:
            self.fps = max(5, min(60, int(cfg["fps"])))
            h264.MAX_FRAME_RATE = self.fps
        if "br" in cfg:
            h264.MAX_BITRATE = max(500_000, min(12_000_000, int(cfg["br"])))

    def _set_paused(self, paused):
        self.paused = paused
        if paused:
            self.resumed.clear()
        else:
            self.resumed.set()

    def _on_message(self, msg):
        try:
            data = json.loads(msg)
        except ValueError:
            return
        for ev in (data if isinstance(data, list) else [data]):
            t = ev.get("t")
            if t == "cfg":
                self.set_quality(ev)
            elif t == "pause":
                self._set_paused(True)
            elif t == "resume":
                self._set_paused(False)
            elif t != "ping":
                self.input_pool.submit(self._safe_input, ev)

    def _safe_input(self, ev):
        try:
            self.handle_input(ev)
        except Exception:
            pass

    async def _answer(self, offer):
        # one viewer at a time: a new connection replaces the old one (and frees the port)
        for old in list(self.pcs):
            await old.close()
        self.pcs.clear()
        _PIN["host"] = primary_ip()
        self.set_quality(offer)
        self._set_paused(False)

        pc = RTCPeerConnection(RTCConfiguration(iceServers=[RTCIceServer(STUN)]))
        self.pcs.add(pc)

        @pc.on("datachannel")
        def on_dc(channel):
            channel.on("message", self._on_message)

        @pc.on("connectionstatechange")
        async def on_state():
            if pc.connectionState in ("failed", "closed"):
                self.pcs.discard(pc)
                await pc.close()

        await pc.setRemoteDescription(RTCSessionDescription(sdp=prefer_h264(offer["sdp"]), type=offer["type"]))
        for tr in pc.getTransceivers():
            if tr.kind == "video" and getattr(tr, "_codecs", None):
                tr._codecs.sort(key=_codec_rank)  # aiortc keeps the phone's order otherwise
        pc.addTrack(ScreenTrack(self))
        await pc.setLocalDescription(await pc.createAnswer())
        return {"sdp": self._add_public_candidate(pc.localDescription.sdp), "type": pc.localDescription.type}

    def _add_public_candidate(self, sdp):
        """Tell the phone the laptop's internet address + forwarded port, in case STUN
        reported a different port than the one the router forwards."""
        ip, host = self.public_ip(), _PIN["host"]
        if not ip or not host or f" {host} {RTC_PORT} typ host" not in sdp:
            return sdp
        line = f"a=candidate:rdpub 1 udp 1694498815 {ip} {RTC_PORT} typ srflx raddr {host} rport {RTC_PORT}"
        if f" {ip} {RTC_PORT} " in sdp:
            return sdp
        out, added = [], False
        for ln in sdp.split("\r\n"):
            if not added and ln.startswith("a=end-of-candidates"):
                out.append(line)
                added = True
            out.append(ln)
        if not added:
            for i, ln in enumerate(out):
                if ln.startswith("a=candidate:"):
                    out.insert(i, line)
                    break
        return "\r\n".join(out)

    def answer(self, offer, timeout=20):
        return asyncio.run_coroutine_threadsafe(self._answer(offer), self.loop).result(timeout)
