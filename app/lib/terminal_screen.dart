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

const _green = Color(0xFF7EE787);
const _blue = Color(0xFF8AB8FF);

/// Quick-launch buttons. Each one just types its command, so the user sees
/// (and learns) what to write next time.
const _apps = <(IconData, String, String)>[
  (Icons.public, 'Opera', 'opera'),
  (Icons.local_fire_department, 'Streak', 'streak'),
  (Icons.code, 'VS Code', 'vscode'),
  (Icons.smart_toy_outlined, 'Claude Code', 'claude'),
  (Icons.sports_esports_outlined, 'Unity Hub', 'unity'),
  (Icons.terminal, 'CMD', 'cmd'),
  (Icons.desktop_windows_outlined, 'Рабочий стол', 'рабочий стол'),
  (Icons.folder_open, 'Проводник', 'проводник'),
  (Icons.download, 'Загрузки', 'загрузки'),
  (Icons.monitor_heart_outlined, 'Диспетчер задач', 'диспетчер задач'),
];

/// Explanation shown under the input while typing.
const _hints = <String, String>{
  'помощь': 'Покажет список всех команд',
  'программы': 'Покажет все программы, которые можно открыть',
  'открыть': 'открыть <программа или файл>  — например: открыть opera, открыть steam, открыть отчет.docx',
  'открой': 'открой <программа>  — например: открой telegram',
  'проекты': 'Покажет ваши папки и проекты с номерами',
  'перейти': 'перейти <номер или название>  — зайти в папку проекта, например: перейти 10',
  'файлы': 'Покажет, что лежит в текущей папке',
  'папка': 'папка [номер]  — открыть папку в Проводнике на ноутбуке. Без номера — текущую',
  'vscode': 'vscode <номер>  — открыть проект в VS Code. Без номера — просто открыть VS Code',
  'claude': 'claude <номер>  — открыть Claude Code в окне на ноутбуке (работать с ним во вкладке «Экран»)',
  'спроси': 'спроси <вопрос>  — Claude ответит прямо здесь и может менять файлы в текущей папке',
  'новый': 'новый чат  — начать разговор с Claude заново',
  'unity': 'unity <номер>  — открыть проект в Unity. Без номера — открыть Unity Hub',
  'cd': 'cd <папка>  — перейти в папку (cd .. — на уровень выше)',
  'dir': 'Список файлов (команда PowerShell). Проще: файлы',
  'opera': 'Откроет браузер Opera',
  'streak': 'Откроет Streak',
  'cmd': 'Откроет окно командной строки на ноутбуке в текущей папке',
};

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
  String _hint = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_updateHint);
  }

  void _updateHint() {
    final t = _ctrl.text.trim().toLowerCase();
    String h = '';
    if (t.isNotEmpty) {
      final first = t.split(' ').first;
      h = _hints[first] ?? _hints.entries.firstWhere((e) => e.key.startsWith(t), orElse: () => const MapEntry('', '')).value;
      if (h.isEmpty) h = 'Команда PowerShell. Напишите «помощь», чтобы увидеть простые команды';
    }
    if (h != _hint) setState(() => _hint = h);
  }

  Future<void> _run(String cmd) async {
    cmd = cmd.trim();
    if (cmd.isEmpty || _busy) return;
    if (cmd == 'cls' || cmd == 'clear' || cmd == 'очистить') {
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
  }

  void _insert(String text) {
    _ctrl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
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
    _insert(t);
  }

  static const _mono = TextStyle(
      fontFamily: 'monospace', fontFamilyFallback: ['Consolas', 'Courier New', 'Menlo'], fontSize: 13, height: 1.35);

  // ------------------------------------------------------------ guide
  void _showGuide() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15191E),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            const Text('Как пользоваться терминалом', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Пишите команду внизу и нажимайте ➤. Команды выполняются на ноутбуке, а ответ появляется здесь. '
              'Пока открыт терминал, картинка экрана не передаётся — интернет почти не тратится.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 6),
            const Text('Нажмите на любой пример — он появится в строке ввода.',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
            _section('1. Открыть программу', [
              ('opera', 'браузер Opera'),
              ('streak', 'Streak'),
              ('vscode', 'VS Code'),
              ('cmd', 'командная строка'),
              ('рабочий стол', 'папка «Рабочий стол»'),
              ('открыть steam', 'любая программа из меню «Пуск»'),
              ('программы', 'весь список программ'),
            ], ctx),
            _section('2. Папки и проекты', [
              ('проекты', 'список проектов с номерами'),
              ('перейти 10', 'зайти в проект №10'),
              ('файлы', 'что лежит в текущей папке'),
              ('папка', 'открыть текущую папку в Проводнике'),
              ('открыть README.md', 'открыть файл из текущей папки'),
              ('cd ..', 'выйти на папку выше'),
            ], ctx),
            _section('3. Работа с проектом', [
              ('vscode 10', 'открыть проект №10 в VS Code'),
              ('claude 10', 'Claude Code в окне на ноутбуке (смотрите во вкладке «Экран»)'),
              ('спроси что делает этот проект?', 'Claude ответит прямо здесь'),
              ('спроси исправь ошибку в main.dart', 'Claude может менять файлы текущей папки'),
              ('новый чат', 'начать разговор с Claude заново'),
            ], ctx),
            _section('4. Unity', [
              ('unity', 'открыть Unity Hub'),
              ('unity 9', 'открыть проект №9 в Unity (в списке помечены [Unity])'),
            ], ctx),
            _section('5. Полезное', [
              ('помощь', 'список всех команд'),
              ('очистить', 'очистить экран терминала'),
              ('ipconfig', 'любая команда PowerShell тоже работает'),
            ], ctx),
            const SizedBox(height: 12),
            const Text(
              'Совет: вместо номера можно писать название — например «claude RemoteDesk». '
              'Кнопка 🕘 возвращает прошлую команду. Кнопка «Проекты» сверху открывает список с готовыми действиями.',
              style: TextStyle(color: Colors.white54, height: 1.4, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<(String, String)> rows, BuildContext ctx) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _blue)),
          const SizedBox(height: 6),
          for (final (cmd, what) in rows)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Navigator.pop(ctx);
                _insert(cmd);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xFF0C0E11), borderRadius: BorderRadius.circular(6)),
                    child: Text(cmd, style: _mono.copyWith(color: _green)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(what, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      );

  // ------------------------------------------------------------ projects
  Future<void> _showProjects() async {
    List<Place> list;
    try {
      list = await widget.api.places();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15191E),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            const Text('Папки и проекты', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Нажмите действие — в терминале будет видно, какая команда это делает.',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 8),
            for (final p in list)
              Card(
                color: const Color(0xFF1E232B),
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('${p.n}. ', style: const TextStyle(color: Colors.white54)),
                      Expanded(
                        child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      ),
                      if (p.unity)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
                          child: const Text('Unity', style: TextStyle(fontSize: 11)),
                        ),
                    ]),
                    Text(p.path, style: const TextStyle(color: Colors.white38, fontSize: 11), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      _act(ctx, 'Перейти', 'перейти ${p.n}'),
                      _act(ctx, 'Проводник', 'папка ${p.n}'),
                      _act(ctx, 'VS Code', 'vscode ${p.n}'),
                      _act(ctx, 'Claude', 'claude ${p.n}'),
                      if (p.unity) _act(ctx, 'Unity', 'unity ${p.n}'),
                    ]),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _act(BuildContext ctx, String label, String cmd) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        onPressed: () {
          Navigator.pop(ctx);
          _run(cmd);
        },
      );

  // ------------------------------------------------------------ UI
  Widget _welcome() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Терминал ноутбука', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Здесь можно открывать программы, папки и проекты простыми словами. '
            'Нажмите на пример или кнопку сверху.',
            style: TextStyle(color: Colors.white60, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (final (cmd, what) in const [
            ('помощь', 'все команды'),
            ('opera', 'открыть Opera'),
            ('проекты', 'список проектов'),
            ('vscode 10', 'проект №10 в VS Code'),
            ('claude 10', 'Claude Code в проекте №10'),
            ('спроси что тут за файлы?', 'вопрос Claude прямо отсюда'),
            ('unity', 'открыть Unity Hub'),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: InkWell(
                onTap: () => _insert(cmd),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(children: [
                    Text(cmd, style: _mono.copyWith(color: _green)),
                    const SizedBox(width: 10),
                    Expanded(child: Text('— $what', style: const TextStyle(color: Colors.white54, fontSize: 13))),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: _showGuide,
              icon: const Icon(Icons.help_outline),
              label: const Text('Подробная инструкция'),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF1A1E24),
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(children: [
            const Icon(Icons.terminal, size: 18, color: Colors.white60),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.info.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
            ),
            TextButton.icon(
              onPressed: _showProjects,
              icon: const Icon(Icons.folder_special_outlined, size: 18),
              label: const Text('Проекты'),
            ),
            IconButton(tooltip: 'Инструкция', icon: const Icon(Icons.help_outline, size: 22), onPressed: _showGuide),
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
              for (final (icon, label, cmd) in _apps)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    avatar: Icon(icon, size: 16),
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
                ? _welcome()
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
                              TextSpan(text: 'PS ${e.cwd}> ', style: _mono.copyWith(color: _green)),
                              TextSpan(text: e.cmd, style: _mono.copyWith(color: Colors.white)),
                            ])),
                            if (e.output == null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(children: [
                                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                  if (e.cmd.toLowerCase().startsWith('спроси'))
                                    const Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Text('Claude думает… это может занять пару минут',
                                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                                    ),
                                ]),
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
            Row(children: [
              const Icon(Icons.folder_outlined, size: 13, color: _green),
              const SizedBox(width: 4),
              Expanded(
                child: Text(_cwd, style: _mono.copyWith(fontSize: 11, color: _green), overflow: TextOverflow.ellipsis),
              ),
            ]),
            if (_hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lightbulb_outline, size: 14, color: Color(0xFFE3B341)),
                  const SizedBox(width: 4),
                  Expanded(child: Text(_hint, style: const TextStyle(fontSize: 12, color: Color(0xFFE3B341)))),
                ]),
              ),
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
                    onSubmitted: (t) {
                      _run(t);
                      _focus.requestFocus();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Команда… например: помощь',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Прошлая команда',
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
