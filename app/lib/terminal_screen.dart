import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'kraken/kraken.dart';
import 'main.dart' show homeTabs;

class _Entry {
  final String cwd;
  final String cmd;
  String? output;
  bool error = false;
  _Entry(this.cwd, this.cmd);
}

const _green = K.lime;
const _blue = K.lilac;

/// Colors of the quick-launch chips, in turn (like the colorful tags in the references).
const _chipColors = [
  (K.white, K.ink),
  (K.lilac, K.ink),
  (K.yellow, K.ink),
  (K.panel2, K.white),
  (K.lime, K.ink),
  (K.coral, K.ink),
];

/// Quick-launch buttons. Each one just types its command, so the user sees
/// (and learns) what to write next time.
const _apps = <(IconData, String, String)>[
  (Icons.cancel_presentation, 'Открытые окна', 'открытые'),
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
  'открытые': 'Покажет открытые окна с номерами — потом можно закрыть: закрыть 3',
  'окна': 'Покажет открытые окна с номерами',
  'закрыть': 'закрыть <программа или номер>  — как нажать ✕: закрыть opera, закрыть 3. '
      'Если зависла: закрыть принудительно opera (несохранённое пропадёт)',
  'закрой': 'закрой <программа или номер>  — например: закрой vscode',
  'убить': 'убить <программа>  — то же, что «закрыть принудительно»: без сохранения',
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
  final int tab;
  final ValueChanged<int> onTab;
  const TerminalScreen({super.key, required this.api, required this.info, required this.tab, required this.onTab});

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
  bool _dockOpen = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_updateHint);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  /// Commands shown in the carousel above the keyboard.
  /// Ending with a space = needs a word after it, so it is only inserted.
  static const _quick = [
    'помощь', 'открытые', 'закрыть ', 'открыть ', 'проекты', 'перейти ', 'файлы',
    'папка', 'vscode ', 'claude ', 'спроси ', 'unity', 'cd ..', 'программы', 'очистить',
  ];

  Widget _cmdCarousel() {
    final recent = _history.reversed.take(5).toList();
    Widget chip(String label, {bool past = false}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: KChip(
            label.trim(),
            icon: past ? Icons.history : null,
            style: _mono.copyWith(fontSize: 12, color: past ? Colors.white70 : _green),
            fg: Colors.white70,
            onTap: () {
              if (label.endsWith(' ')) {
                _insert(label); // needs a name/number after it
              } else {
                _run(label);
              }
            },
          ),
        );
    return TextFieldTapRegion(
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 4),
          children: [
            for (final c in recent) chip(c, past: true),
            for (final c in _quick) chip(c),
          ],
        ),
      ),
    );
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

  static final _mono = K.code(13);

  // ------------------------------------------------------------ guide
  void _showGuide() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Text('Как пользоваться', style: K.h(26)),
            Text('терминалом', style: K.accent(26, color: K.lilac)),
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
            _section('Закрыть программу', [
              ('открытые', 'список открытых окон с номерами'),
              ('закрыть opera', 'закрыть, как крестиком ✕'),
              ('закрыть 3', 'закрыть окно №3 из списка «открытые»'),
              ('закрыть принудительно opera', 'если программа зависла (несохранённое пропадёт)'),
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
          Text(title, style: K.t(15, w: FontWeight.w700, color: _blue)),
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
                    decoration: BoxDecoration(color: K.ink, borderRadius: BorderRadius.circular(10)),
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
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(children: [
              Text('Папки и ', style: K.h(26)),
              Text('проекты', style: K.accent(26, color: K.lilac)),
            ]),
            const SizedBox(height: 4),
            const Text('Нажмите действие — в терминале будет видно, какая команда это делает.',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 8),
            for (final p in list)
              Container(
                decoration: BoxDecoration(color: K.panel2, borderRadius: BorderRadius.circular(24)),
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('${p.n}  ', style: K.h(15, color: K.lilac)),
                      Expanded(
                        child: Text(p.name, style: K.t(15, w: FontWeight.w700), overflow: TextOverflow.ellipsis),
                      ),
                      if (p.unity)
                        const KTag('UNITY', bg: K.yellow),
                    ]),
                    Text(p.path, style: const TextStyle(color: Colors.white38, fontSize: 11), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
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

  Widget _act(BuildContext ctx, String label, String cmd) => KChip(
        label,
        bg: label == 'Перейти' ? K.white : K.ink,
        fg: label == 'Перейти' ? K.ink : K.white,
        onTap: () {
          Navigator.pop(ctx);
          _run(cmd);
        },
      );

  // ------------------------------------------------------------ UI
  Widget _welcome() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('С чего начать', style: K.h(22)),
          const SizedBox(height: 8),
          Text(
            'Здесь можно открывать программы, папки и проекты простыми словами. '
            'Нажмите на пример или кнопку сверху.',
            style: K.t(14, color: K.muted, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (final (cmd, what) in const [
            ('помощь', 'все команды'),
            ('opera', 'открыть Opera'),
            ('закрыть opera', 'закрыть Opera'),
            ('открытые', 'какие окна открыты'),
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
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(color: K.panel, borderRadius: BorderRadius.circular(18)),
                  child: Row(children: [
                    Text(cmd, style: _mono.copyWith(color: _green, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(what, style: K.t(13, color: K.muted))),
                    const Icon(Icons.north_east_rounded, size: 16, color: K.muted),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 16),
          KPillButton('Подробная инструкция', onPressed: _showGuide, bg: K.lilac),
        ],
      );

  Widget _logView() => _log.isEmpty
      ? _welcome()
      : SelectionArea(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            itemCount: _log.length,
            itemBuilder: (_, i) {
              final e = _log[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: 'PS ${e.cwd}> ', style: _mono.copyWith(color: _green)),
                    TextSpan(text: e.cmd, style: _mono.copyWith(color: K.white, fontWeight: FontWeight.w700)),
                  ])),
                  if (e.output == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        if (e.cmd.toLowerCase().startsWith('спроси'))
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text('Claude думает… это может занять пару минут', style: K.t(12, color: K.muted)),
                          ),
                      ]),
                    )
                  else if (e.output!.isNotEmpty)
                    Text(e.output!, style: _mono.copyWith(color: e.error ? K.coral : const Color(0xFFCFCFDA))),
                ]),
              );
            },
          ),
        );

  Widget _inputBar() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(children: [
              const Icon(Icons.folder_rounded, size: 13, color: _green),
              const SizedBox(width: 5),
              Expanded(
                child: Text(_cwd, style: _mono.copyWith(fontSize: 11, color: _green), overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          if (_focus.hasFocus) Padding(padding: const EdgeInsets.only(bottom: 6), child: _cmdCarousel()),
          if (_hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.lightbulb_rounded, size: 14, color: K.yellow),
                const SizedBox(width: 5),
                Expanded(child: Text(_hint, style: K.t(12, color: K.yellow, height: 1.3))),
              ]),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 4, 5, 4),
            decoration: BoxDecoration(color: K.panel2, borderRadius: BorderRadius.circular(30)),
            child: Row(children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _histStep(-1),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _histStep(1),
                  },
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    style: _mono.copyWith(fontSize: 14),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (t) {
                      _run(t);
                      _focus.requestFocus();
                    },
                    decoration: InputDecoration(
                      hintText: 'Команда… например: помощь',
                      hintStyle: K.t(14, color: const Color(0xFF6A6A78)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              KRound(
                _busy ? Icons.hourglass_top_rounded : Icons.arrow_upward_rounded,
                tip: 'Выполнить',
                size: 44,
                bg: K.yellow,
                fg: K.ink,
                onTap: _busy ? null : () => _run(_ctrl.text),
              ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom > 0;
    final landscape = mq.size.width > mq.size.height;
    return KrakenBackground(
      scene: KrakenScene.calm,
      animate: false,
      child: SafeArea(
        bottom: false,
        child: Column(children: [
          if (!(keyboard && landscape))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
              child: Row(children: [
                const AppIcon(size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Терминал', style: K.h(26)),
                    const SizedBox(height: 3),
                    Text(widget.info.name, style: K.accent(14), overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const KTag('ONLINE'),
              ]),
            ),
          if (!keyboard)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  for (var i = 0; i < _apps.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 7, bottom: 4),
                      child: KChip(
                        _apps[i].$2,
                        icon: _apps[i].$1,
                        bg: _chipColors[i % _chipColors.length].$1,
                        fg: _chipColors[i % _chipColors.length].$2,
                        onTap: () => _run(_apps[i].$3),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: K.ink,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: const [BoxShadow(color: Color(0x55180F70), blurRadius: 30, offset: Offset(0, 12))],
                ),
                child: Column(children: [
                  Expanded(child: _logView()),
                  _inputBar(),
                ]),
              ),
            ),
          ),
          if (!keyboard)
            KrakenDock(
              tabs: homeTabs,
              tab: widget.tab,
              onTab: widget.onTab,
              actions: [
                DockAction(Icons.folder_special_rounded, 'Проекты', _showProjects),
                DockAction(Icons.help_rounded, 'Помощь', _showGuide),
                DockAction(Icons.history_rounded, 'Прошлая', () => _histStep(-1)),
                DockAction(Icons.delete_sweep_rounded, 'Очистить', () => setState(_log.clear)),
                DockAction(Icons.logout_rounded, 'Выйти', () => Navigator.of(context).pop()),
              ],
              expanded: _dockOpen,
              onToggle: () => setState(() => _dockOpen = !_dockOpen),
            )
          else
            const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
