// Browsers (iPhone Safari especially) only let sound play after a tap.
// unlockSound() is called from a tap and starts every media element on the page.
export 'unlock_stub.dart' if (dart.library.js_interop) 'unlock_web.dart';
