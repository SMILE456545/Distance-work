import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'kraken/kraken.dart';
import 'remote_screen.dart';
import 'terminal_screen.dart';

void main() => runApp(const RemoteDeskApp());

class RemoteDeskApp extends StatelessWidget {
  const RemoteDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteDesk · Kraken Digital',
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
    });
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
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => HomeScreen(api: api, info: info)));
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

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 820;
    final hero = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const KrakenWordmark(),
      SizedBox(height: wide ? 48 : 36),
      Text('Remote', style: K.h(wide ? 84 : 58)),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text('desk', style: K.accent(wide ? 84 : 58)),
        const SizedBox(width: 14),
        const KTag('ONLINE 24/7'),
      ]),
      const SizedBox(height: 16),
      Text('Ваш компьютер —\nв кармане', style: K.t(wide ? 20 : 17, w: FontWeight.w600, height: 1.25)),
    ]);
    final card = Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: K.ink,
        borderRadius: BorderRadius.circular(34),
        boxShadow: const [BoxShadow(color: Color(0x55180F70), blurRadius: 40, offset: Offset(0, 18))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text('Подключение', style: K.h(24))),
          const KrakenBadge(size: 40),
        ]),
        const SizedBox(height: 6),
        Text('Адрес и ключ показаны в окне сервера на компьютере',
            style: K.t(13, color: K.muted, height: 1.3)),
        const SizedBox(height: 18),
        TextField(
          controller: _host,
          keyboardType: TextInputType.url,
          style: K.t(16, w: FontWeight.w600),
          decoration: kField('Адрес компьютера', hint: '192.168.x.x  или  100.x.x.x'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          SizedBox(
            width: 110,
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              style: K.t(16, w: FontWeight.w600),
              decoration: kField('Порт'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _key,
              keyboardType: TextInputType.visiblePassword,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: !_showKey,
              onSubmitted: (_) => _connect(),
              style: K.code(15, w: FontWeight.w700),
              decoration: kField('Ключ', hint: 'XXXX-XXXX-…',
                  suffix: IconButton(
                    icon: Icon(_showKey ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: 20, color: K.muted),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  )),
            ),
          ),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: K.coral.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(16)),
            child: Text(_error!, style: K.t(13, color: K.coral, height: 1.35)),
          ),
        ],
        const SizedBox(height: 18),
        KPillButton('Подключиться', onPressed: _connect, busy: _busy),
      ]),
    );
    return Scaffold(
      backgroundColor: K.violet,
      body: KrakenBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: wide
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: Row(children: [
                        Expanded(child: hero),
                        const SizedBox(width: 40),
                        SizedBox(width: 420, child: card),
                      ]),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        hero,
                        const SizedBox(height: 28),
                        card,
                      ]),
                    ),
            ),
          ),
        ),
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

  void _setTab(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.violet,
      resizeToAvoidBottomInset: true,
      body: IndexedStack(
        index: _tab,
        children: [
          TerminalScreen(api: widget.api, info: widget.info, tab: _tab, onTab: _setTab),
          // the screen picture is only downloaded while this tab is open
          RemoteScreen(api: widget.api, info: widget.info, active: _tab == 1, tab: _tab, onTab: _setTab),
        ],
      ),
    );
  }
}

/// The two tabs shown in every screen's dock.
const homeTabs = [
  DockTab(Icons.terminal_rounded, 'Терминал'),
  DockTab(Icons.desktop_windows_rounded, 'Экран'),
];
