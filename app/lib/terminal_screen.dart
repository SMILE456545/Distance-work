import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'kraken/kraken.dart';
import 'main.dart' show homeTabs;

/// One terminal tab: its own output, folder and scroll position.
class _Session {
  final int id;
  final List<_Entry> log = [];
  String cwd;
  bool busy = false;
  final scroll = ScrollController();
  _Session(this.id, this.cwd);
}

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
  (Icons.cancel_presentation, 'Открытые окна', 'windows'),
  (Icons.public, 'Opera', 'opera'),
  (Icons.local_fire_department, 'Streak', 'streak'),
  (Icons.code, 'VS Code', 'vscode'),
  (Icons.smart_toy_outlined, 'Claude Code', 'claude'),
  (Icons.sports_esports_outlined, 'Unity Hub', 'unity'),
  (Icons.terminal, 'CMD', 'cmd'),
  (Icons.desktop_windows_outlined, 'Рабочий стол', 'desktop'),
  (Icons.folder_open, 'Проводник', 'explorer'),
  (Icons.download, 'Загрузки', 'downloads'),
  (Icons.monitor_heart_outlined, 'Диспетчер задач', 'taskmgr'),
];

/// Explanation shown under the input while typing.
const _hints = <String, String>{
  'help': 'Покажет список всех команд',
  'apps': 'Покажет все программы, которые можно открыть',
  'open': 'open <программа или файл>  — например: open opera, open steam, open report.docx',
  'windows': 'Покажет открытые окна с номерами — потом можно закрыть: close 3',
  'close': 'close <программа или номер>  — как нажать ✕: close opera, close 3. '
      'Если зависла: close force opera (несохранённое пропадёт)',
  'kill': 'kill <программа>  — то же, что «close force»: без сохранения',
  'projects': 'Покажет ваши папки и проекты с номерами',
  'go': 'go <номер или название>  — зайти в папку проекта, например: go 10',
  'files': 'Покажет, что лежит в текущей папке',
  'folder': 'folder [номер]  — открыть папку в Проводнике на ноутбуке. Без номера — текущую',
  'vscode': 'vscode <номер>  — открыть проект в VS Code. Без номера — просто открыть VS Code',
  'claude': 'claude <номер>  — открыть Claude Code в окне на ноутбуке (работать с ним во вкладке «Экран»)',
  'ask': 'ask <вопрос>  — Claude ответит прямо здесь и может менять файлы в текущей папке',
  'new': 'new chat  — начать разговор с Claude заново',
  'unity': 'unity <номер>  — открыть проект в Unity. Без номера — открыть Unity Hub',
  'cd': 'cd <папка>  — перейти в папку (cd .. — на уровень выше)',
  'dir': 'Список файлов (команда PowerShell). Проще: files',
  'clear': 'Очистить экран терминала',
  'opera': 'Откроет браузер Opera',
  'streak': 'Откроет Streak',
  'cmd': 'Откроет окно командной строки на ноутбуке в текущей папке',
  'desktop': 'Откроет папку «Рабочий стол»',
  'explorer': 'Откроет Проводник',
  'downloads': 'Откроет папку «Загрузки»',
  'taskmgr': 'Откроет Диспетчер задач',
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
  final _focus = FocusNode();
  final List<String> _history = [];
  int _histPos = 0;
  late final List<_Session> _tabs = [_Session(1, widget.info.home)];
  int _tab = 0;
  int _tabSeq = 1;
  _Session get _s => _tabs[_tab.clamp(0, _tabs.length - 1)];
  List<_Entry> get _log => _s.log;
  String get _cwd => _s.cwd;
  bool get _busy => _s.busy;
  ScrollController get _scroll => _s.scroll;
  final _hint = ValueNotifier<String>('');
  // Rebuilding the output on every key press made typing lag on phones:
  // the heavy parts are built once and reused until they really change.
  Widget? _logCache, _appsCache, _cmdsCache;
  int? _logKey, _appsKey, _cmdsKey;
  bool _dockOpen = true;
  // keeps the input field the same widget while rows above it appear/disappear,
  // otherwise it is rebuilt and the phone keyboard closes after one letter
  final _inputKey = GlobalKey();
  int _themeIdx = 0;
  double _fontSize = 14;
  int _monoFont = 0;
  List<(String, String, bool)>? _pcApps; // every program on the PC, from the server

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_updateHint);
    _loadLook();
    _loadApps();
  }

  /// Commands shown in the carousel above the keyboard.
  /// Ending with a space = needs a word after it, so it is only inserted.
  static const _quick = [
    'help', 'windows', 'close ', 'open ', 'projects', 'go ', 'files',
    'folder', 'vscode ', 'claude ', 'ask ', 'unity', 'cd ..', 'apps', 'clear',
  ];

  Widget _cmdCarousel() {
    final recent = _history.reversed.take(5).toList();
    Widget chip(String label, {bool past = false}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Material(
            color: _boxBg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: _boxLine)),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                if (label.endsWith(' ')) {
                  _insert(label); // needs a name/number after it
                } else {
                  _run(label);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(past ? '↺ ' : '› ', style: K.code(12.5, color: past ? _termFg.withValues(alpha: 0.5) : K.lime)),
                  Text(label.trim(), style: K.code(12.5, color: _termFg, w: FontWeight.w700)),
                  if (label.endsWith(' '))
                    Text(' …', style: K.code(12.5, color: _termFg.withValues(alpha: 0.45))),
                ]),
              ),
            ),
          ),
        );
    return TextFieldTapRegion(
      child: SizedBox(
        height: 32,
        child: ListView(
          scrollDirection: Axis.horizontal,
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
      if (h.isEmpty) h = 'Команда PowerShell. Напишите «help», чтобы увидеть простые команды';
    }
    _hint.value = h;
  }

  Future<void> _run(String cmd) async {
    cmd = cmd.trim();
    if (cmd.isEmpty || _busy) return;
    if (cmd == 'cls' || cmd == 'clear' || cmd == 'очистить') {
      setState(_log.clear);
      _ctrl.clear();
      return;
    }
    final ses = _s; // the answer goes to the tab the command was typed in
    final e = _Entry(ses.cwd, cmd);
    setState(() {
      ses.log.add(e);
      ses.busy = true;
      _history.remove(cmd);
      _history.add(cmd);
      _histPos = _history.length;
    });
    _ctrl.clear();
    _toBottom();
    try {
      final (out, cwd) = await widget.api.cmd(cmd, ses.cwd);
      e.output = out;
      ses.cwd = cwd;
    } catch (err) {
      e.output = 'Ошибка: $err';
      e.error = true;
    }
    if (!mounted) return;
    setState(() => ses.busy = false);
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
              ('desktop', 'папка «Рабочий стол»'),
              ('open steam', 'любая программа из меню «Пуск»'),
              ('apps', 'весь список программ'),
            ], ctx),
            _section('Закрыть программу', [
              ('windows', 'список открытых окон с номерами'),
              ('close opera', 'закрыть, как крестиком ✕'),
              ('close 3', 'закрыть окно №3 из списка «windows»'),
              ('close force opera', 'если программа зависла (несохранённое пропадёт)'),
            ], ctx),
            _section('2. Папки и проекты', [
              ('projects', 'список проектов с номерами'),
              ('go 10', 'зайти в проект №10'),
              ('files', 'что лежит в текущей папке'),
              ('folder', 'открыть текущую папку в Проводнике'),
              ('open README.md', 'открыть файл из текущей папки'),
              ('cd ..', 'выйти на папку выше'),
            ], ctx),
            _section('3. Работа с проектом', [
              ('vscode 10', 'открыть проект №10 в VS Code'),
              ('claude 10', 'Claude Code в окне на ноутбуке (смотрите во вкладке «Экран»)'),
              ('ask что делает этот проект?', 'Claude ответит прямо здесь'),
              ('ask исправь ошибку в main.dart', 'Claude может менять файлы текущей папки'),
              ('new chat', 'начать разговор с Claude заново'),
            ], ctx),
            _section('4. Unity', [
              ('unity', 'открыть Unity Hub'),
              ('unity 9', 'открыть проект №9 в Unity (в списке помечены [Unity])'),
            ], ctx),
            _section('5. Полезное', [
              ('help', 'список всех команд'),
              ('clear', 'очистить экран терминала'),
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
                      _act(ctx, 'Перейти', 'go ${p.n}'),
                      _act(ctx, 'Проводник', 'folder ${p.n}'),
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
  // ------------------------------------------------------------ terminal look (user can change it)
  _TermTheme get _t => _termThemes[_themeIdx.clamp(0, _termThemes.length - 1)];
  Color get _termBg => _t.bg;
  Color get _termFg => _t.fg;
  Color get _termErr => _t.err;
  Color get _boxBg => Color.lerp(_t.bg, _t.fg, 0.07)!;
  Color get _boxLine => Color.lerp(_t.bg, _t.fg, 0.18)!;
  TextStyle get _ps => (_monoFont == 0
          ? K.code(_fontSize, color: _termFg)
          : TextStyle(
              fontFamily: 'Consolas',
              fontFamilyFallback: const ['Menlo', 'Courier New', 'monospace'],
              fontSize: _fontSize,
              color: _termFg))
      .copyWith(height: 1.45);

  Future<void> _loadLook() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _themeIdx = p.getInt('term_theme') ?? 0;
      _fontSize = p.getDouble('term_font') ?? 14;
      _monoFont = p.getInt('term_mono') ?? 0;
    });
  }

  Future<void> _saveLook() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('term_theme', _themeIdx);
    await p.setDouble('term_font', _fontSize);
    await p.setInt('term_mono', _monoFont);
  }

  Future<void> _loadApps() async {
    try {
      final list = await widget.api.apps();
      if (mounted && list.isNotEmpty) setState(() => _pcApps = list);
    } catch (_) {
      // older server without the list — the built-in buttons stay
    }
  }

  /// Opens one more terminal tab (like «+» in Windows Terminal).
  void _newTerminal() {
    setState(() {
      _tabs.add(_Session(++_tabSeq, widget.info.home));
      _tab = _tabs.length - 1;
      _ctrl.clear();
    });
  }

  void _closeTab(int i) {
    setState(() {
      _tabs.removeAt(i).scroll.dispose();
      if (_tabs.isEmpty) _tabs.add(_Session(++_tabSeq, widget.info.home));
      if (_tab >= i && _tab > 0) _tab--;
      _tab = _tab.clamp(0, _tabs.length - 1);
    });
  }

  /// Tab strip like Windows Terminal: tabs with ✕, then «+».
  Widget _tabStrip() {
    final strip = Color.lerp(_termBg, _termFg, 0.10)!;
    return Container(
      height: 42,
      color: strip,
      child: Row(children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 6, top: 6),
            children: [
              for (var i = 0; i < _tabs.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    width: 170,
                    margin: const EdgeInsets.only(right: 2),
                    padding: const EdgeInsets.only(left: 12, right: 2),
                    decoration: BoxDecoration(
                      color: i == _tab ? _termBg : Colors.transparent,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    ),
                    child: Row(children: [
                      Icon(Icons.terminal_rounded, size: 15, color: _termFg.withValues(alpha: i == _tab ? 1 : 0.6)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Windows PowerShell',
                          overflow: TextOverflow.ellipsis,
                          style: K.t(12.5,
                              color: _termFg.withValues(alpha: i == _tab ? 1 : 0.6),
                              w: i == _tab ? FontWeight.w600 : FontWeight.w500),
                        ),
                      ),
                      if (_tabs[i].busy)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: SizedBox(
                              width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.4, color: _termFg)),
                        ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _closeTab(i),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close_rounded, size: 15, color: _termFg.withValues(alpha: 0.75)),
                        ),
                      ),
                    ]),
                  ),
                ),
              Tooltip(
                message: 'Новый терминал',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _newTerminal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Icon(Icons.add_rounded, size: 20, color: _termFg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  void _showTermSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void apply(VoidCallback f) {
          setState(f);
          setSheet(() {});
          _saveLook();
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(
                    width: 44, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3))),
              ),
              const SizedBox(height: 16),
              Text('Настройки терминала', style: K.t(20, w: FontWeight.w700)),
              const SizedBox(height: 16),
              // preview
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: _termBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: _boxLine)),
                child: Text('PS C:\\Users> help\nКОМАНДЫ …', style: _ps),
              ),
              const SizedBox(height: 18),
              Text('Цветовая схема', style: K.t(13, color: K.muted, w: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < _termThemes.length; i++)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => apply(() => _themeIdx = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: _termThemes[i].bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: i == _themeIdx ? K.lime : Colors.white24, width: i == _themeIdx ? 2 : 1),
                      ),
                      child: Text(_termThemes[i].name,
                          style: K.code(12.5, color: _termThemes[i].fg, w: FontWeight.w700)),
                    ),
                  ),
              ]),
              const SizedBox(height: 18),
              Text('Размер шрифта: ${_fontSize.round()}', style: K.t(13, color: K.muted, w: FontWeight.w600)),
              Slider(
                value: _fontSize,
                min: 10,
                max: 22,
                divisions: 12,
                activeColor: K.lime,
                onChanged: (v) => apply(() => _fontSize = v),
              ),
              Text('Шрифт', style: K.t(13, color: K.muted, w: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final (i, name) in const [(0, 'JetBrains Mono'), (1, 'Consolas')])
                  ChoiceChip(
                    label: Text(name),
                    selected: _monoFont == i,
                    onSelected: (_) => apply(() => _monoFont = i),
                  ),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  Widget _logViewCached() {
    final k = Object.hash(_s.id, _log.length, _log.where((e) => e.output != null).length, _themeIdx, _fontSize,
        _monoFont);
    if (k != _logKey || _logCache == null) {
      _logKey = k;
      _logCache = _logView();
    }
    return _logCache!;
  }

  Widget _appsRowCached() {
    final k = identityHashCode(_pcApps);
    if (k != _appsKey || _appsCache == null) {
      _appsKey = k;
      _appsCache = RepaintBoundary(child: _appsRow());
    }
    return _appsCache!;
  }

  Widget _cmdsCached() {
    final k = Object.hash(_history.length, _history.isEmpty ? '' : _history.last, _themeIdx);
    if (k != _cmdsKey || _cmdsCache == null) {
      _cmdsKey = k;
      _cmdsCache = RepaintBoundary(child: _cmdCarousel());
    }
    return _cmdsCache!;
  }

  Widget _logView() => SelectionArea(
        key: ValueKey(_s.id),
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          itemCount: _log.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                    'Windows PowerShell 5.1\n(C) Корпорация Майкрософт (Microsoft Corporation). Все права защищены.',
                    style: _ps),
              );
            }
            final e = _log[i - 1];
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('PS ${e.cwd}> ${e.cmd}', style: _ps),
                if (e.output == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      SizedBox(
                          width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: _termFg)),
                      if (e.cmd.toLowerCase().startsWith('ask'))
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('Claude думает… это может занять пару минут',
                              style: _ps.copyWith(color: _termFg.withValues(alpha: 0.55))),
                        ),
                    ]),
                  )
                else if (e.output!.isNotEmpty)
                  Text(e.output!, style: _ps.copyWith(color: e.error ? _termErr : _termFg)),
              ]),
            );
          },
        ),
      );

  IconData _appIcon(String name) {
    final n = name.toLowerCase();
    for (final (icon, label, _) in _apps) {
      if (label.toLowerCase() == n) return icon;
    }
    return Icons.apps_rounded;
  }

  Widget _appsRow() {
    final list = _pcApps ?? [for (final (_, label, cmd) in _apps) (label, cmd, true)];
    // only the buttons on screen are built (there can be 100+ programs)
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: list.length + 2,
        itemBuilder: (_, i) {
          final Widget chip;
          if (i == 0) {
            chip = KChip('Новый терминал', icon: Icons.add_rounded, bg: K.lime, fg: K.ink, onTap: _newTerminal);
          } else if (i == 1) {
            chip = KChip('Настройки терминала',
                icon: Icons.tune_rounded, bg: K.panel2, fg: K.white, onTap: _showTermSettings);
          } else {
            final (name, cmd, _) = list[i - 2];
            final c = _chipColors[(i - 2) % _chipColors.length];
            chip = KChip(name, icon: _appIcon(name), bg: c.$1, fg: c.$2, onTap: () => _run(cmd));
          }
          return Padding(padding: const EdgeInsets.only(right: 7, bottom: 4), child: chip);
        },
      ),
    );
  }

  Widget _inputBar(bool keyboard) => Container(
        decoration: BoxDecoration(color: _termBg, border: Border(top: BorderSide(color: _boxLine))),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // program buttons right above the input
          if (!keyboard) Padding(padding: const EdgeInsets.only(bottom: 6), child: _appsRowCached()),
          // possible commands — always shown
          Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 6), child: _cmdsCached()),
          ValueListenableBuilder<String>(
            valueListenable: _hint,
            builder: (_, hint, _) => hint.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Text(hint, style: K.t(12, color: _termFg.withValues(alpha: 0.6), height: 1.3)),
                  ),
          ),
          Container(
            key: _inputKey,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
            decoration: BoxDecoration(
              color: _boxBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _boxLine),
            ),
            child: Row(children: [
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.45),
                  child: Text('PS $_cwd>', style: _ps, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _histStep(-1),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _histStep(1),
                  },
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    style: _ps,
                    cursorColor: _termFg,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (t) {
                      _run(t);
                      _focus.requestFocus();
                    },
                    decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Выполнить',
                icon: _busy
                    ? SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6, color: _termFg))
                    : Icon(Icons.keyboard_return_rounded, size: 20, color: _termFg),
                onPressed: _busy ? null : () => _run(_ctrl.text),
              ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final keyboard = MediaQuery.of(context).viewInsets.bottom > 0;
    return Container(
      color: _termBg,
      child: SafeArea(
        bottom: false,
        child: Column(children: [
          _tabStrip(),
          Expanded(child: RepaintBoundary(child: _logViewCached())),
          _inputBar(keyboard),
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

class _TermTheme {
  final String name;
  final Color bg, fg, err;
  const _TermTheme(this.name, this.bg, this.fg, this.err);
}

const _termThemes = [
  _TermTheme('Campbell', Color(0xFF0C0C0C), Color(0xFFCCCCCC), Color(0xFFF14C4C)),
  _TermTheme('PowerShell', Color(0xFF012456), Color(0xFFEEEDF0), Color(0xFFF14C4C)),
  _TermTheme('One Half Dark', Color(0xFF282C34), Color(0xFFDCDFE4), Color(0xFFE06C75)),
  _TermTheme('Matrix', Color(0xFF000000), Color(0xFF3CF06E), Color(0xFFFF5555)),
  _TermTheme('Solarized', Color(0xFF002B36), Color(0xFF93A1A1), Color(0xFFDC322F)),
  _TermTheme('Light', Color(0xFFF2F2F2), Color(0xFF1E1E1E), Color(0xFFC50F1F)),
];
