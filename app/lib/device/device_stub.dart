import 'dart:io' show Platform;

/// «kind; model» — kind is phone, tablet or laptop. ASCII only (it goes into a header).
String deviceTag() {
  if (Platform.isAndroid) return 'phone; Android';
  if (Platform.isIOS) return 'phone; iPhone';
  if (Platform.isMacOS) return 'laptop; Mac';
  if (Platform.isWindows) return 'laptop; Windows PC';
  return 'laptop; Linux PC';
}

/// Native apps are not opened from a link, so there is nothing to clean.
void clearLoginLink() {}

/// Native apps: nothing to pick.
String? deviceOverride;

List<String> deviceChoices() => const [];
