import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'device/device.dart';

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

/// The console on the PC was closed (or the server restarted).
class PtyGone implements Exception {
  @override
  String toString() => 'Сессия закрыта';
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

  /// «phone; iPhone 15 Pro» — the PC window shows who is connected.
  String get _device => deviceTag(); // a model picked on the connect page counts at once

  Map<String, String> get _headers => {'X-Key': key, 'X-Device': _device, 'Content-Type': 'application/json'};

  void close() => _client.close();

  Future<ServerInfo> info() async {
    final sw = Stopwatch()..start();
    final r = await _client
        .get(_u('/api/info'), headers: {..._headers, 'X-Login': '1'}) // only the connect page calls it
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
          headers: {'X-Key': key, 'X-Device': _device},
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
          headers: {'X-Key': key, 'X-Device': _device},
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

  // ---- real consoles on the PC (Claude Code as in Windows Terminal)

  /// Starts a program in its own console on the PC; returns (id, title, folder).
  Future<(String, String, String)> ptyStart({required String cwd, required int cols, required int rows,
      String kind = 'claude'}) async {
    final r = await _client
        .post(_u('/api/pty/start'),
            headers: _headers, body: jsonEncode({'cwd': cwd, 'cols': cols, 'rows': rows, 'kind': kind}))
        .timeout(const Duration(seconds: 20));
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['id'] as String, j['title'] as String, j['cwd'] as String);
  }

  /// Output after character [after]; the server waits up to 20 s for something new.
  /// Returns (text, new position, the program ended). Throws [PtyGone] when closed.
  Future<(String, int, bool)> ptyRead(String id, int after) async {
    final r = await _client
        .get(_u('/api/pty/read', {'id': id, 'after': '$after'}), headers: _headers)
        .timeout(const Duration(seconds: 35));
    if (r.statusCode == 404) throw PtyGone();
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['data'] as String, j['end'] as int, j['exited'] as bool);
  }

  Future<void> ptyWrite(String id, String data) async {
    final r = await _client
        .post(_u('/api/pty/write'), headers: _headers, body: jsonEncode({'id': id, 'data': data}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 404) throw PtyGone();
    _check(r);
  }

  Future<void> ptyResize(String id, int cols, int rows) async {
    final r = await _client
        .post(_u('/api/pty/resize'), headers: _headers, body: jsonEncode({'id': id, 'cols': cols, 'rows': rows}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 404) return;
    _check(r);
  }

  Future<void> ptyKill(String id) async {
    try {
      await _client
          .post(_u('/api/pty/kill'), headers: _headers, body: jsonEncode({'id': id}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Sends a file from the phone; it lands in Downloads\RemoteDesk on the PC.
  /// Returns the full path on the PC.
  Future<String> upload(String name, Uint8List bytes) async {
    final r = await _client
        .post(_u('/api/upload', {'name': name}),
            headers: {'X-Key': key, 'X-Device': _device, 'Content-Type': 'application/octet-stream'},
            body: bytes)
        .timeout(const Duration(minutes: 10));
    _check(r);
    return (jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>)['path'] as String;
  }

  /// One PC folder (path '' = the start list: Desktop, Downloads, disks…).
  Future<PcFolder> listFiles(String path) async {
    final r = await _client
        .get(_u('/api/files/list', {'path': path}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _check(r);
    final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return PcFolder(
      m['path'] as String? ?? '',
      m['parent'] as String?,
      [for (final i in m['items'] as List) PcEntry.fromJson(i as Map<String, dynamic>)],
    );
  }

  /// Link the browser opens to save a PC file on the phone (the key goes in the link:
  /// a download started by the browser can't send headers).
  String downloadUrl(String path) => _u('/api/files/get', {'path': path, 'key': key}).toString();

  /// Everything sent to the PC and taken from it, newest first.
  Future<List<Transfer>> transfers() async {
    final r = await _client.get(_u('/api/transfers'), headers: _headers).timeout(const Duration(seconds: 10));
    _check(r);
    return [
      for (final i in jsonDecode(utf8.decode(r.bodyBytes)) as List) Transfer.fromJson(i as Map<String, dynamic>)
    ];
  }

  /// kind: 'sent', 'recv' or '' (both).
  Future<void> clearTransfers(String kind) async {
    final r = await _client
        .post(_u('/api/transfers/clear'), headers: _headers, body: jsonEncode({'kind': kind}))
        .timeout(const Duration(seconds: 10));
    _check(r);
  }

  /// Is Windows on the lock screen, and is the unlock helper installed on the PC.
  Future<(bool locked, bool agent)> lockState() async {
    final r = await _client.get(_u('/api/lock'), headers: _headers).timeout(const Duration(seconds: 5));
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['locked'] as bool? ?? false, j['agent'] as bool? ?? false);
  }

  /// Types the PIN / password on the PC's lock screen. Returns null when Windows opened,
  /// otherwise the reason.
  Future<String?> unlock(String pin) async {
    final r = await _client
        .post(_u('/api/unlock'), headers: _headers, body: jsonEncode({'pin': pin}))
        .timeout(const Duration(seconds: 50));
    _check(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return j['ok'] == true ? null : (j['error'] as String? ?? 'Не получилось');
  }

  /// All programs on the PC: (name, command to open it, is one of the main ones).
  Future<List<(String, String, bool)>> apps() async {
    final r = await _client.get(_u('/api/apps'), headers: _headers).timeout(const Duration(seconds: 15));
    _check(r);
    return [
      for (final a in jsonDecode(utf8.decode(r.bodyBytes)) as List)
        (a['name'] as String, a['cmd'] as String, a['main'] as bool),
    ];
  }

  Future<List<Place>> places() async {
    final r = await _client.get(_u('/api/places'), headers: _headers).timeout(const Duration(seconds: 10));
    _check(r);
    return [
      for (final p in jsonDecode(utf8.decode(r.bodyBytes)) as List)
        Place(p['n'] as int, p['name'] as String, p['path'] as String, p['unity'] as bool),
    ];
  }

  /// Set by the connect page: the PC turned this device off → back to the connect page.
  static void Function(String message)? onKicked;

  void _check(http.Response r) {
    if (r.statusCode == 401) throw ApiError('Неверный ключ доступа');
    if (r.statusCode == 403) {
      String msg = 'Компьютер отключил это устройство';
      try {
        msg = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error'] as String;
      } catch (_) {}
      onKicked?.call(msg);
      throw ApiError(msg);
    }
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

class PcEntry {
  final String name, path;
  final bool dir;
  final int size;
  final double time;
  const PcEntry(this.name, this.path, this.dir, this.size, this.time);
  factory PcEntry.fromJson(Map<String, dynamic> m) => PcEntry(m['name'] as String, m['path'] as String,
      m['dir'] as bool? ?? false, (m['size'] as num?)?.toInt() ?? 0, (m['time'] as num?)?.toDouble() ?? 0);
}

class PcFolder {
  final String path;
  final String? parent; // '' = back to the start list, null = this is the start list
  final List<PcEntry> items;
  const PcFolder(this.path, this.parent, this.items);
}

/// One file sent to the PC ('sent') or taken from it ('recv').
class Transfer {
  final String kind, name, path;
  final int size;
  final DateTime time;
  final bool exists;
  const Transfer(this.kind, this.name, this.path, this.size, this.time, this.exists);
  factory Transfer.fromJson(Map<String, dynamic> m) => Transfer(
        m['kind'] as String,
        m['name'] as String,
        m['path'] as String,
        (m['size'] as num?)?.toInt() ?? 0,
        DateTime.fromMillisecondsSinceEpoch((((m['time'] as num?) ?? 0) * 1000).round()),
        m['exists'] as bool? ?? true,
      );
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
