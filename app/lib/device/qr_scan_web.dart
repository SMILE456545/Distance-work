import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:zxing2/qrcode.dart';

const bool canScanQr = true;

/// Opens the camera, then reads the QR code from the photo. null = cancelled;
/// throws [FormatException] when the photo has no readable code.
Future<String?> scanQr() async {
  // iPhone Safari only opens the camera / returns the photo for an input that is on the page
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*';
  input.setAttribute('capture', 'environment'); // straight to the back camera
  input.style.cssText = 'position:fixed;left:-1000px;top:0;width:1px;height:1px;opacity:0';
  web.document.body!.append(input);
  final picked = Completer<web.File?>();
  void done(web.File? f) {
    if (!picked.isCompleted) picked.complete(f);
  }

  input.addEventListener('change', ((web.Event _) => done(input.files?.item(0))).toJS);
  input.addEventListener('input', ((web.Event _) => done(input.files?.item(0))).toJS);
  input.addEventListener('cancel', ((web.Event _) => done(null)).toJS);
  // older Safari has no «cancel» event: when the page is back and no photo came, it was cancelled
  final JSFunction onFocus = ((web.Event _) {
    Timer(const Duration(milliseconds: 1500), () {
      if ((input.files?.length ?? 0) == 0) done(null);
    });
  }).toJS;
  web.window.addEventListener('focus', onFocus);
  input.click();
  final web.File? file;
  try {
    file = await picked.future;
  } finally {
    web.window.removeEventListener('focus', onFocus);
    input.remove();
  }
  if (file == null) return null;

  final url = web.URL.createObjectURL(file);
  final img = web.HTMLImageElement()..src = url;
  try {
    await img.decode().toDart;
  } finally {
    web.URL.revokeObjectURL(url);
  }
  // A phone photo is 12 MP and a photo of a screen has ripples: read smaller copies,
  // the whole photo and its middle, with two ways of turning it into black and white.
  for (final side in const [900, 1300, 600, 1800]) {
    for (final crop in const [1.0, 0.6]) {
      final text = _read(img, side, crop);
      if (text != null) return text;
    }
  }
  throw const FormatException('no QR code');
}

String? _read(web.HTMLImageElement img, int maxSide, double crop) {
  final iw = img.naturalWidth, ih = img.naturalHeight;
  if (iw == 0 || ih == 0) return null;
  final cw = iw * crop, ch = ih * crop; // the part of the photo to read
  final sx = (iw - cw) / 2, sy = (ih - ch) / 2;
  final k = math.min(1.0, maxSide / math.max(cw, ch));
  final w = math.max(1, (cw * k).round());
  final h = math.max(1, (ch * k).round());
  final canvas = web.HTMLCanvasElement()
    ..width = w
    ..height = h;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(img, sx, sy, cw, ch, 0, 0, w, h);
  final rgba = ctx.getImageData(0, 0, w, h).data.toDart;
  final pixels = Int32List(w * h);
  for (var i = 0, p = 0; i < pixels.length; i++, p += 4) {
    pixels[i] = (0xFF << 24) | (rgba[p] << 16) | (rgba[p + 1] << 8) | rgba[p + 2];
  }
  final source = RGBLuminanceSource(w, h, pixels);
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    BinaryBitmap(GlobalHistogramBinarizer(source)),
  ]) {
    try {
      return QRCodeReader().decode(bitmap, hints: hints).text;
    } catch (_) {}
  }
  return null;
}
