import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'claude/claude_term.dart';
import 'kraken/kraken.dart';
import 'main.dart' show homeTabs;

/// One terminal tab: its own output, folder and scroll position.
/// A Claude Code tab is a real console on the PC instead ([claude]).
class _Session {
  final int id;
  final List<_Entry> log = [];
  String cwd;
  bool busy = false;
  final scroll = ScrollController();
  ClaudeSession? claude;
  _Session(this.id, this.cwd, {this.claude});
}

class _Entry {
  final String cwd;
  final String cmd;
  String? output;
  bool error = false;
  _Entry(this.cwd, this.cmd);
}

const _claudeColor = Color(0xFFD97757); // Claude's orange

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
  // Rebuilding the output on every key press made typing lag on phones:
  // the heavy parts are built once and reused until they really change.
  Widget? _logCache, _chipsCache;
  int? _logKey;
  bool _dockOpen = true;
  // keeps the input field the same widget while rows above it appear/disappear,
  // otherwise it is rebuilt and the phone keyboard closes after one letter
  final _inputKey = GlobalKey();
  int _themeIdx = 0;
  double _fontSize = 14;
  int _monoFont = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadLook();
  }

  Widget _chipsRowCached() => _chipsCache ??= RepaintBoundary(
        child: SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final chip in [
                KChip('Новый терминал', icon: Icons.add_rounded, bg: K.lime, fg: K.ink, onTap: _newTerminal),
                KChip('Claude Code', icon: Icons.auto_awesome_rounded, bg: _claudeColor, fg: K.ink, onTap: _newClaude),
                KChip('Настройки терминала',
                    icon: Icons.tune_rounded, bg: K.panel2, fg: K.white, onTap: _showTermSettings),
              ])
                Padding(padding: const EdgeInsets.only(right: 7, bottom: 4), child: chip),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------ history / commands sheets
  Widget _sheet(String title, String sub, List<Widget> rows) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            Center(
              child: Container(
                  width: 44, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3))),
            ),
            const SizedBox(height: 14),
            Text(title, style: K.t(20, w: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(sub, style: K.t(12.5, color: K.muted, w: FontWeight.w400, height: 1.4)),
            const SizedBox(height: 10),
            ...rows,
          ],
        ),
      );

  Widget _cmdRow(BuildContext ctx, String cmd, [String? what]) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          Navigator.pop(ctx);
          _insert(cmd);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cmd, style: K.code(13.5, color: K.lime, w: FontWeight.w700)),
            if (what != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(what, style: K.t(12.5, color: Colors.white70, w: FontWeight.w400, height: 1.35)),
              ),
          ]),
        ),
      );

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _sheet(
        'История команд',
        _history.isEmpty ? 'Здесь появятся команды, которые вы выполняли.' : 'Нажмите — команда появится в строке ввода.',
        [for (final c in _history.reversed) _cmdRow(ctx, c)],
      ),
    );
  }

  void _showCommands() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _sheet(
        'Команды PowerShell',
        'Нажмите — команда появится в строке ввода. Слова в <скобках> замените своими.',
        [
          for (final (group, list) in _psCommands) ...[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 2),
              child: Text(group, style: K.t(14, color: K.lilac, w: FontWeight.w700)),
            ),
            for (final (cmd, what) in list) _cmdRow(ctx, cmd, what),
          ],
        ],
      ),
    );
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
    _openKeyboard();
  }

  /// iPhone Safari can hide the keyboard while the field stays focused, and then a tap on
  /// the field does nothing. Ask for the keyboard explicitly every time.
  void _openKeyboard() {
    if (_focus.hasFocus) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _focus.requestFocus();
    }
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

  /// Opens one more terminal tab (like «+» in Windows Terminal).
  void _newTerminal() {
    setState(() {
      _tabs.add(_Session(++_tabSeq, widget.info.home));
      _tab = _tabs.length - 1;
      _ctrl.clear();
    });
  }

  /// Opens Claude Code (exactly as in Windows Terminal) in the folder of the current tab.
  void _newClaude() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _tabs.add(_Session(++_tabSeq, _cwd, claude: ClaudeSession(widget.api, _cwd)));
      _tab = _tabs.length - 1;
    });
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.claude?.kill();
    }
    super.dispose();
  }

  void _closeTab(int i) {
    _tabs[i].claude?.kill();
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
                      Icon(_tabs[i].claude != null ? Icons.auto_awesome_rounded : Icons.terminal_rounded,
                          size: 15,
                          color: _tabs[i].claude != null
                              ? _claudeColor.withValues(alpha: i == _tab ? 1 : 0.7)
                              : _termFg.withValues(alpha: i == _tab ? 1 : 0.6)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tabs[i].claude != null ? 'Claude Code' : 'Windows PowerShell',
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

  Widget _inputBar(bool keyboard) => Container(
        decoration: BoxDecoration(color: _termBg, border: Border(top: BorderSide(color: _boxLine))),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // new terminal / Claude Code / settings right above the input
          if (!keyboard) Padding(padding: const EdgeInsets.only(bottom: 6), child: _chipsRowCached()),
          GestureDetector(
            key: _inputKey,
            behavior: HitTestBehavior.translucent,
            onTap: _openKeyboard, // the whole input line, the «PS C:\\…>» part too
            child: Container(
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
                    onTap: _openKeyboard,
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
          )),
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
          if (_s.claude != null) ...[
            Expanded(
              child: ClaudeView(
                key: ValueKey(_s.id),
                session: _s.claude!,
                bg: _termBg,
                fg: _termFg,
                fontSize: (_fontSize - 2).clamp(9, 20),
                // the same chips as in the PowerShell tab: new terminal, Claude Code, settings
                above: keyboard ? null : _chipsRowCached(),
              ),
            ),
          ] else ...[
            Expanded(child: RepaintBoundary(child: _logViewCached())),
            _inputBar(keyboard),
          ],
          if (!keyboard)
            KrakenDock(
              tabs: homeTabs,
              tab: widget.tab,
              onTab: widget.onTab,
              actions: [
                DockAction(Icons.history_rounded, 'История', _showHistory),
                DockAction(Icons.list_alt_rounded, 'Команды', _showCommands),
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

/// Real PowerShell commands for the «Команды» list (nothing RemoteDesk-specific).
const _psCommands = <(String, List<(String, String)>)>[
  ('Папки и файлы', [
    ('ls', 'что лежит в текущей папке (Get-ChildItem, dir)'),
    ('cd <папка>', 'перейти в папку'),
    ('cd ..', 'на папку выше'),
    ('cd ~', 'в домашнюю папку'),
    ('pwd', 'где я сейчас'),
    ('mkdir <имя>', 'создать папку'),
    ('ni <файл.txt>', 'создать пустой файл (New-Item)'),
    ('cat <файл>', 'показать текст файла (Get-Content)'),
    ('cp <откуда> <куда>', 'копировать (Copy-Item)'),
    ('mv <откуда> <куда>', 'переместить (Move-Item)'),
    ('ren <файл> <новое имя>', 'переименовать (Rename-Item)'),
    ('rm <файл>', 'удалить (Remove-Item)'),
    ('ls -Recurse -Filter *.txt', 'найти файлы по маске во всех вложенных папках'),
    ('explorer .', 'открыть текущую папку в Проводнике'),
  ]),
  ('Программы и процессы', [
    ('start <программа или файл>', 'запустить (Start-Process), например start notepad'),
    ('Get-Process', 'запущенные процессы (ps)'),
    ('Stop-Process -Name <имя>', 'завершить процесс (kill)'),
    ('tasklist', 'список задач'),
    ('taskkill /IM <имя.exe> /F', 'принудительно закрыть программу'),
  ]),
  ('Система и сеть', [
    ('ipconfig', 'IP-адреса компьютера'),
    ('ping <адрес>', 'проверить связь, например ping google.com'),
    ('Test-NetConnection <адрес> -Port <порт>', 'открыт ли порт'),
    ('hostname', 'имя компьютера'),
    ('whoami', 'текущий пользователь'),
    ('systeminfo', 'сведения о системе'),
    ('Get-Date', 'дата и время'),
    ('Get-PSDrive -PSProvider FileSystem', 'диски и свободное место'),
    ('Get-Volume', 'тома дисков'),
  ]),
  ('Текст и вывод', [
    ('echo <текст>', 'вывести текст (Write-Output)'),
    ('<команда> | Select-String <слово>', 'найти строки со словом'),
    ('<команда> | Out-File <файл.txt>', 'сохранить вывод в файл'),
    ('cls', 'очистить экран (Clear-Host)'),
  ]),
  ('Справка', [
    ('Get-Help <команда>', 'справка по команде (help)'),
    ('Get-Command', 'все доступные команды'),
    ('Get-History', 'история команд PowerShell'),
  ]),
  ('Разработка', [
    ('git status', 'состояние репозитория'),
    ('git pull', 'забрать изменения'),
    ('python --version', 'версия Python'),
    ('code .', 'открыть текущую папку в VS Code'),
    ('winget search <название>', 'найти программу для установки'),
  ]),
];

const _termThemes = [
  _TermTheme('Campbell', Color(0xFF0C0C0C), Color(0xFFCCCCCC), Color(0xFFF14C4C)),
  _TermTheme('PowerShell', Color(0xFF012456), Color(0xFFEEEDF0), Color(0xFFF14C4C)),
  _TermTheme('One Half Dark', Color(0xFF282C34), Color(0xFFDCDFE4), Color(0xFFE06C75)),
  _TermTheme('Matrix', Color(0xFF000000), Color(0xFF3CF06E), Color(0xFFFF5555)),
  _TermTheme('Solarized', Color(0xFF002B36), Color(0xFF93A1A1), Color(0xFFDC322F)),
  _TermTheme('Light', Color(0xFFF2F2F2), Color(0xFF1E1E1E), Color(0xFFC50F1F)),
];
