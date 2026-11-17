import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:zxing2/qrcode.dart';

import '../kraken/kraken.dart';

const bool canScanQr = true;

/// Live camera right on the page: the code is read from the video as soon as it is in the frame.
/// null = closed; throws [FormatException] when a photo (fallback) has no readable code.
Future<String?> scanQr(BuildContext context) async {
  // Safari gives a page the live camera only in a secure context (https or localhost);
  // over plain http there is no navigator.mediaDevices — then the phone takes a photo instead.
  final live = web.window.isSecureContext && web.window.navigator.has('mediaDevices');
  if (!live) return _scanPhoto();
  return Navigator.of(context).push<String>(PageRouteBuilder(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (_, _, _) => const _LiveScanner(),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

extension on web.Navigator {
  bool has(String name) => (this as JSObject).has(name);
}

class _LiveScanner extends StatefulWidget {
  const _LiveScanner();

  @override
  State<_LiveScanner> createState() => _LiveScannerState();
}

class _LiveScannerState extends State<_LiveScanner> {
  static int _seq = 0;
  late final String _viewType = 'rd-qr-video-${_seq++}';
  final web.HTMLVideoElement _video = web.HTMLVideoElement();
  web.MediaStream? _stream;
  Timer? _timer;
  bool _closed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _video
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true'); // iPhone: play inside the page, not fullscreen
    _video.style.cssText = 'width:100%;height:100%;object-fit:cover;pointer-events:none;background:#000';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
    _start();
  }

  Future<void> _start() async {
    try {
      final constraints = web.MediaStreamConstraints(
        audio: false.toJS,
        video: {
          'facingMode': {'ideal': 'environment'},
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        }.jsify()!,
      );
      final s = await web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
      if (_closed) {
        _stop(s);
        return;
      }
      _stream = s;
      _video.srcObject = s;
      try {
        await _video.play().toDart;
      } catch (_) {}
      _timer = Timer.periodic(const Duration(milliseconds: 160), (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      setState(() => _error = msg.contains('NotAllowed')
          ? 'Нет доступа к камере. Разрешите камеру для этого сайта в настройках Safari и попробуйте снова.'
          : 'Не удалось включить камеру: $msg');
    }
  }

  void _tick() {
    if (_busy || _closed || _video.readyState < 2) return;
    _busy = true;
    try {
      final text = _readVideo(_video);
      if (text != null) _finish(text);
    } finally {
      _busy = false;
    }
  }

  void _finish(String? text) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    final s = _stream;
    if (s != null) _stop(s);
    if (mounted) Navigator.of(context).pop(text);
  }

  static void _stop(web.MediaStream s) {
    final tracks = s.getTracks().toDart;
    for (final t in tracks) {
      t.stop();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    final s = _stream;
    if (s != null) _stop(s);
    _video.srcObject = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final box = math.min(size.width, size.height) * 0.68;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        HtmlElementView(viewType: _viewType),
        // darkened surroundings with a clear square for the code
        IgnorePointer(
          child: CustomPaint(painter: _FramePainter(box)),
        ),
        SafeArea(
          child: Column(children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  onPressed: () => _finish(null),
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
              child: Text(
                _error ?? 'Наведите камеру на QR-код в окне RemoteDesk на компьютере',
                textAlign: TextAlign.center,
                style: K.t(14, color: _error == null ? Colors.white : K.coral, w: FontWeight.w500, height: 1.4),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _FramePainter extends CustomPainter {
  final double box;
  _FramePainter(this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: box, height: box);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(22));
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rr);
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    canvas.drawRRect(
        rr,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.box != box;
}

final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();

/// One video frame: the middle of the picture, scaled down — quick enough to read several times a second.
String? _readVideo(web.HTMLVideoElement v) {
  final vw = v.videoWidth, vh = v.videoHeight;
  if (vw == 0 || vh == 0) return null;
  final side = math.min(vw, vh) * 0.8;
  final sx = (vw - side) / 2, sy = (vh - side) / 2;
  final n = math.min(560, side.round());
  _canvas
    ..width = n
    ..height = n;
  final ctx = _canvas.getContext('2d', {'willReadFrequently': true}.jsify()) as web.CanvasRenderingContext2D;
  ctx.drawImage(v, sx, sy, side, side, 0, 0, n, n);
  return _decode(ctx, n, n, both: false);
}

String? _decode(web.CanvasRenderingContext2D ctx, int w, int h, {required bool both}) {
  final rgba = ctx.getImageData(0, 0, w, h).data.toDart;
  final pixels = Int32List(w * h);
  for (var i = 0, p = 0; i < pixels.length; i++, p += 4) {
    pixels[i] = (0xFF << 24) | (rgba[p] << 16) | (rgba[p + 1] << 8) | rgba[p + 2];
  }
  final source = RGBLuminanceSource(w, h, pixels);
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    if (both) BinaryBitmap(GlobalHistogramBinarizer(source)),
  ]) {
    try {
      return QRCodeReader().decode(bitmap, hints: hints).text;
    } catch (_) {}
  }
  return null;
}

/// Fallback over plain http (no live camera): the phone camera takes a photo, the code is read from it.
Future<String?> _scanPhoto() async {
  // iPhone Safari only opens the camera / returns the photo for an input that is on the page
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*';
  input.setAttribute('capture', 'environment');
  input.style.cssText = 'position:fixed;left:-1000px;top:0;width:1px;height:1px;opacity:0';
  web.document.body!.append(input);
  final picked = Completer<web.File?>();
  void done(web.File? f) {
    if (!picked.isCompleted) picked.complete(f);
  }

  input.addEventListener('change', ((web.Event _) => done(input.files?.item(0))).toJS);
  input.addEventListener('input', ((web.Event _) => done(input.files?.item(0))).toJS);
  input.addEventListener('cancel', ((web.Event _) => done(null)).toJS);
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
  for (final side in const [900, 1300, 600, 1800]) {
    for (final crop in const [1.0, 0.6]) {
      final text = _readImage(img, side, crop);
      if (text != null) return text;
    }
  }
  throw const FormatException('no QR code');
}

String? _readImage(web.HTMLImageElement img, int maxSide, double crop) {
  final iw = img.naturalWidth, ih = img.naturalHeight;
  if (iw == 0 || ih == 0) return null;
  final cw = iw * crop, ch = ih * crop;
  final sx = (iw - cw) / 2, sy = (ih - ch) / 2;
  final k = math.min(1.0, maxSide / math.max(cw, ch));
  final w = math.max(1, (cw * k).round());
  final h = math.max(1, (ch * k).round());
  final canvas = web.HTMLCanvasElement()
    ..width = w
    ..height = h;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(img, sx, sy, cw, ch, 0, 0, w, h);
  return _decode(ctx, w, h, both: true);
}
