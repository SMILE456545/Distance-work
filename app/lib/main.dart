import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'files/files_screen.dart';
import 'device/device.dart';
import 'device/qr_scan.dart';
import 'kraken/kraken.dart';
import 'remote_screen.dart';
import 'terminal_screen.dart';

void main() => runApp(const RemoteDeskApp());

class RemoteDeskApp extends StatelessWidget {
  const RemoteDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteDesk',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: K.theme(),
      home: const ConnectScreen(),
    );
  }
}

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8765');
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    // When the app is opened from the server itself in a browser, use that address.
    final fromWeb = kIsWeb && Uri.base.host.isNotEmpty && Uri.base.scheme.startsWith('http');
    setState(() {
      _host.text = fromWeb
          ? (Uri.base.scheme == 'https' ? 'https://${Uri.base.host}' : Uri.base.host)
          : (p.getString('host') ?? '');
      _port.text = fromWeb ? '${Uri.base.port}' : (p.getString('port') ?? '8765');
      _key.text = p.getString('key') ?? '';
      deviceOverride = p.getString('device_model');
    });
    // Opened from the QR code in the PC window: «http://pc:8765/?k=KEY» — log in at once.
    final k = kIsWeb ? (Uri.base.queryParameters['k'] ?? '') : '';
    if (k.isNotEmpty) {
      clearLoginLink();
      _key.text = k;
      _connect();
    }
  }

  /// «192.168.0.10», «https://mydesk.duckdns.org:8443» or just «mydesk.duckdns.org».
  (String, int, bool) _address() {
    var text = _host.text.trim();
    var port = int.tryParse(_port.text.trim());
    var secure = text.startsWith('https://') || text.endsWith('.duckdns.org');
    if (text.contains('://')) {
      final u = Uri.tryParse(text);
      if (u != null && u.host.isNotEmpty) {
        text = u.host;
        if (u.hasPort) port = u.port;
      }
    }
    text = text.split('/').first;
    if (text.contains(':') && !text.contains('::')) {
      final parts = text.split(':');
      text = parts.first;
      port = int.tryParse(parts.last) ?? port;
    }
    if (secure && (port == null || port == 8765)) port = 8443;
    return (text, port ?? 8765, secure);
  }

  Future<void> _connect() async {
    final (host, port, secure) = _address();
    final key = _key.text.trim();
    if (host.isEmpty || key.isEmpty) {
      setState(() => _error = 'Введите адрес и ключ');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = Api(host, port, key, secure: secure);
    try {
      final info = await api.info();
      final p = await SharedPreferences.getInstance();
      await p.setString('host', secure ? 'https://$host' : host);
      await p.setString('port', '$port');
      await p.setString('key', key);
      if (!mounted) return;
      final nav = Navigator.of(context);
      Api.onKicked = (msg) {
        Api.onKicked = null;
        nav.popUntil((r) => r.isFirst);
        if (mounted) setState(() => _error = msg);
      };
      await nav.push(PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => HomeScreen(api: api, info: info),
      ));
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Не удалось подключиться. Проверьте, что сервер на ноутбуке запущен. '
          'Дома — адрес вида 192.168.x.x, из любого места — адрес Tailscale (100.x.x.x)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _showKey = false;

  /// «Сканировать QR-код»: the code in the PC window holds the address, port and key —
  /// fill them in and connect at once.
  Future<void> _scanQr() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    String? text;
    try {
      text = await scanQr(context);
    } on FormatException {
      setState(() {
        _busy = false;
        _error = 'QR-код не распознан. Снимите его ближе, чтобы он занимал большую часть кадра, без бликов.';
      });
      return;
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Не удалось открыть фото: $e';
      });
      return;
    }
    setState(() => _busy = false);
    if (text == null) return; // cancelled
    final u = Uri.tryParse(text.trim());
    final k = u?.queryParameters['k'] ?? '';
    if (u == null || u.host.isEmpty || k.isEmpty) {
      setState(() => _error = 'Это не QR-код RemoteDesk. Отсканируйте код из окна программы на компьютере.');
      return;
    }
    setState(() {
      _host.text = u.host;
      _port.text = '${u.hasPort ? u.port : 8765}';
      _key.text = k;
    });
    await _connect();
  }

  static const _accent = Colors.white; // black & white page
  static const _field = Color(0xFF141417);

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: K.t(12, color: const Color(0xFFD6D6DC), w: FontWeight.w500)),
          TextSpan(text: ' *', style: K.t(12, color: const Color(0xFF8A8A92), w: FontWeight.w500)),
        ])),
      );

  InputDecoration _input(String hint, {Widget? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: K.t(13, color: const Color(0xFF5E5E66), w: FontWeight.w400),
        suffixIcon: suffix,
        filled: true,
        fillColor: _field,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF232328))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _accent, width: 1.4)),
      );

  Widget _form() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Подключение к компьютеру', style: K.t(20, w: FontWeight.w500)),
        const SizedBox(height: 10),
        Text('Соедините телефон с ноутбуком: введите адрес и ключ, которые показаны в окне сервера на компьютере.',
            style: K.t(12.5, color: const Color(0xFF8A8A92), w: FontWeight.w400, height: 1.5)),
        const SizedBox(height: 26),
        _label('Адрес компьютера'),
        TextField(
          controller: _host,
          keyboardType: TextInputType.url,
          style: K.t(14, w: FontWeight.w500),
          decoration: _input('например, 192.168.0.10 или 100.x.x.x'),
        ),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 104,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _label('Порт'),
              TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                style: K.t(14, w: FontWeight.w500),
                decoration: _input('8765'),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _label('Ключ доступа'),
              TextField(
                controller: _key,
                keyboardType: TextInputType.visiblePassword,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: !_showKey,
                onSubmitted: (_) => _connect(),
                style: K.code(14, w: FontWeight.w700),
                decoration: _input('XXXX-XXXX-…-XXXX',
                    suffix: IconButton(
                      icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          size: 18, color: const Color(0xFF6A6A72)),
                      onPressed: () => setState(() => _showKey = !_showKey),
                    )),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text('Ключ из 32 символов — или просто отсканируйте QR-код из окна программы. Дома используйте адрес 192.168.x.x, вне дома — адрес Tailscale 100.x.x.x.',
            style: K.t(11, color: const Color(0xFF6E6E76), w: FontWeight.w400, height: 1.45)),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: K.t(12, color: K.coral, w: FontWeight.w500, height: 1.4)),
        ],
        const SizedBox(height: 26),
        SizedBox(
          height: 46,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: K.ink,
              disabledBackgroundColor: _accent.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _busy ? null : _connect,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: K.ink))
                : Text('Подключиться', style: K.t(14, color: K.ink, w: FontWeight.w600)),
          ),
        ),
        if (canScanQr) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF3A3A40)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _busy ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: Text('Сканировать QR-код', style: K.t(14, w: FontWeight.w600)),
            ),
          ),
        ],
        const SizedBox(height: 22),
        Center(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Сервер не запущен? ', style: K.t(12, color: const Color(0xFF8A8A92), w: FontWeight.w400)),
            TextSpan(text: 'Запустите RemoteDesk на ПК', style: K.t(12, w: FontWeight.w600)),
          ])),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text('Подключение идёт напрямую к вашему компьютеру и защищено ключом доступа.',
              textAlign: TextAlign.center,
              style: K.t(10.5, color: const Color(0xFF5E5E66), w: FontWeight.w400, height: 1.4)),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final wide = size.width > 760;
    final card = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: wide ? const EdgeInsets.symmetric(horizontal: 40, vertical: 36) : const EdgeInsets.fromLTRB(16, 26, 16, 18),
        child: _form(),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: KrakenBackground(
        child: Stack(children: [
          // prepares the terminal fonts in advance, so opening the terminal after «Подключиться» doesn't stutter
          Offstage(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(r'PS C:\> Windows PowerShell абв', style: K.code(14)),
              Text(r'PS C:\> Windows PowerShell абв', style: K.code(14, w: FontWeight.w700)),
              Text('Терминал Opera', style: K.t(13, w: FontWeight.w600)),
            ]),
          ),
          SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(wide ? 32 : 10),
              child: ConstrainedBox(constraints: BoxConstraints(maxWidth: wide ? 500 : 480), child: card),
            ),
          ),
        ),
        ]),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final Api api;
  final ServerInfo info;
  const HomeScreen({super.key, required this.api, required this.info});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  bool _screenOpened = false; // the Screen tab is built the first time it is opened
  bool _filesOpened = false;

  void _setTab(int i) => setState(() {
        _tab = i;
        if (i == 1) _screenOpened = true;
        if (i == 2) _filesOpened = true;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // what shows behind the phone keyboard — dark like the terminal, not violet
      backgroundColor: const Color(0xFF0C0C0C),
      resizeToAvoidBottomInset: true,
      body: IndexedStack(
        index: _tab,
        children: [
          TerminalScreen(api: widget.api, info: widget.info, tab: _tab, onTab: _setTab),
          // the screen picture is only downloaded while this tab is open
          _screenOpened
              ? RemoteScreen(api: widget.api, info: widget.info, active: _tab == 1, tab: _tab, onTab: _setTab)
              : const SizedBox.shrink(),
          _filesOpened
              ? FilesScreen(api: widget.api, active: _tab == 2, tab: _tab, onTab: _setTab)
              : const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// The tabs shown in every screen's dock.
const homeTabs = [
  DockTab(Icons.terminal_rounded, 'Терминал'),
  DockTab(Icons.desktop_windows_rounded, 'Экран'),
  DockTab(Icons.swap_vert_rounded, 'Файлы'),
];
