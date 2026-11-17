import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../kraken/kraken.dart';
import '../main.dart' show homeTabs;
import 'download.dart';

/// «Файлы» tab: send phone files to the PC, take PC files to the phone,
/// and the lists of what was sent and what was received.
class FilesScreen extends StatefulWidget {
  final Api api;
  final bool active;
  final int tab;
  final ValueChanged<int> onTab;
  const FilesScreen({super.key, required this.api, required this.active, required this.tab, required this.onTab});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  List<Transfer> _all = [];
  String _kind = 'sent'; // which list is shown
  bool _loading = true;
  String? _error;
  String? _status; // «Отправляю …» / «Готово»
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _syncPoll();
  }

  @override
  void didUpdateWidget(FilesScreen old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      if (widget.active) _refresh();
      _syncPoll();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // files sent from the Claude Code tab show up here too, so the list is re-read while the tab is open
  void _syncPoll() {
    _poll?.cancel();
    _poll = widget.active ? Timer.periodic(const Duration(seconds: 6), (_) => _refresh(quiet: true)) : null;
  }

  Future<void> _refresh({bool quiet = false}) async {
    try {
      final l = await widget.api.transfers();
      if (!mounted) return;
      setState(() {
        _all = l;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || quiet) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось получить список: $e';
      });
    }
  }

  // ---------------------------------------------------------------- phone → PC
  Future<void> _send() async {
    if (_busy) return;
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    } catch (e) {
      setState(() => _status = 'Не открылся выбор файлов: $e');
      return;
    }
    if (res == null || res.files.isEmpty) return;
    setState(() {
      _busy = true;
      _kind = 'sent';
    });
    var ok = 0;
    final files = res.files;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final bytes = f.bytes;
      if (bytes == null) continue;
      setState(() => _status = files.length > 1
          ? 'Отправляю ${i + 1} из ${files.length}: ${f.name} (${_size(bytes.length)})…'
          : 'Отправляю ${f.name} (${_size(bytes.length)})…');
      try {
        await widget.api.upload(f.name, bytes);
        ok++;
      } catch (e) {
        if (mounted) setState(() => _status = 'Не отправился ${f.name}: $e');
        break;
      }
      await _refresh(quiet: true);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok > 0) {
        _status = ok == 1 ? 'Готово: файл на ПК в «Загрузки\\RemoteDesk»' : 'Готово: $ok файлов на ПК в «Загрузки\\RemoteDesk»';
      }
    });
    HapticFeedback.mediumImpact();
  }

  // ---------------------------------------------------------------- PC → phone
  void _download(String path, String name) {
    if (!startDownload(widget.api.downloadUrl(path), name)) {
      setState(() => _status = 'Скачивание работает в браузере: откройте RemoteDesk в Safari');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _status = 'Скачиваю $name — Safari сохранит его в «Файлы» → «Загрузки»';
      _kind = 'recv';
    });
    Future.delayed(const Duration(milliseconds: 1500), () => _refresh(quiet: true));
  }

  void _receive() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, sc) => _PcBrowser(
          api: widget.api,
          scroll: sc,
          onPick: (e) {
            Navigator.of(ctx).pop();
            _download(e.path, e.name);
          },
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final label = _kind == 'sent' ? 'отправленных' : 'полученных';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: K.panel,
        title: Text('Очистить список $label?', style: K.t(17, w: FontWeight.w700)),
        content: Text('Сами файлы останутся на ПК и на телефоне.', style: K.t(14, color: K.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.api.clearTransfers(_kind);
    } catch (e) {
      if (mounted) setState(() => _status = 'Не очистилось: $e');
    }
    _refresh();
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final sent = _all.where((t) => t.kind == 'sent').toList();
    final recv = _all.where((t) => t.kind == 'recv').toList();
    final shown = _kind == 'sent' ? sent : recv;
    return Container(
      color: K.ink,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: Row(children: [
                  Expanded(child: Text('Файлы', style: K.h(28))),
                  Text(widget.api.host, style: K.t(12, color: K.muted)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: _Segments(
                  left: 'Отправлено  ${sent.length}',
                  right: 'Получено  ${recv.length}',
                  isLeft: _kind == 'sent',
                  onChange: (l) => setState(() => _kind = l ? 'sent' : 'recv'),
                ),
              ),
              Expanded(child: _list(shown)),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                  child: Row(children: [
                    if (_busy) ...[
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: Text(_status!, style: K.t(12.5, color: K.muted), maxLines: 2)),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(children: [
                  Expanded(
                    child: _BigButton(Icons.upload_rounded, 'Отправить на ПК', K.yellow, _busy ? null : _send),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _BigButton(Icons.download_rounded, 'Получить с ПК', K.white, _receive)),
                ]),
              ),
              KrakenDock(
                tabs: homeTabs,
                tab: widget.tab,
                onTab: widget.onTab,
                actions: [
                  DockAction(Icons.refresh_rounded, 'Обновить', _refresh),
                  DockAction(Icons.delete_sweep_rounded, 'Очистить', _clear),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _list(List<Transfer> items) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && items.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, style: K.t(14, color: K.coral), textAlign: TextAlign.center)));
    }
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_kind == 'sent' ? Icons.upload_file_rounded : Icons.file_download_outlined, size: 46, color: K.muted),
            const SizedBox(height: 12),
            Text(
              _kind == 'sent'
                  ? 'Вы ещё ничего не отправили.\nНажмите «Отправить на ПК».'
                  : 'Вы ещё ничего не получили.\nНажмите «Получить с ПК».',
              textAlign: TextAlign.center,
              style: K.t(14, color: K.muted, height: 1.4),
            ),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _TransferTile(
          t: items[i],
          onTap: () => _tapItem(items[i]),
        ),
      ),
    );
  }

  void _tapItem(Transfer t) {
    if (!t.exists) {
      setState(() => _status = 'Файла «${t.name}» больше нет на ПК');
      return;
    }
    if (t.kind == 'recv') {
      _download(t.path, t.name); // download again
    } else {
      Clipboard.setData(ClipboardData(text: t.path));
      setState(() => _status = 'Путь на ПК скопирован: ${t.path}');
    }
  }
}

String _size(int b) {
  if (b < 1024) return '$b Б';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} КБ';
  if (b < 1024 * 1024 * 1024) return '${(b / 1048576).toStringAsFixed(1)} МБ';
  return '${(b / 1073741824).toStringAsFixed(2)} ГБ';
}

String _when(DateTime t) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return 'сегодня $hm';
  final y = now.subtract(const Duration(days: 1));
  if (t.year == y.year && t.month == y.month && t.day == y.day) return 'вчера $hm';
  return '${two(t.day)}.${two(t.month)}.${t.year} $hm';
}

IconData _iconFor(String name, {bool dir = false}) {
  if (dir) return Icons.folder_rounded;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const img = {'jpg', 'jpeg', 'png', 'heic', 'gif', 'webp', 'bmp'};
  const vid = {'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'};
  const aud = {'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'};
  const arc = {'zip', 'rar', '7z', 'tar', 'gz'};
  const doc = {'pdf', 'doc', 'docx', 'txt', 'rtf', 'epub', 'fb2', 'md', 'xls', 'xlsx', 'ppt', 'pptx'};
  if (img.contains(ext)) return Icons.image_rounded;
  if (vid.contains(ext)) return Icons.movie_rounded;
  if (aud.contains(ext)) return Icons.music_note_rounded;
  if (arc.contains(ext)) return Icons.folder_zip_rounded;
  if (doc.contains(ext)) return Icons.description_rounded;
  if (ext == 'exe' || ext == 'msi' || ext == 'apk') return Icons.apps_rounded;
  return Icons.insert_drive_file_rounded;
}

class _TransferTile extends StatelessWidget {
  final Transfer t;
  final VoidCallback onTap;
  const _TransferTile({required this.t, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sent = t.kind == 'sent';
    return Material(
      color: K.panel,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: K.panel2, borderRadius: BorderRadius.circular(12)),
              child: Icon(_iconFor(t.name), color: t.exists ? K.white : K.muted, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: K.t(14.5, w: FontWeight.w600, color: t.exists ? K.white : K.muted)),
                const SizedBox(height: 3),
                Text('${_size(t.size)} · ${_when(t.time)}${t.exists ? '' : ' · удалён с ПК'}',
                    style: K.t(12, color: K.muted)),
                Text(t.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: K.t(11, color: const Color(0xFF6A6A78))),
              ]),
            ),
            const SizedBox(width: 6),
            Icon(sent ? Icons.north_east_rounded : Icons.south_west_rounded, size: 18, color: sent ? K.yellow : K.lime),
          ]),
        ),
      ),
    );
  }
}

class _Segments extends StatelessWidget {
  final String left, right;
  final bool isLeft;
  final ValueChanged<bool> onChange;
  const _Segments({required this.left, required this.right, required this.isLeft, required this.onChange});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool on, VoidCallback tap) => Expanded(
          child: GestureDetector(
            onTap: tap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: on ? K.white : Colors.transparent, borderRadius: BorderRadius.circular(20)),
              child: Text(label, style: K.t(13.5, w: FontWeight.w700, color: on ? K.ink : K.muted)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: K.panel, borderRadius: BorderRadius.circular(24), border: Border.all(color: K.line)),
      child: Row(children: [
        seg(left, isLeft, () => onChange(true)),
        seg(right, !isLeft, () => onChange(false)),
      ]),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final VoidCallback? onTap;
  const _BigButton(this.icon, this.label, this.bg, this.onTap);

  @override
  Widget build(BuildContext context) => Material(
        color: onTap == null ? bg.withValues(alpha: 0.4) : bg,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(
            height: 54,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: K.ink),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: K.t(14.5, color: K.ink, w: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      );
}

/// PC folders in a bottom sheet; tapping a file downloads it to the phone.
class _PcBrowser extends StatefulWidget {
  final Api api;
  final ScrollController scroll;
  final ValueChanged<PcEntry> onPick;
  const _PcBrowser({required this.api, required this.scroll, required this.onPick});

  @override
  State<_PcBrowser> createState() => _PcBrowserState();
}

class _PcBrowserState extends State<_PcBrowser> {
  PcFolder? _f;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open('');
  }

  Future<void> _open(String path) async {
    setState(() => _loading = true);
    try {
      final f = await widget.api.listFiles(path);
      if (!mounted) return;
      setState(() {
        _f = f;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    final title = f == null || f.path.isEmpty ? 'Файлы на ПК' : f.path;
    return Column(children: [
      const SizedBox(height: 10),
      Container(width: 40, height: 4, decoration: BoxDecoration(color: K.line, borderRadius: BorderRadius.circular(2))),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
        child: Row(children: [
          if (f != null && f.parent != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: _loading ? null : () => _open(f.parent!),
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: f == null || f.path.isEmpty ? K.h(22) : K.t(14, w: FontWeight.w700)),
          ),
          if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Нажмите на файл — он скачается на телефон', style: K.t(12, color: K.muted)),
        ),
      ),
      Expanded(child: _body()),
    ]);
  }

  Widget _body() {
    final f = _f;
    if (_error != null) {
      return Center(child: Text(_error!, style: K.t(14, color: K.coral), textAlign: TextAlign.center));
    }
    if (f == null) return const SizedBox.shrink();
    if (f.items.isEmpty) return Center(child: Text('Папка пустая', style: K.t(14, color: K.muted)));
    return ListView.builder(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
      itemCount: f.items.length,
      itemBuilder: (_, i) {
        final e = f.items[i];
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: Icon(_iconFor(e.name, dir: e.dir), color: e.dir ? K.yellow : K.white),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: K.t(14.5, w: FontWeight.w600)),
          subtitle: e.dir || f.path.isEmpty
              ? null
              : Text('${_size(e.size)} · ${_when(DateTime.fromMillisecondsSinceEpoch((e.time * 1000).round()))}',
                  style: K.t(12, color: K.muted)),
          trailing: Icon(e.dir ? Icons.chevron_right_rounded : Icons.download_rounded, color: K.muted),
          onTap: _loading ? null : () => e.dir ? _open(e.path) : widget.onPick(e),
        );
      },
    );
  }
}
