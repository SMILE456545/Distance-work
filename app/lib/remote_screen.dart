import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'kraken/kraken.dart';
import 'main.dart' show homeTabs;
import 'screen/fullscreen.dart';
import 'screen/lock_panel.dart';
import 'sound/unlock.dart';

class _Quality {
  final String label;
  final int width;
  final int q; // JPEG quality (fallback mode)
  final int fps; // video frames per second
  final int br; // video bitrate limit, bit/s
  const _Quality(this.label, this.width, this.q, this.fps, this.br);
}

const _qualities = [
  _Quality('Эконом', 960, 45, 20, 1200000),
  _Quality('Норма', 1366, 60, 30, 3000000),
  _Quality('Высокое', 1920, 75, 30, 6000000),
  _Quality('Максимум', 1920, 85, 60, 16000000), // games: full size, 60 frames
];

class RemoteScreen extends StatefulWidget {
  final Api api;
  final ServerInfo info;
  final bool active;
  final int tab;
  final ValueChanged<int> onTab;
  const RemoteScreen({
    super.key,
    required this.api,
    required this.info,
    required this.active,
    required this.tab,
    required this.onTab,
  });

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

  // fast video (H.264 over WebRTC); the picture stream is the fallback
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  bool _rtcOn = false; // video frames are being shown
  bool _rtcFailed = false; // gave up -> picture stream
  bool _rtcStarting = false;
  int _rtcRetries = 0;
  Timer? _rtcWatchdog;
  Timer? _statsTimer;
  bool _sound = true; // PC sound on the phone
  bool _soundUnlocked = false; // browsers need one tap before sound can play

  // view transform: screen = offset + scale * content
  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;

  // gestures
  // everything works at once: tap = click, double tap = double click, finger = scroll,
  // hold = menu (copy / paste…), hold + move = select text / drag, two fingers = zoom
  bool _held = false; // the finger was held still: left button is down
  bool _full = false; // full screen, landscape, only the menu button
  bool _panelOpen = true; // the dock's button grid; collapsed = just the tabs
  final Map<int, Offset> _pointers = {};
  final Map<int, DateTime> _pointerSeen = {}; // last down/move of each finger
  Offset? _start;
  DateTime _startTime = DateTime.now();
  bool _moved = false;
  bool _consumed = false;
  bool _buttonDown = false;
  Timer? _longPress;
  Offset? _lastPos;
  // menu after a long press (like the phone's own «Копировать / Вставить»)
  Offset? _menuAt;
  // double tap = double click: the second tap clicks exactly where the first one did
  Offset? _tapPos;
  DateTime _tapTime = DateTime(2000);
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
  final Set<String> _mods = {};
  bool _kbSeen = false; // the phone keyboard has actually appeared since focusing

  // Windows lock screen: a PIN field is shown over the picture
  bool _locked = false;
  bool _unlockAgent = false;
  Timer? _lockTimer;
  AppLifecycleListener? _life;

  Future<void> _checkLock() async {
    if (!mounted || !widget.active) return;
    try {
      final (locked, agent) = await widget.api.lockState();
      if (mounted && (locked != _locked || agent != _unlockAgent)) {
        if (locked && _kbFocus.hasFocus) _closeKeyboard();
        setState(() {
          _locked = locked;
          _unlockAgent = agent;
        });
      }
    } catch (_) {
      // an older server without /api/lock, or no connection: just no panel
    }
  }

  MonitorInfo get _mon => widget.info.monitors[_monitor.clamp(0, widget.info.monitors.length - 1)];

  @override
  void initState() {
    super.initState();
    // video adapts to the connection by itself; the picture stream needs a lighter start far away
    _quality = _qualities.length - 1; // maximum speed and quality
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_rtcOn && _fps != _framesThisSecond) setState(() => _fps = _framesThisSecond);
      _framesThisSecond = 0;
    });
    _kbFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _checkLock();
    _lockTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkLock());
    // leaving Safari mid-touch loses the «finger up»
    _life = AppLifecycleListener(onHide: _resetGesture, onShow: _resetGesture);
    _renderer.initialize().then((_) {
      _renderer.onResize = () {
        if (mounted && _renderer.videoWidth > 0 && !_rtcOn) {
          _rtcWatchdog?.cancel();
          _rtcRetries = 0;
          setState(() {
            _rtcOn = true;
            _offline = false;
          });
        }
      };
      if (widget.active) _startRtc();
    });
    _loop();
  }

  @override
  void didUpdateWidget(RemoteScreen old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active) {
      _checkLock();
      if (_pc == null && !_rtcFailed) {
        _startRtc();
      } else {
        _dcSend({'t': 'resume'});
      }
    } else {
      // the Terminal tab is open — don't spend mobile traffic on the picture
      _dcSend({'t': 'pause'});
      if (_kbFocus.hasFocus) _closeKeyboard();
      _resetGesture();
    }
  }

  @override
  void dispose() {
    _running = false;
    _rtcWatchdog?.cancel();
    _statsTimer?.cancel();
    _pc?.close();
    _renderer.dispose();
    _fpsTimer?.cancel();
    _lockTimer?.cancel();
    _life?.dispose();
    _longPress?.cancel();
    if (_full) exitFullscreen();
    _kbFocus.dispose();
    _kb.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ fast video (WebRTC)
  Future<void> _startRtc() async {
    if (_rtcStarting || _pc != null || _rtcFailed || !mounted) return;
    _rtcStarting = true;
    try {
      final pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      // PC sound
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      final dc = await pc.createDataChannel('input', RTCDataChannelInit()..ordered = true);
      dc.onDataChannelState = (st) {
        if (st == RTCDataChannelState.RTCDataChannelOpen) {
          _dc = dc;
          if (!widget.active) _dcSend({'t': 'pause'});
        } else if (st == RTCDataChannelState.RTCDataChannelClosed) {
          if (identical(_dc, dc)) _dc = null;
        }
      };
      pc.onTrack = (e) async {
        if (e.track.kind == 'audio') {
          e.track.enabled = _sound;
          // same stream as the picture — the renderer plays it; a separate one is played here
          if (e.streams.isNotEmpty && identical(_renderer.srcObject, e.streams.first)) return;
          if (e.streams.isNotEmpty && _renderer.srcObject == null) _renderer.srcObject = e.streams.first;
          return;
        }
        if (e.track.kind != 'video') return;
        if (e.streams.isNotEmpty) {
          _renderer.srcObject = e.streams.first;
        } else {
          final st = await createLocalMediaStream('remotedesk');
          await st.addTrack(e.track);
          _renderer.srcObject = st;
        }
      };
      pc.onConnectionState = (st) {
        if (!identical(_pc, pc)) return;
        if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            st == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _rtcDrop();
        } else if (mounted) {
          setState(() => _offline = st == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
        }
      };
      await pc.setLocalDescription(await pc.createOffer({}));
      // the laptop's server doesn't take addresses one by one — collect them first
      final sw = Stopwatch()..start();
      while (pc.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete &&
          sw.elapsedMilliseconds < 2500) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final local = await pc.getLocalDescription();
      final q = _qualities[_quality];
      final ans = await widget.api.rtc({
        'sdp': local!.sdp,
        'type': local.type,
        'w': q.width,
        'fps': q.fps,
        'br': q.br,
        'm': _monitor,
        'sound': _sound,
      });
      if (!identical(_pc, pc)) return;
      await pc.setRemoteDescription(RTCSessionDescription(ans['sdp'] as String, ans['type'] as String));
      _rtcWatchdog?.cancel();
      _rtcWatchdog = Timer(const Duration(seconds: 12), () {
        if (!_rtcOn && identical(_pc, pc)) _rtcDrop(giveUp: true);
      });
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readFps(pc));
    } catch (_) {
      _rtcDrop(giveUp: true);
    } finally {
      _rtcStarting = false;
    }
  }

  Future<void> _readFps(RTCPeerConnection pc) async {
    if (!_rtcOn || !identical(_pc, pc) || !widget.active) return;
    try {
      for (final r in await pc.getStats()) {
        if (r.type == 'inbound-rtp' && (r.values['kind'] ?? r.values['mediaType']) == 'video') {
          final f = r.values['framesPerSecond'];
          if (f is num) _fps = f.round(); // not shown while video runs — no rebuild needed
        }
      }
    } catch (_) {}
  }

  void _rtcDrop({bool giveUp = false}) {
    final pc = _pc;
    _pc = null;
    _dc = null;
    _rtcWatchdog?.cancel();
    _statsTimer?.cancel();
    pc?.close();
    if (!mounted) return;
    final wasOn = _rtcOn;
    setState(() => _rtcOn = false);
    if (!giveUp && _rtcRetries < 3) {
      _rtcRetries++;
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && widget.active) _startRtc();
      });
      return;
    }
    setState(() {
      _rtcFailed = true;
      if (widget.api.rttMs > 60) _quality = 0; // far away (internet / VPN) → lighter pictures
    });
    _snack(
      wasOn
          ? 'Видео прервалось — переключаюсь на обычный режим'
          : 'Быстрое видео не подключилось — работает обычный режим',
    );
  }

  void _dcSend(Map<String, dynamic> ev) {
    final dc = _dc;
    if (dc == null) return;
    try {
      dc.send(RTCDataChannelMessage(jsonEncode(ev)));
    } catch (_) {}
  }

  void _sendQuality() {
    final q = _qualities[_quality];
    _dcSend({'t': 'cfg', 'w': q.width, 'fps': q.fps, 'br': q.br, 'm': _monitor});
  }

  // ------------------------------------------------------------ picture stream (fallback)
  Future<void> _loop() async {
    while (_running) {
      if (!widget.active || !_rtcFailed) {
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
    // over the video connection events skip HTTP requests entirely;
    // a channel that silently died (Safari in background, network hiccup) must not
    // swallow the input — then it goes over HTTP
    final dc = _dc;
    if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        dc.send(RTCDataChannelMessage(jsonEncode(ev)));
        return;
      } catch (_) {
        if (identical(_dc, dc)) _dc = null;
      }
    }
    _input.add(ev);
  }

  /// Forget all touches (a lost «finger up» left a ghost finger: every new touch
  /// was taken for a two-finger zoom and the cursor stopped moving).
  void _resetGesture() {
    _longPress?.cancel();
    if (_buttonDown) {
      _send({'t': 'up', 'b': 'left'});
      _buttonDown = false;
    }
    _pointers.clear();
    _pointerSeen.clear();
    _menuAt = null;
    _start = null;
    _held = false;
    _moved = false;
    _consumed = false;
  }

  Map<String, dynamic> _at(String t, Offset p, [Map<String, dynamic>? extra]) {
    final n = _norm(p);
    return {'t': t, 'x': n.dx, 'y': n.dy, ...?extra};
  }

  void _click(Offset p, {String button = 'left'}) => _send(_at('click', p, {'b': button}));

  // ------------------------------------------------------------ pointer handling
  void _onDown(PointerDownEvent e) {
    if (!_soundUnlocked && _sound) {
      _soundUnlocked = true;
      unlockSound();
    }
    if (e.kind == PointerDeviceKind.mouse) {
      final b = e.buttons == kSecondaryMouseButton
          ? 'right'
          : e.buttons == kMiddleMouseButton
          ? 'middle'
          : 'left';
      _send(_at('down', e.localPosition, {'b': b}));
      return;
    }
    // iOS sometimes never reports a finger lifting (system gesture, notification,
    // keyboard, edge of the screen). Fingers silent for a while are ghosts — drop them.
    final now = DateTime.now();
    final ghosts = _pointerSeen.entries
        .where((p) => now.difference(p.value).inMilliseconds > 1200)
        .map((p) => p.key)
        .toList();
    if (ghosts.isNotEmpty) {
      _resetGesture();
    }
    _pointers[e.pointer] = e.localPosition;
    _pointerSeen[e.pointer] = now;
    if (_menuAt != null) {
      // a touch outside the menu only closes it (as on the phone)
      setState(() => _menuAt = null);
      _start = null;
      _consumed = true;
      return;
    }
    if (_pointers.length == 1) {
      _start = e.localPosition;
      _lastPos = e.localPosition;
      _startTime = DateTime.now();
      _moved = false;
      _consumed = false;
      _held = false;
      _longPress?.cancel();
      // finger held still: press the left button there; moving now selects text / drags,
      // letting go shows the menu «Копировать / Вставить…»
      _longPress = Timer(const Duration(milliseconds: 450), () {
        if (_pointers.length == 1 && !_moved) {
          _held = true;
          HapticFeedback.mediumImpact();
          _send(_at('move', _start!));
          _send({'t': 'down', 'b': 'left'});
          _buttonDown = true;
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
    _pointerSeen[e.pointer] = DateTime.now();

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
    }
    if (!_moved) return;
    if (_held) {
      // held, then moved: the button is down — select text / drag
      _send(_at('move', e.localPosition));
    } else {
      // plain swipe scrolls the page under the finger (like on a phone)
      final delta = e.localPosition - (_lastPos ?? e.localPosition);
      if (_lastPos == _start) _send(_at('move', _start!));
      final dy = (delta.dy * 6).round(), dx = (-delta.dx * 6).round();
      if (dy != 0 || dx != 0) _send({'t': 'scroll', 'dy': dy, 'dx': dx});
    }
    _lastPos = e.localPosition;
  }

  void _onUp(PointerEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      // which button was released is not reported; release all that were pressed
      _send(_at('up', e.localPosition, {'b': 'left'}));
      return;
    }
    _pointerSeen.remove(e.pointer);
    if (_pointers.remove(e.pointer) == null) return; // already dropped as a ghost
    if (_pointers.isNotEmpty) return;
    _longPress?.cancel();
    if (_buttonDown) {
      _send({'t': 'up', 'b': 'left'});
      _buttonDown = false;
      if (_held && e is PointerUpEvent) setState(() => _menuAt = _moved ? (_lastPos ?? _start!) : _start!);
    } else if (!_consumed && !_moved && _start != null && e is PointerUpEvent) {
      final now = DateTime.now();
      if (now.difference(_startTime).inMilliseconds < 550) {
        final prev = _tapPos;
        if (prev != null && now.difference(_tapTime).inMilliseconds < 450 && (prev - _start!).distance < 40) {
          _click(prev); // second click on the same spot: Windows sees a double click
          _tapPos = null;
        } else {
          _click(_start!);
          _tapPos = _start;
          _tapTime = now;
        }
      }
    }
    _start = null;
    _held = false;
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
      _closeKeyboard();
    } else {
      _openKeyboard();
    }
  }

  void _openKeyboard() {
    _kb.value = const TextEditingValue(text: _sentinel, selection: TextSelection.collapsed(offset: 2));
    _kbPrev = _sentinel;
    _kbSeen = false;
    if (_kbFocus.hasFocus) {
      // focused but the phone hid its keyboard — reconnect so the browser shows it again
      _kbFocus.unfocus();
    }
    _kbFocus.requestFocus();
    SystemChannels.textInput.invokeMethod('TextInput.show');
    setState(() {});
  }

  void _closeKeyboard() {
    _kbSeen = false;
    _kbFocus.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() {});
  }

  /// The phone keyboard was closed by the system (swipe down, «Готово»…) while the
  /// hidden field kept focus — drop the focus so the dock comes back.
  void _watchKeyboard(double inset) {
    if (!_kbFocus.hasFocus) return;
    if (inset > 80) {
      _kbSeen = true;
    } else if (_kbSeen) {
      _kbSeen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _kbFocus.hasFocus && MediaQuery.viewInsetsOf(context).bottom <= 80) _closeKeyboard();
      });
    }
  }

  void _onKbChanged(String v) {
    int p = 0;
    while (p < v.length && p < _kbPrev.length && v[p] == _kbPrev[p]) {
      p++;
    }
    final deleted = _kbPrev.length - p;
    final added = v.substring(p);
    for (var i = 0; i < deleted; i++) {
      _send({
        't': 'key',
        'k': ['backspace'],
      });
    }
    if (added.isNotEmpty) {
      if (_mods.isNotEmpty) {
        for (final ch in added.split('')) {
          _send({
            't': 'key',
            'k': [..._mods, ch.toLowerCase()],
          });
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
    _watchKeyboard(MediaQuery.viewInsetsOf(context).bottom);
    if (_full) return _fullView();
    return Container(
      color: K.ink,
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(child: _screen()),
                if (_kbFocus.hasFocus)
                  // key carousel right above the phone keyboard
                  _kbCarousel()
                else ...[
                  KrakenDock(
                    tabs: homeTabs,
                    tab: widget.tab,
                    onTab: widget.onTab,
                    actions: _actions(),
                    expanded: _panelOpen,
                    onToggle: () => setState(() => _panelOpen = !_panelOpen),
                  ),
                ],
              ],
            ),
            // hidden text field that receives the phone keyboard — kept away from the video
            Positioned(left: 0, bottom: 0, width: 2, height: 2, child: _hiddenField()),
          ],
        ),
      ),
    );
  }

  /// Full screen: the picture fills a landscape screen, only the menu button stays.
  /// If the phone is held upright (iPhone Safari can't turn the page), the picture is turned.
  Widget _fullView() {
    final size = MediaQuery.sizeOf(context);
    final view = Stack(
      children: [
        Positioned.fill(child: _screen()),
        Positioned(
          left: 12,
          top: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleFull,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: K.ink.withValues(alpha: 0.55), shape: BoxShape.circle),
              child: const Icon(Icons.menu_rounded, color: Colors.white, size: 22),
            ),
          ),
        ),
      ],
    );
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(child: size.height > size.width ? RotatedBox(quarterTurns: 1, child: view) : view),
          Positioned(left: 0, bottom: 0, width: 2, height: 2, child: _hiddenField()),
        ],
      ),
    );
  }

  void _toggleFull() {
    if (_kbFocus.hasFocus) _closeKeyboard();
    _resetGesture();
    setState(() {
      _full = !_full;
      _scale = 1;
      _offset = Offset.zero;
    });
    _full ? enterFullscreen() : exitFullscreen();
  }

  Widget _hiddenField() => Opacity(
    opacity: 0.01,
    child: TextField(
      focusNode: _kbFocus,
      controller: _kb,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.multiline,
      maxLines: null,
      onChanged: _onKbChanged,
      // keep the keyboard open while tapping on the remote screen;
      // it is closed with the keyboard button
      onTapOutside: (_) {},
      decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
    ),
  );

  Widget _screen() {
    return LayoutBuilder(
      builder: (context, c) {
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
                    color: K.ink,
                    child: Transform(
                      transform: Matrix4.identity()
                        ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                        ..scaleByDouble(_scale, _scale, 1, 1),
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: r,
                            child: _rtcOn
                                ? RTCVideoView(
                                    _renderer,
                                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                                    filterQuality: FilterQuality.medium,
                                  )
                                : _base == null
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text('Подключаю экран…', style: K.t(14, color: K.muted)),
                                      ],
                                    ),
                                  )
                                : Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Image(
                                          image: _base!,
                                          gaplessPlayback: true,
                                          fit: BoxFit.fill,
                                          filterQuality: FilterQuality.medium,
                                        ),
                                      ),
                                      for (final (p, img) in _patches)
                                        Positioned(
                                          left: p.x * r.width / _imgW,
                                          top: p.y * r.height / _imgH,
                                          width: p.w * r.width / _imgW,
                                          height: p.h * r.height / _imgH,
                                          child: Image(
                                            image: img,
                                            fit: BoxFit.fill,
                                            filterQuality: FilterQuality.medium,
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // status only while connecting / offline: anything over the running video slows the browser
            if (!_rtcOn || _offline)
              Positioned(
                left: _full ? 64 : 10,
                top: _full ? 20 : 10,
                child: IgnorePointer(
                  child: _badge(
                    _offline
                        ? 'Нет связи…'
                        : '${widget.info.name} · $_fps к/с${_rtcOn ? ' · видео' : ''}${_scale > 1 ? ' · ×${_scale.toStringAsFixed(1)}' : ''}',
                    _offline,
                  ),
                ),
              ),
            if (_menuAt != null) _pressMenu(_menuAt!),
            if (_locked)
              Positioned.fill(
                child: LockPanel(
                  api: widget.api,
                  agent: _unlockAgent,
                  onUnlocked: () => setState(() => _locked = false),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _badge(String text, bool bad) => Container(
    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
    decoration: BoxDecoration(color: K.ink.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(30)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: bad ? K.coral : K.lime, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: K.t(12, color: bad ? K.coral : K.white, w: FontWeight.w600),
        ),
      ],
    ),
  );

  void _toggleSound() {
    setState(() => _sound = !_sound);
    _soundUnlocked = true;
    unlockSound(muted: !_sound); // called from a tap, so the browser allows it
    _renderer.muted = !_sound;
    final stream = _renderer.srcObject;
    if (stream != null) {
      for (final t in stream.getAudioTracks()) {
        t.enabled = _sound;
      }
    }
    _dcSend({'t': 'sound', 'on': _sound});
    _snack(_sound ? 'Звук с компьютера включён' : 'Звук выключен');
  }

  List<DockAction> _actions() => [
    DockAction(_sound ? Icons.volume_up_rounded : Icons.volume_off_rounded, 'Звук', _toggleSound, on: _sound),
    DockAction(Icons.keyboard_rounded, 'Клавиатура', _toggleKeyboard, on: _kbFocus.hasFocus),
    DockAction(Icons.fullscreen_rounded, 'Весь экран', _toggleFull),
    DockAction(Icons.high_quality_rounded, _qualities[_quality].label, () {
      setState(() => _quality = (_quality + 1) % _qualities.length);
      _sendQuality();
      _snack('Качество: ${_qualities[_quality].label}');
    }),
    if (widget.info.monitors.length > 1)
      DockAction(Icons.monitor_rounded, 'Монитор ${_monitor + 1}', () {
        setState(() => _monitor = (_monitor + 1) % widget.info.monitors.length);
        _sendQuality();
        _snack('Монитор ${_monitor + 1}');
      }),
    DockAction(Icons.logout_rounded, 'Выйти', () => Navigator.of(context).pop()),
  ];

  void _snack(String s) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(milliseconds: 1400)));
  }

  Widget _chip(String label, VoidCallback onTap, {bool on = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: KChip(label, onTap: onTap, bg: on ? K.lime : K.panel2, fg: on ? K.ink : K.white),
  );

  Widget _mod(String name, String label) => _chip(label, () {
    setState(() => _mods.contains(name) ? _mods.remove(name) : _mods.add(name));
  }, on: _mods.contains(name));

  Widget _row(List<Widget> children) => SizedBox(
    height: 44,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      children: children,
    ),
  );

  /// One scrollable row of keys shown while the phone keyboard is open.
  /// TextFieldTapRegion keeps the keyboard open when these keys are tapped.
  Widget _kbCarousel() {
    return TextFieldTapRegion(
      child: Container(
        color: K.ink,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _row([
          _chip('⌨ Клавиатура', _openKeyboard),
          _chip('✕ Скрыть', _closeKeyboard),
          _chip('Enter ⏎', () => _key(['enter'])),
          _chip('⌫', () => _key(['backspace'])),
          _chip('Esc', () => _key(['esc'])),
          _chip('Tab', () => _key(['tab'])),
          _chip('←', () => _key(['left'])),
          _chip('→', () => _key(['right'])),
          _chip('↑', () => _key(['up'])),
          _chip('↓', () => _key(['down'])),
          _mod('ctrl', 'Ctrl'),
          _mod('alt', 'Alt'),
          _mod('shift', 'Shift'),
          _mod('win', 'Win'),
          _chip('Del', () => _key(['delete'])),
          _chip('Копировать', () => _key(['ctrl', 'c'])),
          _chip('Вставить', () => _key(['ctrl', 'v'])),
          _chip('Отменить', () => _key(['ctrl', 'z'])),
          _chip('Выделить всё', () => _key(['ctrl', 'a'])),
          _chip('Сохранить', () => _key(['ctrl', 's'])),
          _chip('Home', () => _key(['home'])),
          _chip('End', () => _key(['end'])),
          _chip('Alt+Tab', () => _key(['alt', 'tab'])),
          _chip('Смена языка', () => _key(['alt', 'shift'])),
          _chip('F5', () => _key(['f5'])),
          _chip('Пуск', () => _key(['win'])),
        ]),
      ),
    );
  }

  /// Menu after a long press: the same actions as the PC's own menu, sent as key presses.
  Widget _pressMenu(Offset at) {
    void act(VoidCallback f) {
      setState(() => _menuAt = null);
      HapticFeedback.selectionClick();
      f();
    }

    final items = <(String, VoidCallback)>[
      ('Копировать', () => _key(['ctrl', 'c'])),
      ('Вырезать', () => _key(['ctrl', 'x'])),
      ('Вставить', () => _key(['ctrl', 'v'])),
      ('Выделить всё', () => _key(['ctrl', 'a'])),
      ('Правая кнопка', () => _click(at, button: 'right')),
    ];
    final maxW = math.max(120.0, _viewport.width - 16);
    final top = at.dy - 62 < 8 ? at.dy + 28 : at.dy - 62;
    return Positioned(
      left: 8,
      right: 8,
      top: top,
      child: Align(
        alignment: Alignment(
            _viewport.width <= 0 ? 0 : ((at.dx / _viewport.width) * 2 - 1).clamp(-1.0, 1.0), 0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Material(
            color: const Color(0xF22A2A2E),
            elevation: 8,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) Container(width: 1, height: 22, color: Colors.white24),
                  InkWell(
                    onTap: () => act(items[i].$2),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                      child: Text(items[i].$1, style: K.t(13.5, w: FontWeight.w500)),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
