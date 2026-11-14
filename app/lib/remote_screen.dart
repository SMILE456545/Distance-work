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
import 'sound/unlock.dart';

enum TouchMode { direct, touchpad }

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
  TouchMode _mode = TouchMode.direct;
  bool _dragLock = false;
  bool _scrollMode = false;
  bool _panelOpen = true; // the dock's button grid; collapsed = just the tabs
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
    // video adapts to the connection by itself; the picture stream needs a lighter start far away
    _quality = 1;
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_rtcOn && _fps != _framesThisSecond) setState(() => _fps = _framesThisSecond);
      _framesThisSecond = 0;
    });
    _kbFocus.addListener(() {
      if (mounted) setState(() {});
    });
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
      if (_pc == null && !_rtcFailed) {
        _startRtc();
      } else {
        _dcSend({'t': 'resume'});
      }
    } else {
      // the Terminal tab is open — don't spend mobile traffic on the picture
      _dcSend({'t': 'pause'});
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
    _longPress?.cancel();
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
    // over the video connection events skip HTTP requests entirely
    if (_dc != null) {
      _dcSend(ev);
    } else {
      _input.add(ev);
    }
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
                  if (_panelOpen && _showKeys) _keysPanel(),
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
                left: 10,
                top: 10,
                child: IgnorePointer(
                  child: _badge(
                    _offline
                        ? 'Нет связи…'
                        : '${widget.info.name} · $_fps к/с${_rtcOn ? ' · видео' : ''}${_scale > 1 ? ' · ×${_scale.toStringAsFixed(1)}' : ''}',
                    _offline,
                  ),
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
    DockAction(
      Icons.keyboard_command_key_rounded,
      'Клавиши',
      () => setState(() => _showKeys = !_showKeys),
      on: _showKeys,
    ),
    DockAction(
      _mode == TouchMode.direct ? Icons.touch_app_rounded : Icons.mouse_rounded,
      _mode == TouchMode.direct ? 'Касание' : 'Тачпад',
      () {
        setState(() => _mode = _mode == TouchMode.direct ? TouchMode.touchpad : TouchMode.direct);
        _snack(
          _mode == TouchMode.direct
              ? 'Касание: нажимайте прямо на нужное место'
              : 'Тачпад: водите пальцем, курсор двигается как на ноутбуке',
        );
      },
    ),
    DockAction(Icons.pan_tool_alt_rounded, 'Тянуть', () {
      setState(() => _dragLock = !_dragLock);
      _snack(_dragLock ? 'Перетаскивание включено: ведите пальцем, чтобы тянуть' : 'Перетаскивание выключено');
    }, on: _dragLock),
    DockAction(Icons.swap_vert_rounded, 'Прокрутка', () {
      setState(() {
        _scrollMode = !_scrollMode;
        if (_scrollMode) _dragLock = false;
      });
      _snack(
        _scrollMode
            ? 'Прокрутка: ведите пальцем вверх/вниз, чтобы листать. Нажатия работают как обычно'
            : 'Прокрутка выключена',
      );
    }, on: _scrollMode),
    DockAction(Icons.ads_click_rounded, 'ПКМ', () => _send({'t': 'click', 'b': 'right'})),
    DockAction(
      Icons.zoom_out_map_rounded,
      '1:1',
      () => setState(() {
        _scale = 1;
        _offset = Offset.zero;
      }),
    ),
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

  Widget _keysPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: K.line),
      ),
      child: Column(
        children: [
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
        ],
      ),
    );
  }
}
