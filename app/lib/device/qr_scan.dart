// «Сканировать QR-код» on the connect page: reads the code from the PC window and returns
// its text («http://192.168.x.x:8765/?k=KEY»).
//
// Safari gives a page live camera only over https, and the PC is reached over plain http,
// so the web version opens the phone camera for a photo (works over http) and reads the
// code from that photo right in the app.
export 'qr_scan_stub.dart' if (dart.library.js_interop) 'qr_scan_web.dart';
