import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> enterFullscreen() async {
  try {
    await web.document.documentElement?.requestFullscreen().toDart;
  } catch (_) {}
  try {
    await web.window.screen.orientation.lock('landscape').toDart;
  } catch (_) {}
}

Future<void> exitFullscreen() async {
  try {
    web.window.screen.orientation.unlock();
  } catch (_) {}
  try {
    if (web.document.fullscreenElement != null) await web.document.exitFullscreen().toDart;
  } catch (_) {}
}
