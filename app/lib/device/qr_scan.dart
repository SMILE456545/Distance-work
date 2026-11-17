// «Сканировать QR-код» on the connect page: reads the code from the PC window and returns
// its text («http://192.168.x.x:8765/?k=KEY»).
//
// Web: a live camera view right on the page reads the code from the video. Safari allows
// the live camera only over https; over plain http it falls back to taking a photo.
export 'qr_scan_stub.dart' if (dart.library.js_interop) 'qr_scan_web.dart';
