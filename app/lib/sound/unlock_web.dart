import 'package:web/web.dart' as web;

/// Starts (or mutes) the audio elements flutter_webrtc created for remote sound.
void unlockSound({bool muted = false}) {
  final list = web.document.querySelectorAll('audio');
  for (var i = 0; i < list.length; i++) {
    final el = list.item(i);
    if (el == null) continue;
    final media = el as web.HTMLMediaElement;
    media.muted = muted;
    if (!muted) media.play();
  }
}
