// Full screen + landscape for the Screen tab: the browser Fullscreen / orientation API on the
// web (works on Android Chrome; iPhone Safari ignores it — the picture is rotated instead),
// immersive mode + landscape lock in the app.
export 'fullscreen_stub.dart' if (dart.library.js_interop) 'fullscreen_web.dart';
