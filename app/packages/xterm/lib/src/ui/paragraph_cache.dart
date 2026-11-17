import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:quiver/collection.dart';

/// Key of one drawn cell. RemoteDesk patch: upstream used a 29-bit Jenkins hash of
/// (foreground, background, flags, content) as the key itself, so different cells
/// could share a key and draw the wrong letter (Cyrillic «с т у п» drawn as «0 1 2 .»).
/// A record compares every field, so equal keys really mean the same cell.
typedef ParagraphKey = (int fg, int bg, int flags, int content, int scaler);

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
class ParagraphCache {
  ParagraphCache(int maximumSize)
      : _cache = LruMap<ParagraphKey, Paragraph>(maximumSize: maximumSize);

  final LruMap<ParagraphKey, Paragraph> _cache;

  /// Returns a [Paragraph] for the given [key]. [key] is the same as the
  /// key argument to [performAndCacheLayout].
  Paragraph? getLayoutFromCache(ParagraphKey key) {
    return _cache[key];
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    ParagraphKey key,
  ) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(text);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    _cache[key] = paragraph;
    return paragraph;
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    _cache.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}
