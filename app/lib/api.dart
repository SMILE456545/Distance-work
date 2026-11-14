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

/// Talks to the RemoteDesk server running on the computer.
class Api {
  final String host;
  final int port;
  final String key;
  final http.Client _client = http.Client();

  Api(this.host, this.port, this.key);

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: q);

  Map<String, String> get _headers => {'X-Key': key, 'Content-Type': 'application/json'};

  void close() => _client.close();

  Future<ServerInfo> info() async {
    final r = await _client
        .get(_u('/api/info'), headers: _headers)
        .timeout(const Duration(seconds: 5));
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

  Future<void> input(List<Map<String, dynamic>> events) async {
    final r = await _client
        .post(_u('/api/input'), headers: _headers, body: jsonEncode(events))
        .timeout(const Duration(seconds: 5));
    _check(r);
  }

  Future<(String, String)> cmd(String command, String cwd) async {
    final r = await _client
        .post(_u('/api/cmd'), headers: _headers, body: jsonEncode({'cmd': command, 'cwd': cwd}))
        .timeout(const Duration(seconds: 130));
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['output'] as String? ?? '', j['cwd'] as String? ?? cwd);
  }

  void _check(http.Response r) {
    if (r.statusCode == 401) throw ApiError('Неверный ключ доступа');
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
