import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

enum TouchMode { direct, touchpad }

class _Quality {
  final String label;
  final int width;
  final int q;
  const _Quality(this.label, this.width, this.q);
}

const _qualities = [
  _Quality('Эконом', 960, 45),
  _Quality('Норма', 1366, 60),
  _Quality('Высокое', 1920, 75),
];

class RemoteScreen extends StatefulWidget {
  final Api api;
  final ServerInfo info;
  final bool active;
  const RemoteScreen({super.key, required this.api, required this.info, required this.active});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  late final InputQueue _input = InputQueue(widget.api);

  // stream
  MemoryImage? _base;
  final List<(Patch, MemoryImage)> _patches = [];
  int _seq = 0;
  int _imgW = 1, _imgH = 1;
  bool _running = true;
  bool _offline = false;
  int _fps = 0;
  int _framesThisSecond = 0;
  Timer? _fpsTimer;
  int _quality = 1;
  int _monitor = 0;

  // view transform: screen = offset + scale * content
  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;

  // gestures
  TouchMode _mode = TouchMode.direct;
  bool _dragLock = false;
  bool _scrollMode = false;
  final Map<int, Offset> _pointers = {};
  Offset? _start;
  DateTime _startTime = DateTime.now();
  bool _moved = false;
  bool _consumed = false;
  bool _buttonDown = false;
  Timer? _longPress;
  Offset? _lastPos;
  // pinch
  double _pinchDist0 = 1;
  double _pinchScale0 = 1;
  Offset _pinchFocal0 = Offset.zero;
  Offset _pinchOffset0 = Offset.zero;

  // keyboard
  final _kbFocus = FocusNode();
  final _kb = TextEditingController(text: _sentinel);
  String _kbPrev = _sentinel;
  static const _sentinel = '  ';
  bool _showKeys = false;
  final Set<String> _mods = {};

  MonitorInfo get _mon => widget.info.monitors[_monitor.clamp(0, widget.info.monitors.length - 1)];

  @override
  void initState() {
    super.initState();
    // far away (via internet / VPN) → start with lighter picture
    _quality = widget.api.rttMs > 60 ? 0 : 1;
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _fps = _framesThisSecond);
      _framesThisSecond = 0;
    });
    _loop();
  }

  @override
  void dispose() {
    _running = false;
    _fpsTimer?.cancel();
    _longPress?.cancel();
    _kbFocus.dispose();
    _kb.dispose();
    super.dispose();
  }

  Future<void> _loop() async {
    while (_running) {
      if (!widget.active) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      try {
        final q = _qualities[_quality];
        final u = await widget.api.stream(
          after: _seq,
          monitor: _monitor,
          width: q.width,
          quality: q.q,
          keyframe: _base == null || _patches.length > 60,
        );
        if (!mounted) return;
        if (u != null) {
          await _apply(u);
        } else if (_offline) {
          setState(() => _offline = false);
        }
      } catch (_) {
        if (!mounted) return;
        setState(() => _offline = true);
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _apply(ScreenUpdate u) async {
    final imgs = [for (final p in u.patches) (p, MemoryImage(p.bytes))];
    // decode before showing, so nothing flickers
    await Future.wait(imgs.map((e) => precacheImage(e.$2, context).catchError((_) {})));
    if (!mounted) return;
    _seq = u.seq;
    _framesThisSecond++;
    setState(() {
      _offline = false;
      _imgW = u.width;
      _imgH = u.height;
      if (u.key) {
        // free decoded pictures that are no longer shown (iPhone has little memory for them)
        _base?.evict();
        for (final (_, img) in _patches) {
          img.evict();
        }
        _base = imgs.first.$2;
        _patches.clear();
      } else {
        _patches.addAll(imgs);
      }
    });
  }

  // ------------------------------------------------------------ geometry
  Rect get _fitted {
    final v = _viewport;
    final ar = _mon.width / _mon.height;
    double w = v.width, h = v.width / ar;
    if (h > v.height) {
      h = v.height;
      w = h * ar;
    }
    return Rect.fromLTWH((v.width - w) / 2, (v.height - h) / 2, w, h);
  }

  Offset _norm(Offset p) {
    final c = (p - _offset) / _scale;
    final r = _fitted;
    return Offset(((c.dx - r.left) / r.width).clamp(0.0, 1.0), ((c.dy - r.top) / r.height).clamp(0.0, 1.0));
  }

  void _clampView() {
    if (_scale <= 1.001) {
      _scale = 1;
      _offset = Offset.zero;
      return;
    }
    final v = _viewport;
    final minX = v.width - v.width * _scale, minY = v.height - v.height * _scale;
    _offset = Offset(_offset.dx.clamp(minX, 0.0), _offset.dy.clamp(minY, 0.0));
  }

  // ------------------------------------------------------------ sending
  void _send(Map<String, dynamic> ev) {
    ev['m'] = _monitor;
    _input.add(ev);
  }

  Map<String, dynamic> _at(String t, Offset p, [Map<String, dynamic>? extra]) {
    final n = _norm(p);
    return {'t': t, 'x': n.dx, 'y': n.dy, ...?extra};
  }

  void _click(Offset p, {String button = 'left'}) {
    if (_mode == TouchMode.direct) {
      _send(_at('click', p, {'b': button}));
    } else {
      _send({'t': 'click', 'b': button});
    }
  }

  // ------------------------------------------------------------ pointer handling
  void _onDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      final b = e.buttons == kSecondaryMouseButton
          ? 'right'
          : e.buttons == kMiddleMouseButton
              ? 'middle'
              : 'left';
      _send(_at('down', e.localPosition, {'b': b}));
      return;
    }
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      _start = e.localPosition;
      _lastPos = e.localPosition;
      _startTime = DateTime.now();
      _moved = false;
      _consumed = false;
      _longPress?.cancel();
      _longPress = Timer(const Duration(milliseconds: 550), () {
        if (_pointers.length == 1 && !_moved && !_dragLock) {
          _consumed = true;
          HapticFeedback.mediumImpact();
          _click(_start!, button: 'right');
        }
      });
    } else if (_pointers.length == 2) {
      _longPress?.cancel();
      _consumed = true;
      if (_buttonDown) {
        _send({'t': 'up', 'b': 'left'});
        _buttonDown = false;
      }
      final pts = _pointers.values.toList();
      _pinchDist0 = math.max(1, (pts[0] - pts[1]).distance);
      _pinchFocal0 = (pts[0] + pts[1]) / 2;
      _pinchScale0 = _scale;
      _pinchOffset0 = _offset;
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      _send(_at('move', e.localPosition));
      return;
    }
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_pointers.length >= 2) {
      final pts = _pointers.values.toList();
      final d = math.max(1.0, (pts[0] - pts[1]).distance);
      final focal = (pts[0] + pts[1]) / 2;
      setState(() {
        final ns = (_pinchScale0 * d / _pinchDist0).clamp(1.0, 6.0);
        _offset = focal - (_pinchFocal0 - _pinchOffset0) * (ns / _pinchScale0);
        _scale = ns;
        _clampView();
      });
      return;
    }
    if (_consumed || _start == null) return;
    if (!_moved && (e.localPosition - _start!).distance > 8) {
      _moved = true;
      _longPress?.cancel();
      if (_dragLock) {
        if (_mode == TouchMode.direct) _send(_at('move', _start!));
        _send({'t': 'down', 'b': 'left'});
        _buttonDown = true;
      }
    }
    if (!_moved) return;
    if (_scrollMode && !_dragLock) {
      // finger up/down scrolls the page under the finger (like on a phone)
      final delta = e.localPosition - (_lastPos ?? e.localPosition);
      if (_lastPos == _start && _mode == TouchMode.direct) _send(_at('move', _start!));
      final dy = (delta.dy * 6).round();
      if (dy != 0) _send({'t': 'scroll', 'dy': dy, 'dx': 0});
    } else if (_mode == TouchMode.direct) {
      _send(_at('move', e.localPosition));
    } else {
      final delta = e.localPosition - (_lastPos ?? e.localPosition);
      final k = _mon.width / (_fitted.width * _scale) * 1.6;
      final dx = (delta.dx * k).round(), dy = (delta.dy * k).round();
      if (dx != 0 || dy != 0) _send({'t': 'rel', 'dx': dx, 'dy': dy});
    }
    _lastPos = e.localPosition;
  }

  void _onUp(PointerEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      // which button was released is not reported; release all that were pressed
      _send(_at('up', e.localPosition, {'b': 'left'}));
      return;
    }
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) return;
    _longPress?.cancel();
    if (_buttonDown) {
      _send({'t': 'up', 'b': 'left'});
      _buttonDown = false;
    } else if (!_consumed && !_moved && _start != null && e is PointerUpEvent) {
      if (DateTime.now().difference(_startTime).inMilliseconds < 550) _click(_start!);
    }
    _start = null;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      _send(_at('move', e.localPosition));
      _send({'t': 'scroll', 'dy': (-e.scrollDelta.dy).round(), 'dx': e.scrollDelta.dx.round()});
    }
  }

  // ------------------------------------------------------------ keyboard
  void _toggleKeyboard() {
    if (_kbFocus.hasFocus) {
      _kbFocus.unfocus();
    } else {
      _kb.value = const TextEditingValue(text: _sentinel, selection: TextSelection.collapsed(offset: 2));
      _kbPrev = _sentinel;
      _kbFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    }
    setState(() {});
  }

  void _onKbChanged(String v) {
    int p = 0;
    while (p < v.length && p < _kbPrev.length && v[p] == _kbPrev[p]) {
      p++;
    }
    final deleted = _kbPrev.length - p;
    final added = v.substring(p);
    for (var i = 0; i < deleted; i++) {
      _send({'t': 'key', 'k': ['backspace']});
    }
    if (added.isNotEmpty) {
      if (_mods.isNotEmpty) {
        for (final ch in added.split('')) {
          _send({'t': 'key', 'k': [..._mods, ch.toLowerCase()]});
        }
        setState(_mods.clear);
      } else {
        _send({'t': 'text', 's': added});
      }
    }
    _kbPrev = v;
    final composing = _kb.value.composing;
    if ((v.length < 2 || v.length > 40) && (!composing.isValid || composing.isCollapsed)) {
      _kb.value = const TextEditingValue(text: _sentinel, selection: TextSelection.collapsed(offset: 2));
      _kbPrev = _sentinel;
    }
  }

  void _key(List<String> keys) {
    final all = [..._mods, ...keys];
    _send({'t': 'key', 'k': all});
    if (_mods.isNotEmpty) setState(_mods.clear);
    HapticFeedback.selectionClick();
  }

  // ------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Expanded(child: _screen()),
          if (_showKeys) _keysPanel(),
          _toolbar(),
        ],
      ),
    );
  }

  Widget _screen() {
    return LayoutBuilder(builder: (context, c) {
      _viewport = Size(c.maxWidth, c.maxHeight);
      final r = _fitted;
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              onPointerHover: (e) => _send(_at('move', e.localPosition)),
              onPointerSignal: _onSignal,
              child: ClipRect(
                child: Container(
                  color: Colors.black,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                      ..scaleByDouble(_scale, _scale, 1, 1),
                    child: Stack(children: [
                      Positioned.fromRect(
                        rect: r,
                        child: _base == null
                            ? const Center(child: CircularProgressIndicator())
                            : Stack(children: [
                                Positioned.fill(
                                  child: Image(image: _base!, gaplessPlayback: true, fit: BoxFit.fill,
                                      filterQuality: FilterQuality.medium),
                                ),
                                for (final (p, img) in _patches)
                                  Positioned(
                                    left: p.x * r.width / _imgW,
                                    top: p.y * r.height / _imgH,
                                    width: p.w * r.width / _imgW,
                                    height: p.h * r.height / _imgH,
                                    child: Image(image: img, fit: BoxFit.fill,
                                        filterQuality: FilterQuality.medium),
                                  ),
                              ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: _badge(_offline
                ? 'Нет связи…'
                : '${widget.info.name} · $_fps к/с${_scale > 1 ? ' · ×${_scale.toStringAsFixed(1)}' : ''}',
                _offline ? const Color(0xFFFF7B72) : Colors.white70),
          ),
          // hidden text field that receives the phone keyboard
          Positioned(
            left: 0,
            bottom: 0,
            width: 2,
            height: 2,
            child: Opacity(
              opacity: 0.01,
              child: TextField(
                focusNode: _kbFocus,
                controller: _kb,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                maxLines: null,
                onChanged: _onKbChanged,
                decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );

  Widget _toolBtn(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 44,
            height: 40,
            decoration: BoxDecoration(
              color: on ? const Color(0xFF3D8BFD).withValues(alpha: 0.25) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 22, color: on ? const Color(0xFF8AB8FF) : Colors.white70),
          ),
        ),
      );

  Widget _toolbar() {
    return Container(
      color: const Color(0xFF1A1E24),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _toolBtn(Icons.keyboard, 'Клавиатура', _toggleKeyboard, on: _kbFocus.hasFocus),
          _toolBtn(Icons.keyboard_command_key, 'Спец. клавиши', () => setState(() => _showKeys = !_showKeys),
              on: _showKeys),
          _toolBtn(_mode == TouchMode.direct ? Icons.touch_app : Icons.mouse,
              _mode == TouchMode.direct ? 'Режим: касание' : 'Режим: тачпад', () {
            setState(() => _mode = _mode == TouchMode.direct ? TouchMode.touchpad : TouchMode.direct);
            _snack(_mode == TouchMode.direct
                ? 'Касание: нажимайте прямо на нужное место'
                : 'Тачпад: водите пальцем, курсор двигается как на ноутбуке');
          }),
          _toolBtn(Icons.pan_tool_alt, 'Перетаскивание (зажать ЛКМ)', () {
            setState(() => _dragLock = !_dragLock);
            _snack(_dragLock ? 'Перетаскивание включено: ведите пальцем, чтобы тянуть' : 'Перетаскивание выключено');
          }, on: _dragLock),
          _toolBtn(Icons.swap_vert, 'Прокрутка пальцем', () {
            setState(() {
              _scrollMode = !_scrollMode;
              if (_scrollMode) _dragLock = false;
            });
            _snack(_scrollMode
                ? 'Прокрутка: ведите пальцем вверх/вниз, чтобы листать. Нажатия работают как обычно'
                : 'Прокрутка выключена');
          }, on: _scrollMode),
          _toolBtn(Icons.ads_click,'Правый клик (или долгое нажатие)', () => _send({'t': 'click', 'b': 'right'})),
          _toolBtn(Icons.zoom_out_map, 'Сбросить масштаб', () => setState(() {
                _scale = 1;
                _offset = Offset.zero;
              })),
          _toolBtn(Icons.high_quality, 'Качество: ${_qualities[_quality].label}', () {
            setState(() {
              _quality = (_quality + 1) % _qualities.length;
            });
            _snack('Качество: ${_qualities[_quality].label}');
          }),
          if (widget.info.monitors.length > 1)
            _toolBtn(Icons.monitor, 'Монитор ${_monitor + 1}', () {
              setState(() {
                _monitor = (_monitor + 1) % widget.info.monitors.length;
              });
              _snack('Монитор ${_monitor + 1}');
            }),
          _toolBtn(Icons.logout, 'Отключиться', () => Navigator.of(context).pop()),
        ]),
      ),
    );
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(milliseconds: 1400)));
  }

  Widget _chip(String label, VoidCallback onTap, {bool on = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: on ? const Color(0xFF3D8BFD) : const Color(0xFF2A303A),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      );

  Widget _mod(String name, String label) => _chip(label, () {
        setState(() => _mods.contains(name) ? _mods.remove(name) : _mods.add(name));
      }, on: _mods.contains(name));

  Widget _row(List<Widget> children) => SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 4), children: children),
      );

  Widget _keysPanel() {
    return Container(
      color: const Color(0xFF15191E),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [
        _row([
          _mod('ctrl', 'Ctrl'),
          _mod('alt', 'Alt'),
          _mod('shift', 'Shift'),
          _mod('win', 'Win'),
          _chip('Esc', () => _key(['esc'])),
          _chip('Tab', () => _key(['tab'])),
          _chip('Enter', () => _key(['enter'])),
          _chip('⌫', () => _key(['backspace'])),
          _chip('Del', () => _key(['delete'])),
          _chip('←', () => _key(['left'])),
          _chip('↑', () => _key(['up'])),
          _chip('↓', () => _key(['down'])),
          _chip('→', () => _key(['right'])),
          _chip('Home', () => _key(['home'])),
          _chip('End', () => _key(['end'])),
          _chip('PgUp', () => _key(['pageup'])),
          _chip('PgDn', () => _key(['pagedown'])),
          for (var i = 1; i <= 12; i++) _chip('F$i', () => _key(['f$i'])),
        ]),
        _row([
          _chip('Пуск', () => _key(['win'])),
          _chip('Копировать', () => _key(['ctrl', 'c'])),
          _chip('Вставить', () => _key(['ctrl', 'v'])),
          _chip('Вырезать', () => _key(['ctrl', 'x'])),
          _chip('Отменить', () => _key(['ctrl', 'z'])),
          _chip('Выделить всё', () => _key(['ctrl', 'a'])),
          _chip('Сохранить', () => _key(['ctrl', 's'])),
          _chip('Alt+Tab', () => _key(['alt', 'tab'])),
          _chip('Закрыть окно', () => _key(['alt', 'f4'])),
          _chip('Рабочий стол', () => _key(['win', 'd'])),
          _chip('Проводник', () => _key(['win', 'e'])),
          _chip('Выполнить', () => _key(['win', 'r'])),
          _chip('Диспетчер задач', () => _key(['ctrl', 'shift', 'esc'])),
          _chip('Смена языка', () => _key(['alt', 'shift'])),
          _chip('🔉', () => _key(['volumedown'])),
          _chip('🔊', () => _key(['volumeup'])),
          _chip('🔇', () => _key(['volumemute'])),
          _chip('⏯', () => _key(['mediaplay'])),
        ]),
      ]),
    );
  }
}
