import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'remote_screen.dart';
import 'terminal_screen.dart';

void main() => runApp(const RemoteDeskApp());

const accent = Color(0xFF3D8BFD);

class RemoteDeskApp extends StatelessWidget {
  const RemoteDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteDesk',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF111418),
        useMaterial3: true,
      ),
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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.desktop_windows_rounded, size: 56, color: accent),
                  const SizedBox(height: 12),
                  Text('RemoteDesk', textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text('Управление компьютером с телефона',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(color: Colors.white60)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'Адрес компьютера',
                        hintText: '192.168.x.x  или  100.x.x.x (Tailscale)',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Порт', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _key,
                    keyboardType: TextInputType.visiblePassword,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    obscureText: true,
                    onSubmitted: (_) => _connect(),
                    decoration: const InputDecoration(
                        labelText: 'Ключ доступа', hintText: 'XXXX-XXXX-XXXX-XXXX', border: OutlineInputBorder()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: const TextStyle(color: Color(0xFFFF7B72))),
                  ],
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link_rounded),
                    label: const Padding(padding: EdgeInsets.all(12), child: Text('Подключиться')),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Адрес и ключ показаны в окне сервера на компьютере.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall?.copyWith(color: Colors.white54),
                  ),
                ],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TerminalScreen(api: widget.api, info: widget.info),
          // the screen picture is only downloaded while this tab is open
          RemoteScreen(api: widget.api, info: widget.info, active: _tab == 1),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 60,
        selectedIndex: _tab,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.terminal_outlined), selectedIcon: Icon(Icons.terminal), label: 'Терминал'),
          NavigationDestination(icon: Icon(Icons.desktop_windows_outlined), selectedIcon: Icon(Icons.desktop_windows), label: 'Экран'),
        ],
      ),
    );
  }
}
