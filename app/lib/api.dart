import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

class MonitorInfo {
  final int width;
  final int height;
  MonitorInfo(this.width, this.height);
}

class ServerInfo {
  final String name;
  final List<MonitorInfo> monitors;
  final String home;
  ServerInfo(this.name, this.monitors, this.home);
}

class Frame {
  final Uint8List bytes;
  final String tag;
  Frame(this.bytes, this.tag);
}

class Place {
  final int n;
  final String name;
  final String path;
  final bool unity;
  Place(this.n, this.name, this.path, this.unity);
}

class Patch {
  final double x, y, w, h;
  final Uint8List bytes;
  Patch(this.x, this.y, this.w, this.h, this.bytes);
}

/// A screen update: either a full picture ([key]) or only the changed parts.
class ScreenUpdate {
  final int seq;
  final int width;
  final int height;
  final bool key;
  final List<Patch> patches;
  ScreenUpdate(this.seq, this.width, this.height, this.key, this.patches);

  static ScreenUpdate parse(Uint8List b) {
    final jl = ByteData.sublistView(b).getUint32(0);
    final j = jsonDecode(utf8.decode(Uint8List.sublistView(b, 4, 4 + jl))) as Map<String, dynamic>;
    var off = 4 + jl;
    final patches = <Patch>[];
    for (final r in j['rects'] as List) {
      final len = r[4] as int;
      patches.add(Patch((r[0] as num).toDouble(), (r[1] as num).toDouble(), (r[2] as num).toDouble(),
          // own copy: Safari can't decode images that are views into a bigger buffer
          (r[3] as num).toDouble(), Uint8List.fromList(Uint8List.sublistView(b, off, off + len))));
      off += len;
    }
    return ScreenUpdate(j['seq'] as int, j['w'] as int, j['h'] as int, j['key'] as bool, patches);
  }
}

/// Talks to the RemoteDesk server running on the computer.
class Api {
  final String host;
  final int port;
  final String key;

  /// true = https (connection from the internet through the DuckDNS name).
  final bool secure;
  final http.Client _client = http.Client();

  /// Round-trip time measured when connecting, in milliseconds.
  int rttMs = 0;

  Api(this.host, this.port, this.key, {this.secure = false});

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: path, queryParameters: q);

  Map<String, String> get _headers => {'X-Key': key, 'Content-Type': 'application/json'};

  void close() => _client.close();

  Future<ServerInfo> info() async {
    final sw = Stopwatch()..start();
    final r = await _client
        .get(_u('/api/info'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    rttMs = sw.elapsedMilliseconds;
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final mons = (j['monitors'] as List)
        .map((m) => MonitorInfo(m['width'] as int, m['height'] as int))
        .toList();
    return ServerInfo(j['name'] as String, mons, j['home'] as String);
  }

  /// Returns null when the screen has not changed since [last].
  Future<Frame?> frame({int monitor = 0, int width = 1280, int quality = 60, String last = ''}) async {
    final r = await _client
        .get(
          _u('/api/frame', {'m': '$monitor', 'w': '$width', 'q': '$quality', 'last': last}),
          headers: {'X-Key': key},
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 204) return null;
    _check(r);
    return Frame(r.bodyBytes, r.headers['x-frame'] ?? '');
  }

  /// Waits (up to ~2 s on the server) for screen changes newer than [after].
  /// Returns null when nothing changed.
  Future<ScreenUpdate?> stream(
      {required int after, int monitor = 0, int width = 1280, int quality = 60, bool keyframe = false}) async {
    final r = await _client
        .get(
          _u('/api/stream', {
            'after': '$after',
            'm': '$monitor',
            'w': '$width',
            'q': '$quality',
            if (keyframe) 'kf': '1',
          }),
          headers: {'X-Key': key},
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 204) return null;
    _check(r);
    return ScreenUpdate.parse(r.bodyBytes);
  }

  Future<void> input(List<Map<String, dynamic>> events) async {
    final r = await _client
        .post(_u('/api/input'), headers: _headers, body: jsonEncode(events))
        .timeout(const Duration(seconds: 5));
    _check(r);
  }

  Future<(String, String)> cmd(String command, String cwd) async {
    final r = await _client
        .post(_u('/api/cmd'), headers: _headers, body: jsonEncode({'cmd': command, 'cwd': cwd}))
        .timeout(const Duration(seconds: 620)); // «спроси» waits for Claude up to 10 min
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['output'] as String? ?? '', j['cwd'] as String? ?? cwd);
  }

  /// WebRTC: sends the phone's offer, gets the laptop's answer (fast H.264 video).
  Future<Map<String, dynamic>> rtc(Map<String, dynamic> offer) async {
    final r = await _client
        .post(_u('/api/rtc'), headers: _headers, body: jsonEncode(offer))
        .timeout(const Duration(seconds: 25));
    _check(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<Place>> places() async {
    final r = await _client.get(_u('/api/places'), headers: _headers).timeout(const Duration(seconds: 10));
    _check(r);
    return [
      for (final p in jsonDecode(utf8.decode(r.bodyBytes)) as List)
        Place(p['n'] as int, p['name'] as String, p['path'] as String, p['unity'] as bool),
    ];
  }

  void _check(http.Response r) {
    if (r.statusCode == 401) throw ApiError('Неверный ключ доступа');
    if (r.statusCode == 429) {
      String msg = 'Слишком много неверных ключей — доступ временно закрыт';
      try {
        msg = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error'] as String;
      } catch (_) {}
      throw ApiError(msg);
    }
    if (r.statusCode >= 400) {
      String msg = 'Ошибка сервера ${r.statusCode}';
      try {
        msg = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error'] as String;
      } catch (_) {}
      throw ApiError(msg);
    }
  }
}

/// Sends input events one request at a time, merging mouse moves so the
/// cursor never lags behind the finger.
class InputQueue {
  final Api api;
  final List<Map<String, dynamic>> _pending = [];
  bool _busy = false;

  InputQueue(this.api);

  void add(Map<String, dynamic> ev) {
    if (ev['t'] == 'move' && _pending.isNotEmpty && _pending.last['t'] == 'move') {
      _pending[_pending.length - 1] = ev;
    } else if (ev['t'] == 'rel' && _pending.isNotEmpty && _pending.last['t'] == 'rel') {
      final l = _pending.last;
      l['dx'] = (l['dx'] as int) + (ev['dx'] as int);
      l['dy'] = (l['dy'] as int) + (ev['dy'] as int);
    } else if (ev['t'] == 'scroll' && _pending.isNotEmpty && _pending.last['t'] == 'scroll') {
      final l = _pending.last;
      l['dy'] = (l['dy'] as int) + (ev['dy'] as int? ?? 0);
      l['dx'] = (l['dx'] as int) + (ev['dx'] as int? ?? 0);
    } else {
      _pending.add(ev);
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_busy || _pending.isEmpty) return;
    _busy = true;
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    try {
      await api.input(batch);
    } catch (_) {
      // dropped; the next event will try again
    }
    _busy = false;
    if (_pending.isNotEmpty) _pump();
  }
}
