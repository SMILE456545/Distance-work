import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../api.dart';
import '../kraken/kraken.dart';

/// Claude Code running in a real console on the PC, shown here exactly as in
/// Windows Terminal: logo, colors, menus, questions.
class ClaudeSession {
  final Api api;
  final String cwd;
  final terminal = Terminal(maxLines: 5000);
  final controller = TerminalController();
  String? id;
  bool exited = false;
  String? error;
  VoidCallback? onChange;

  int _pos = 0;
  bool _starting = false;
  bool _closed = false;
  String _pending = '';
  bool _sending = false;
  Timer? _resizeTimer;

  ClaudeSession(this.api, this.cwd) {
    terminal.onOutput = _send;
    terminal.onResize = (cols, rows, _, _) {
      if (id == null) {
        _start(cols, rows);
      } else {
        // the phone keyboard opening/closing resizes many times in a row
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 250), () => api.ptyResize(id!, cols, rows));
      }
    };
  }

  Future<void> _start(int cols, int rows) async {
    if (_starting || _closed) return;
    _starting = true;
    terminal.write('\x1b[90mЗапускаю Claude Code в $cwd…\x1b[0m\r\n');
    try {
      final (sid, _, _) = await api.ptyStart(cwd: cwd, cols: cols, rows: rows);
      id = sid;
      terminal.write('\x1b[2J\x1b[H');
      _loop();
    } catch (e) {
      error = '$e';
      exited = true;
      terminal.write('\r\n\x1b[31mНе запустилось: $e\x1b[0m\r\n');
    }
    onChange?.call();
  }

  Future<void> _loop() async {
    var fails = 0;
    while (!_closed && id != null) {
      try {
        final (data, end, ended) = await api.ptyRead(id!, _pos);
        fails = 0;
        // ⎿ (Claude's answer connector) exists in no free font; └ looks the same
        if (data.isNotEmpty) terminal.write(data.replaceAll('⎿', '└'));
        _pos = end;
        if (ended) {
          exited = true;
          terminal.write('\r\n\x1b[90m[Claude Code завершён — закройте вкладку]\x1b[0m\r\n');
          onChange?.call();
          return;
        }
      } on PtyGone {
        exited = true;
        terminal.write('\r\n\x1b[90m[Сессия на компьютере закрыта]\x1b[0m\r\n');
        onChange?.call();
        return;
      } catch (_) {
        // no connection for a moment: try again, a little later each time
        fails++;
        await Future<void>.delayed(Duration(milliseconds: 500 * fails.clamp(1, 8)));
      }
    }
  }

  /// Keys and text go to the PC in order, merged while a request is on its way.
  void _send(String data) {
    if (id == null || exited) return;
    _pending += data;
    _pump();
  }

  Future<void> _pump() async {
    if (_sending || _pending.isEmpty) return;
    _sending = true;
    while (_pending.isNotEmpty && !_closed) {
      final chunk = _pending;
      _pending = '';
      try {
        await api.ptyWrite(id!, chunk);
      } on PtyGone {
        break;
      } catch (_) {
        _pending = chunk + _pending; // retry
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
    _sending = false;
  }

  /// Text typed into Claude's prompt (e.g. paths of sent files).
  void type(String text) => _send(text);

  void kill() {
    _closed = true;
    _resizeTimer?.cancel();
    if (id != null) api.ptyKill(id!);
  }
}

/// The console view + a row of keys a phone keyboard doesn't have + «Файл».
class ClaudeView extends StatefulWidget {
  final ClaudeSession session;
  final Color bg, fg;
  final double fontSize;

  /// Shown right above the key row (the program chips, as in the PowerShell tab).
  final Widget? above;
  const ClaudeView(
      {super.key, required this.session, required this.bg, required this.fg, required this.fontSize, this.above});

  @override
  State<ClaudeView> createState() => _ClaudeViewState();
}

class _ClaudeViewState extends State<ClaudeView> {
  final _focus = FocusNode();
  String? _status; // «Отправляю фото.jpg…»
  bool _ctrl = false;

  ClaudeSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _s.onChange = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void didUpdateWidget(ClaudeView old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) {
      old.session.onChange = null;
      _s.onChange = () {
        if (mounted) setState(() {});
      };
    }
  }

  @override
  void dispose() {
    _s.onChange = null;
    _focus.dispose();
    super.dispose();
  }

  void _key(String seq) {
    HapticFeedback.selectionClick();
    _s.type(seq);
  }

  Future<void> _sendFiles() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    } catch (e) {
      if (mounted) setState(() => _status = 'Не открылся выбор файлов: $e');
      return;
    }
    if (res == null || res.files.isEmpty) return;
    final paths = <String>[];
    for (final f in res.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      setState(() => _status = 'Отправляю ${f.name}…');
      try {
        paths.add(await _s.api.upload(f.name, bytes));
      } catch (e) {
        if (mounted) setState(() => _status = 'Не отправился ${f.name}: $e');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _status = paths.length == 1 ? 'Файл на ПК: ${paths.first}' : 'Файлов на ПК: ${paths.length}');
    // the paths go into Claude's prompt; the message is written around them
    _s.type('${paths.join(' ')} ');
    Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _status = null);
    });
  }

  TerminalTheme get _theme => TerminalTheme(
        cursor: widget.fg.withValues(alpha: 0.8),
        selection: widget.fg.withValues(alpha: 0.3),
        foreground: widget.fg,
        background: widget.bg,
        black: const Color(0xFF0C0C0C),
        red: const Color(0xFFC50F1F),
        green: const Color(0xFF13A10E),
        yellow: const Color(0xFFC19C00),
        blue: const Color(0xFF0037DA),
        magenta: const Color(0xFF881798),
        cyan: const Color(0xFF3A96DD),
        white: const Color(0xFFCCCCCC),
        brightBlack: const Color(0xFF767676),
        brightRed: const Color(0xFFE74856),
        brightGreen: const Color(0xFF16C60C),
        brightYellow: const Color(0xFFF9F1A5),
        brightBlue: const Color(0xFF3B78FF),
        brightMagenta: const Color(0xFFB4009E),
        brightCyan: const Color(0xFF61D6D6),
        brightWhite: const Color(0xFFF2F2F2),
        searchHitBackground: const Color(0xFFFFFF2B),
        searchHitBackgroundCurrent: const Color(0xFF31FF26),
        searchHitForeground: const Color(0xFF000000),
      );

  Widget _btn(String label, VoidCallback onTap, {IconData? icon, bool on = false}) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: on ? widget.fg : Color.lerp(widget.bg, widget.fg, 0.12),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              height: 34,
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: on ? widget.bg : widget.fg),
                  if (label.isNotEmpty) const SizedBox(width: 5),
                ],
                if (label.isNotEmpty)
                  Text(label, style: K.code(12.5, color: on ? widget.bg : widget.fg, w: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      );

  /// Ctrl + letter: one tap on «Ctrl», then a key on the row (C, D, …).
  void _ctrlKey(String letter) {
    setState(() => _ctrl = false);
    _key(String.fromCharCode(letter.toUpperCase().codeUnitAt(0) - 64));
  }

  Widget _keys() => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          children: [
            _btn('Файл', _sendFiles, icon: Icons.attach_file_rounded),
            _btn('Esc', () => _key('\x1b')),
            _btn('Tab', () => _key('\t')),
            _btn('⇧Tab', () => _key('\x1b[Z')),
            _btn('', () => _key('\x1b[A'), icon: Icons.keyboard_arrow_up_rounded),
            _btn('', () => _key('\x1b[B'), icon: Icons.keyboard_arrow_down_rounded),
            _btn('', () => _key('\x1b[D'), icon: Icons.keyboard_arrow_left_rounded),
            _btn('', () => _key('\x1b[C'), icon: Icons.keyboard_arrow_right_rounded),
            _btn('Enter', () => _key('\r'), icon: Icons.keyboard_return_rounded),
            if (_ctrl) ...[
              _btn('C', () => _ctrlKey('c'), on: true),
              _btn('D', () => _ctrlKey('d'), on: true),
              _btn('L', () => _ctrlKey('l'), on: true),
              _btn('R', () => _ctrlKey('r'), on: true),
              _btn('✕', () => setState(() => _ctrl = false)),
            ] else
              _btn('Ctrl', () => setState(() => _ctrl = true)),
            _btn('/', () => _key('/')),
            _btn('@', () => _key('@')),
            _btn('', () => _focus.requestFocus(), icon: Icons.keyboard_rounded),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: TerminalView(
          _s.terminal,
          controller: _s.controller,
          focusNode: _focus,
          theme: _theme,
          textStyle: TerminalStyle(
            fontSize: widget.fontSize,
            fontFamily: K.mono,
            // Claude Code's ⏺ ✻ ✳ ✓ … are not in JetBrains Mono
            fontFamilyFallback: const ['TermSymbols', 'TermMath', 'Noto Color Emoji', 'Apple Color Emoji'],
          ),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
          keyboardType: TextInputType.text,
          deleteDetection: true,
          keyboardAppearance: Brightness.dark,
        ),
      ),
      if (_status != null)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Text(_status!,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: K.code(11.5, color: widget.fg.withValues(alpha: 0.75))),
        ),
      Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: widget.fg.withValues(alpha: 0.12)))),
        child: Column(children: [
          if (widget.above != null) Padding(padding: const EdgeInsets.only(top: 8), child: widget.above!),
          _keys(),
        ]),
      ),
    ]);
  }
}
