/// Kraken Digital design system: colors, type, logo, 3D tentacle background,
/// and the bottom dock. Shared look for every Kraken Digital app.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

part 'kraken_logo_data.dart';

// ------------------------------------------------------------------ colors
class K {
  static const violet = Color(0xFF6E64F0);
  static const violetDeep = Color(0xFF4B3FD6);
  static const lilac = Color(0xFFA9A2FF);
  static const ink = Color(0xFF0C0C10);
  static const panel = Color(0xFF16161C);
  static const panel2 = Color(0xFF22222A);
  static const line = Color(0x1FFFFFFF);
  static const white = Color(0xFFF6F6FA);
  static const muted = Color(0xFF9C9CAB);
  static const lime = Color(0xFF3CF06E);
  static const yellow = Color(0xFFFFE01B);
  static const coral = Color(0xFFFF6B5B);

  static const font = 'Montserrat';
  static const mono = 'JetBrainsMono';

  /// Bold geometric heading.
  static TextStyle h(double size, {Color color = white, FontWeight w = FontWeight.w800, double height = 1.0}) =>
      TextStyle(fontFamily: font, fontSize: size, fontWeight: w, color: color, height: height, letterSpacing: -0.5);

  /// Light italic accent word ("of *digital* Arts").
  static TextStyle accent(double size, {Color color = white}) => TextStyle(
      fontFamily: font, fontSize: size, fontWeight: FontWeight.w300, fontStyle: FontStyle.italic, color: color, height: 1.0);

  static TextStyle t(double size, {Color color = white, FontWeight w = FontWeight.w500, double? height}) =>
      TextStyle(fontFamily: font, fontSize: size, fontWeight: w, color: color, height: height);

  static TextStyle code(double size, {Color color = white, FontWeight w = FontWeight.w400}) => TextStyle(
      fontFamily: mono, fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'], fontSize: size, fontWeight: w,
      color: color, height: 1.4);

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: font,
      colorScheme: ColorScheme.fromSeed(
        seedColor: violet,
        brightness: Brightness.dark,
        primary: lilac,
        surface: panel,
      ),
      scaffoldBackgroundColor: ink,
    );
    return base.copyWith(
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: white,
        contentTextStyle: t(14, color: ink, w: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: panel,
        showDragHandle: false,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(10)),
        textStyle: t(12, color: ink, w: FontWeight.w600),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: lime),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: lime, selectionColor: Color(0x666E64F0)),
    );
  }
}

// ------------------------------------------------------------------ logo
/// The Kraken Digital mark. Eyes are cut out, so whatever is behind shows through.
class KrakenLogo extends StatelessWidget {
  final double size;
  final Color color;
  const KrakenLogo({super.key, this.size = 40, this.color = K.white});

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _LogoPainter(color)));
}

class _LogoPainter extends CustomPainter {
  final Color color;
  _LogoPainter(this.color);

  static Path? _cache;

  static Path _poly(List<double> p) {
    final path = Path()..moveTo(p[0], p[1]);
    for (var i = 2; i < p.length; i += 2) {
      path.lineTo(p[i], p[i + 1]);
    }
    return path..close();
  }

  static Path get _shape {
    if (_cache != null) return _cache!;
    var body = Path();
    for (final p in _krakenBody) {
      body = Path.combine(PathOperation.union, body, _poly(p));
    }
    for (final e in _krakenEyes) {
      body = Path.combine(PathOperation.difference, body, _poly(e));
    }
    return _cache = body;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final b = _krakenBounds;
    final w = b[2] - b[0], h = b[3] - b[1];
    final s = math.min(size.width / w, size.height / h);
    canvas.translate((size.width - w * s) / 2, (size.height - h * s) / 2);
    canvas.scale(s);
    canvas.translate(-b[0], -b[1]);
    canvas.drawPath(_shape, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}

/// Logo inside a round badge (like the round "MUSEUM" stamp in the references).
class KrakenBadge extends StatelessWidget {
  final double size;
  final Color bg;
  final Color fg;
  const KrakenBadge({super.key, this.size = 44, this.bg = K.lilac, this.fg = K.ink});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        padding: EdgeInsets.all(size * 0.16),
        child: KrakenLogo(size: size * 0.68, color: fg),
      );
}

/// "KRAKEN DIGITAL" lock-up: badge + wordmark.
class KrakenWordmark extends StatelessWidget {
  final Color color;
  const KrakenWordmark({super.key, this.color = K.white});

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
      decoration: BoxDecoration(color: K.ink, borderRadius: BorderRadius.circular(40)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        KrakenLogo(size: 30, color: color),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('KRAKEN', style: K.h(13, color: color).copyWith(letterSpacing: 2.4, height: 1.05)),
          Text('digital', style: K.accent(13, color: color).copyWith(letterSpacing: 0.6)),
        ]),
      ]));
}

/// The product's own icon (each Kraken Digital app has its own; the kraken is the company mark).
class AppIcon extends StatelessWidget {
  final double size;
  const AppIcon({super.key, this.size = 44});

  @override
  Widget build(BuildContext context) => Image.asset('assets/images/app_icon.png',
      width: size, height: size, filterQuality: FilterQuality.medium);
}

// ------------------------------------------------------------------ background
enum KrakenScene { hero, calm }

/// Plain black-and-white gradient background.
class KrakenBackground extends StatelessWidget {
  final KrakenScene scene;
  final bool animate;
  final Widget? child;
  const KrakenBackground({super.key, this.scene = KrakenScene.hero, this.animate = false, this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF2F2F5), Color(0xFF0C0C10)],
          ),
        ),
        child: child ?? const SizedBox.expand(),
      );
}

// ------------------------------------------------------------------ controls
/// Pill button (yellow CTA by default) with the ↗ arrow like in the references.
class KPillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color bg;
  final Color fg;
  final bool busy;
  final bool arrow;
  const KPillButton(this.label,
      {super.key, this.onPressed, this.bg = K.yellow, this.fg = K.ink, this.busy = false, this.arrow = true});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onPressed == null && !busy ? bg.withValues(alpha: 0.4) : bg,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: busy ? null : onPressed,
        child: SizedBox(
          height: 58,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, style: K.t(16, color: fg, w: FontWeight.w700)),
            const SizedBox(width: 8),
            if (busy)
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
            else if (arrow)
              Icon(Icons.north_east_rounded, size: 20, color: fg),
          ]),
        ),
      ),
    );
  }
}

/// Small status pill with a dot, like "● OPEN NOW".
class KTag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const KTag(this.text, {super.key, this.bg = K.lime, this.fg = K.ink});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(40)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(text, style: K.t(11, color: fg, w: FontWeight.w700).copyWith(letterSpacing: 0.8)),
        ]),
      );
}

/// Chip in the colorful style of the references (white / lilac / yellow / lime / coral).
class KChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final Color bg;
  final Color fg;
  final TextStyle? style;
  const KChip(this.label, {super.key, required this.onTap, this.icon, this.bg = K.panel2, this.fg = K.white, this.style});

  @override
  Widget build(BuildContext context) => Material(
        color: bg,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
              Text(label, style: style ?? K.t(13, color: fg, w: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

/// Round icon button (like the G / Apple circles in the references).
class KRound extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tip;
  final bool on;
  final double size;
  final Color? bg;
  final Color? fg;
  const KRound(this.icon, {super.key, this.onTap, this.tip, this.on = false, this.size = 48, this.bg, this.fg});

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: bg ?? (on ? K.lime : K.panel2),
      shape: CircleBorder(side: BorderSide(color: on || bg == Colors.transparent ? Colors.transparent : K.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * 0.46, color: fg ?? (on ? K.ink : K.white)),
        ),
      ),
    );
    return tip == null ? b : Tooltip(message: tip!, child: b);
  }
}

// ------------------------------------------------------------------ dock
class DockAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool on;
  const DockAction(this.icon, this.label, this.onTap, {this.on = false});
}

class DockTab {
  final IconData icon;
  final String label;
  const DockTab(this.icon, this.label);
}

/// The bottom block with every button of the screen.
/// Portrait: tabs on the bottom row, actions as a grid above them.
/// Landscape: the block stays at the bottom, everything goes in one row.
class KrakenDock extends StatelessWidget {
  final List<DockTab> tabs;
  final int tab;
  final ValueChanged<int> onTab;
  final List<DockAction> actions;
  final bool expanded;
  final VoidCallback? onToggle;
  const KrakenDock({
    super.key,
    required this.tabs,
    required this.tab,
    required this.onTab,
    this.actions = const [],
    this.expanded = true,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final landscape = mq.size.width > mq.size.height;
    final bottom = math.max(mq.padding.bottom, 10.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 6, 10, bottom),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: landscape ? 1100 : 560),
          child: Container(
            decoration: BoxDecoration(
              color: K.ink.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: K.line),
            ),
            padding: const EdgeInsets.all(8),
            child: landscape ? _row() : _column(),
          ),
        ),
      ),
    );
  }

  Widget _tabs() => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < tabs.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _TabPill(tabs[i], i == tab, () => onTab(i)),
          ),
      ]);

  Widget _toggle() => onToggle == null || actions.isEmpty
      ? const SizedBox.shrink()
      : KRound(expanded ? Icons.keyboard_arrow_down_rounded : Icons.apps_rounded,
          tip: expanded ? 'Свернуть кнопки' : 'Все кнопки', onTap: onToggle, size: 44, bg: Colors.transparent);

  /// Portrait: a strict 5-column grid, so every button sits exactly above another;
  /// the last row holds the tabs (left columns) and the collapse button (last column).
  Widget _column() {
    const cols = 5;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / cols;
        Widget cell(Widget child) => SizedBox(width: w, child: Center(child: child));
        final bottom = <Widget>[
          for (var i = 0; i < tabs.length; i++) cell(_TabPill(tabs[i], i == tab, () => onTab(i))),
        ];
        while (bottom.length < cols - 1) {
          bottom.add(SizedBox(width: w));
        }
        bottom.add(cell(_toggle()));
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (expanded && actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              // full width, so a short row starts in the first column like the tabs below it
              child: SizedBox(
                width: c.maxWidth,
                child: Wrap(children: [
                  for (final a in actions) SizedBox(width: w, child: _ActionCell(a, labeled: true)),
                ]),
              ),
            ),
          Row(children: bottom),
        ]);
      }),
    );
  }

  Widget _row() {
    return SizedBox(
      height: 48,
      child: Row(children: [
        _tabs(),
        if (expanded && actions.isNotEmpty) ...[
          Container(width: 1, height: 28, color: K.line, margin: const EdgeInsets.symmetric(horizontal: 6)),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final a in actions)
                  Padding(padding: const EdgeInsets.only(right: 6), child: _ActionCell(a, labeled: false)),
              ],
            ),
          ),
        ] else
          const Spacer(),
        _toggle(),
      ]),
    );
  }
}

class _TabPill extends StatelessWidget {
  final DockTab t;
  final bool active;
  final VoidCallback onTap;
  const _TabPill(this.t, this.active, this.onTap);

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(color: active ? K.white : Colors.transparent, borderRadius: BorderRadius.circular(30)),
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Tooltip(message: t.label, child: Icon(t.icon, size: 22, color: active ? K.ink : K.muted)),
          ),
        ),
      );
}

class _ActionCell extends StatelessWidget {
  final DockAction a;
  final bool labeled;
  const _ActionCell(this.a, {required this.labeled});

  @override
  Widget build(BuildContext context) {
    final btn = KRound(a.icon,
        onTap: a.onTap, on: a.on, tip: labeled ? null : a.label, size: labeled ? 50 : 46,
        bg: a.on ? null : Colors.transparent);
    if (!labeled) return btn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        btn,
        const SizedBox(height: 5),
        Text(a.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: K.t(10.5, color: a.on ? K.lime : K.muted, w: FontWeight.w600)),
      ]),
    );
  }
}

/// Text field in the brand style.
InputDecoration kField(String label, {String? hint, Widget? suffix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
      filled: true,
      fillColor: K.panel2,
      labelStyle: K.t(14, color: K.muted),
      floatingLabelStyle: K.t(13, color: K.lilac, w: FontWeight.w600),
      hintStyle: K.t(14, color: const Color(0xFF5C5C6A)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: K.lilac, width: 1.5)),
    );

