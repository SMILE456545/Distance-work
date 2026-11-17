// Saving a PC file on the phone: in the browser the link is opened as a download
// (Safari asks «Загрузить?» and puts it in «Файлы»); the app has no browser for that.
export 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';
