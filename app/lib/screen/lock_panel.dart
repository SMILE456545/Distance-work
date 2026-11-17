import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../kraken/kraken.dart';

/// Shown over the screen tab while Windows is on the lock screen:
/// the PIN / password typed here is entered on the PC (it is not saved anywhere).
class LockPanel extends StatefulWidget {
  final Api api;

  /// The unlock helper is installed on the PC.
  final bool agent;
  final VoidCallback onUnlocked;
  const LockPanel({super.key, required this.api, required this.agent, required this.onUnlocked});

  @override
  State<LockPanel> createState() => _LockPanelState();
}

class _LockPanelState extends State<LockPanel> {
  static const _field = Color(0xFF141417);
  final _pin = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final pin = _pin.text;
    if (pin.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      err = await widget.api.unlock(pin);
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) {
      HapticFeedback.mediumImpact();
      FocusManager.instance.primaryFocus?.unfocus();
      widget.onUnlocked();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: K.ink.withValues(alpha: 0.92),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
            decoration: BoxDecoration(
              color: const Color(0xFF0E0E11),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF232328)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, color: Colors.white, size: 30),
                const SizedBox(height: 14),
                Text('Компьютер заблокирован', textAlign: TextAlign.center, style: K.t(19, w: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  widget.agent
                      ? 'Введите PIN-код или пароль Windows — он будет набран на экране блокировки. Нигде не сохраняется.'
                      : 'Разблокировка с телефона ещё не включена. Запустите RemoteDesk на компьютере и нажмите «Да» в запросе Windows.',
                  textAlign: TextAlign.center,
                  style: K.t(12.5, color: const Color(0xFF8A8A92), w: FontWeight.w400, height: 1.5),
                ),
                if (widget.agent) ...[
                  const SizedBox(height: 20),
                  TextField(
                    controller: _pin,
                    obscureText: !_show,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _unlock(),
                    onChanged: (_) => setState(() {}),
                    style: K.code(15, w: FontWeight.w700),
                    decoration: InputDecoration(
                      hintText: 'PIN-код или пароль',
                      hintStyle: K.t(13, color: const Color(0xFF5E5E66), w: FontWeight.w400),
                      filled: true,
                      fillColor: _field,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      suffixIcon: IconButton(
                        icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            size: 18, color: const Color(0xFF6A6A72)),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFF232328))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.white, width: 1.4)),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: K.t(12, color: K.coral, w: FontWeight.w500, height: 1.4)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 46,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: K.ink,
                        disabledBackgroundColor: Colors.white.withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _busy || _pin.text.isEmpty ? null : _unlock,
                      child: _busy
                          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: K.ink)),
                              const SizedBox(width: 10),
                              Text('Разблокирую…', style: K.t(14, color: K.ink, w: FontWeight.w600)),
                            ])
                          : Text('Разблокировать', style: K.t(14, color: K.ink, w: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
