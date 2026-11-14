import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

class _Entry {
  final String cwd;
  final String cmd;
  String? output;
  bool error = false;
  _Entry(this.cwd, this.cmd);
}

const _launchers = <(String, String)>[
  ('Проводник', 'Start-Process explorer'),
  ('Блокнот', 'Start-Process notepad'),
  ('Калькулятор', 'Start-Process calc'),
  ('Диспетчер задач', 'Start-Process taskmgr'),
  ('Браузер', 'Start-Process "https://www.google.com"'),
  ('Параметры', 'Start-Process "ms-settings:"'),
  ('Процессы', 'Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name,Id,CPU'),
  ('Файлы здесь', 'Get-ChildItem'),
  ('Заряд', '(Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining,BatteryStatus)'),
  ('IP-адрес', 'Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress,InterfaceAlias'),
  ('Заблокировать', 'rundll32.exe user32.dll,LockWorkStation'),
  ('Сон', r'Add-Type -Assembly System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState("Suspend", $false, $false)'),
];

class TerminalScreen extends StatefulWidget {
  final Api api;
  final ServerInfo info;
  const TerminalScreen({super.key, required this.api, required this.info});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with AutomaticKeepAliveClientMixin {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<_Entry> _log = [];
  final List<String> _history = [];
  int _histPos = 0;
  late String _cwd = widget.info.home;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _run(String cmd) async {
    cmd = cmd.trim();
    if (cmd.isEmpty || _busy) return;
    if (cmd == 'cls' || cmd == 'clear') {
      setState(_log.clear);
      _ctrl.clear();
      return;
    }
    final e = _Entry(_cwd, cmd);
    setState(() {
      _log.add(e);
      _busy = true;
      _history.remove(cmd);
      _history.add(cmd);
      _histPos = _history.length;
    });
    _ctrl.clear();
    _toBottom();
    try {
      final (out, cwd) = await widget.api.cmd(cmd, _cwd);
      e.output = out;
      _cwd = cwd;
    } catch (err) {
      e.output = 'Ошибка: $err';
      e.error = true;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toBottom();
    _focus.requestFocus();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _histStep(int d) {
    if (_history.isEmpty) return;
    _histPos = (_histPos + d).clamp(0, _history.length);
    final t = _histPos < _history.length ? _history[_histPos] : '';
    _ctrl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  static const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Consolas', 'Courier New', 'Menlo'], fontSize: 13, height: 1.35);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF1A1E24),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(children: [
            const Icon(Icons.terminal, size: 18, color: Colors.white60),
            const SizedBox(width: 8),
            Expanded(
              child: Text('PowerShell · ${widget.info.name}',
                  style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'Очистить',
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              onPressed: () => setState(_log.clear),
            ),
          ]),
        ),
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              for (final (label, cmd) in _launchers)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _run(cmd),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF0C0E11),
            child: _log.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Введите команду PowerShell, например:\n\n'
                        'dir\ncd Desktop\nStart-Process notepad\nipconfig\n\n'
                        'Или нажмите кнопку быстрого запуска выше.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _log.length,
                      itemBuilder: (_, i) {
                        final e = _log[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text.rich(TextSpan(children: [
                              TextSpan(text: 'PS ${e.cwd}> ', style: _mono.copyWith(color: const Color(0xFF7EE787))),
                              TextSpan(text: e.cmd, style: _mono.copyWith(color: Colors.white)),
                            ])),
                            if (e.output == null)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            else if (e.output!.isNotEmpty)
                              Text(e.output!,
                                  style: _mono.copyWith(color: e.error ? const Color(0xFFFF7B72) : Colors.white70)),
                          ]),
                        );
                      },
                    ),
                  ),
          ),
        ),
        Container(
          color: const Color(0xFF1A1E24),
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_cwd, style: _mono.copyWith(fontSize: 11, color: const Color(0xFF7EE787)), overflow: TextOverflow.ellipsis),
            Row(children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _histStep(-1),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _histStep(1),
                  },
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    style: _mono,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _run,
                    decoration: const InputDecoration(
                      hintText: 'Команда…',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Предыдущая команда',
                icon: const Icon(Icons.history, size: 20),
                onPressed: () => _histStep(-1),
              ),
              IconButton.filled(
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send, size: 18),
                onPressed: _busy ? null : () => _run(_ctrl.text),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
