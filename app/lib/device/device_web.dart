import 'package:web/web.dart' as web;

/// Safari does not tell the iPhone model; the screen size in points + pixel ratio narrows it
/// down to a few models. When several fit, the person picks theirs once on the connect page.
const _iphones = <String, List<String>>{
  '320x568@2': ['iPhone SE'],
  '375x667@2': ['iPhone SE (2/3)', 'iPhone 8', 'iPhone 7', 'iPhone 6s'],
  '414x736@3': ['iPhone 8 Plus', 'iPhone 7 Plus'],
  '375x812@3': ['iPhone X', 'iPhone XS', 'iPhone 11 Pro', 'iPhone 12 mini', 'iPhone 13 mini'],
  '414x896@2': ['iPhone 11', 'iPhone XR'],
  '414x896@3': ['iPhone 11 Pro Max', 'iPhone XS Max'],
  '390x844@3': ['iPhone 12', 'iPhone 12 Pro', 'iPhone 13', 'iPhone 13 Pro', 'iPhone 14', 'iPhone 16e'],
  '428x926@3': ['iPhone 12 Pro Max', 'iPhone 13 Pro Max', 'iPhone 14 Plus'],
  '393x852@3': ['iPhone 14 Pro', 'iPhone 15', 'iPhone 15 Pro', 'iPhone 16'],
  '430x932@3': ['iPhone 14 Pro Max', 'iPhone 15 Pro Max', 'iPhone 15 Plus', 'iPhone 16 Plus'],
  '402x874@3': ['iPhone 16 Pro', 'iPhone 17', 'iPhone 17 Pro'],
  '440x956@3': ['iPhone 16 Pro Max', 'iPhone 17 Pro Max'],
  '420x912@3': ['iPhone Air'],
};

/// The model the person picked (saved on the phone), or null.
String? deviceOverride;

String _screenKey() {
  final s = web.window.screen;
  final w = s.width < s.height ? s.width : s.height;
  final h = s.width < s.height ? s.height : s.width;
  return '${w}x$h@${web.window.devicePixelRatio.round()}';
}

/// Models that fit this screen when there is more than one (the connect page asks which).
List<String> deviceChoices() {
  if (!web.window.navigator.userAgent.contains('iPhone')) return const [];
  final list = _iphones[_screenKey()] ?? const <String>[];
  return list.length > 1 ? list : const [];
}

String deviceTag() {
  final nav = web.window.navigator;
  final ua = nav.userAgent;
  final s = web.window.screen;
  final w = s.width < s.height ? s.width : s.height;
  final h = s.width < s.height ? s.height : s.width;
  final dpr = web.window.devicePixelRatio.round();
  final tag = _tag(ua, nav, w, h, dpr);
  return '$tag; ${w}x$h@$dpr'; // the screen goes along so the PC log shows what was measured
}

String _tag(String ua, web.Navigator nav, int w, int h, int dpr) {
  if (ua.contains('iPhone')) {
    final list = _iphones['${w}x$h@$dpr'] ?? const <String>[];
    final pick = deviceOverride;
    if (pick != null && list.contains(pick)) return 'phone; $pick';
    return 'phone; ${list.length == 1 ? list.first : 'iPhone'}';
  }
  // iPadOS Safari pretends to be a Mac, but a Mac has no touch screen
  if (ua.contains('iPad') || (ua.contains('Macintosh') && nav.maxTouchPoints > 1)) return 'tablet; iPad';
  if (ua.contains('Android')) {
    final m = RegExp(r'Android [\d.]+; ([^;)]+)').firstMatch(ua)?.group(1)?.trim();
    final model = (m == null || m == 'K' || m.length < 2) ? 'Android' : m.replaceAll(RegExp(r'Build/.*'), '').trim();
    final kind = ua.contains('Mobile') ? 'phone' : 'tablet';
    return '$kind; ${model.replaceAll(RegExp(r'[^\x20-\x7E]'), '')}';
  }
  if (ua.contains('Macintosh')) return 'laptop; Mac';
  if (ua.contains('Windows')) return 'laptop; Windows PC';
  return 'laptop; Computer';
}

/// The QR code opens «http://pc:8765/?k=KEY»: once the key is read, remove it from the
/// address bar so it is not left in the browser history.
void clearLoginLink() {
  final u = Uri.base;
  if (!u.queryParameters.containsKey('k')) return;
  web.window.history.replaceState(null, '', u.replace(queryParameters: const {}).toString().replaceAll('?', ''));
}
