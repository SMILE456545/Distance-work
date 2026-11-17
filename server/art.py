# -*- coding: utf-8 -*-
"""Pictures for the RemoteDesk window, drawn with Pillow (smooth edges: drawn 4x larger,
then scaled down): rounded window and blocks, line-art phone / tablet / laptop, Wi-Fi."""
from PIL import Image, ImageDraw

SS = 4
LANCZOS = Image.LANCZOS

# line-art colors for the black window
FILL, STROKE, DARK = (32, 32, 36, 255), (142, 142, 147, 255), (161, 161, 170, 255)
SCREEN, BEZEL = (18, 18, 21, 255), (58, 58, 64, 255)


def _corner(r):
    """Top-left quarter of a smooth circle of radius r (mask, 0..255)."""
    t = Image.new("L", (2 * r * SS, 2 * r * SS), 0)
    ImageDraw.Draw(t).ellipse([0, 0, 2 * r * SS - 1, 2 * r * SS - 1], fill=255)
    return t.crop((0, 0, r * SS, r * SS)).resize((r, r), LANCZOS)


def _round_mask(w, h, r):
    r = max(1, min(r, w // 2, h // 2))
    q = _corner(r)
    m = Image.new("L", (w, h), 255)
    m.paste(q, (0, 0))
    m.paste(q.transpose(Image.FLIP_LEFT_RIGHT), (w - r, 0))
    m.paste(q.transpose(Image.FLIP_TOP_BOTTOM), (0, h - r))
    m.paste(q.transpose(Image.ROTATE_180), (w - r, h - r))
    return m


def window_bg(w, h, r, head_h, key, body, head):
    """The whole window: black header on top, white body, rounded corners on the
    transparent key color."""
    img = Image.new("RGB", (w, h), body)
    if head_h > 0:
        img.paste(head, (0, 0, w, head_h))
    return Image.composite(img, Image.new("RGB", (w, h), key), _round_mask(w, h, r))


def rounded(w, h, r, fill, outer):
    """A rounded block of color `fill` on a background of color `outer`."""
    return Image.composite(Image.new("RGB", (w, h), fill), Image.new("RGB", (w, h), outer),
                           _round_mask(w, h, r))


def _canvas(w, h):
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def _done(im, w, h):
    return im.resize((w, h), LANCZOS)


def phone(w, h):
    im, d = _canvas(w, h)
    s = SS
    lw = max(2, round(w / 26)) * s
    d.rounded_rectangle([lw // 2, lw // 2, w * s - lw // 2, h * s - lw // 2], radius=w * s * 0.2,
                        fill=FILL, outline=STROKE, width=lw)
    iw, ih = w * s * 0.3, max(h * s * 0.035, 3 * s)  # dynamic island
    top = h * s * 0.055
    d.rounded_rectangle([(w * s - iw) / 2, top, (w * s + iw) / 2, top + ih], radius=ih / 2, fill=STROKE)
    return _done(im, w, h)


def tablet(w, h):
    im, d = _canvas(w, h)
    s = SS
    lw = max(2, round(w / 40)) * s
    d.rounded_rectangle([lw // 2, lw // 2, w * s - lw // 2, h * s - lw // 2], radius=w * s * 0.08,
                        fill=FILL, outline=STROKE, width=lw)
    c = h * s * 0.05
    d.ellipse([w * s / 2 - c / 3, c / 2, w * s / 2 + c / 3, c / 2 + c * 2 / 3], fill=STROKE)
    return _done(im, w, h)


def laptop(w, h):
    im, d = _canvas(w, h)
    s = SS
    lw = max(2, round(w / 60)) * s
    W, H = w * s, h * s
    sx0, sx1 = W * 0.08, W * 0.92
    sy0, sy1 = lw, H * 0.86
    d.rounded_rectangle([sx0, sy0, sx1, sy1], radius=W * 0.03, fill=FILL, outline=STROKE, width=lw)
    b = W * 0.025  # screen inside the bezel
    d.rounded_rectangle([sx0 + b, sy0 + b, sx1 - b, sy1 - b * 0.8], radius=W * 0.012,
                        fill=SCREEN, outline=BEZEL, width=max(s, lw // 2))
    d.rounded_rectangle([0, sy1 - lw / 2, W, H - lw / 2], radius=(H - sy1) / 2, fill=FILL,
                        outline=STROKE, width=lw)
    nw = W * 0.14  # the thumb notch
    d.rounded_rectangle([(W - nw) / 2, sy1 - lw / 2, (W + nw) / 2, sy1 + (H - sy1) * 0.35],
                        radius=(H - sy1) * 0.2, fill=STROKE)
    return _done(im, w, h)


def device(kind, w, h):
    return {"phone": phone, "tablet": tablet}.get(kind, laptop)(w, h)


def wifi(size, color=DARK):
    im, d = _canvas(size, size)
    s = SS
    S = size * s
    cx, cy = S / 2, S * 0.82
    lw = max(2, round(size / 11)) * s
    for k in (0.75, 0.5):
        r = S * k * 0.82
        d.arc([cx - r, cy - r, cx + r, cy + r], 225, 315, fill=color, width=lw)
    r = S * 0.07
    d.ellipse([cx - r, cy - r - lw * 0.2, cx + r, cy + r - lw * 0.2], fill=color)
    return _done(im, size, size)


def bell(size, color=STROKE, dot=None, bg="#000000"):
    """The notifications bell; `dot` = color of the «there is news» mark."""
    im, d = _canvas(size, size)
    S = size * SS
    cx, bw = S / 2, S * 0.5
    top, bottom = S * 0.17, S * 0.70
    d.ellipse([cx - S * 0.055, top - S * 0.07, cx + S * 0.055, top + S * 0.04], fill=color)   # knob
    d.pieslice([cx - bw / 2, top, cx + bw / 2, top + bw], 180, 360, fill=color)               # dome
    d.polygon([(cx - bw / 2, top + bw / 2 - 1), (cx + bw / 2, top + bw / 2 - 1),
               (cx + bw * 0.66, bottom), (cx - bw * 0.66, bottom)], fill=color)               # body
    d.rounded_rectangle([cx - bw * 0.78, bottom - S * 0.02, cx + bw * 0.78, bottom + S * 0.06],
                        radius=S * 0.04, fill=color)                                          # rim
    d.pieslice([cx - S * 0.1, bottom - S * 0.02, cx + S * 0.1, bottom + S * 0.18], 0, 180, fill=color)
    if dot:
        r = S * 0.17
        d.ellipse([S - 2 * r - SS, SS, S - SS, 2 * r + SS], fill=dot, outline=bg, width=int(S * 0.045))
    return _done(im, size, size)


def avatar(kind, size, bg=(44, 44, 48, 255)):
    """Device picture in a circle (for the device card)."""
    im, d = _canvas(size, size)
    d.ellipse([0, 0, size * SS - 1, size * SS - 1], fill=bg)
    out = _done(im, size, size)
    if kind == "laptop":
        pic = laptop(int(size * 0.62), int(size * 0.4))
    elif kind == "tablet":
        pic = tablet(int(size * 0.44), int(size * 0.58))
    else:
        pic = phone(int(size * 0.32), int(size * 0.6))
    out.alpha_composite(pic, ((size - pic.width) // 2, (size - pic.height) // 2))
    return out
