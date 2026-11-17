import 'package:web/web.dart' as web;

bool startDownload(String url, String name) {
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.append(a);
  a.click();
  a.remove();
  return true;
}
