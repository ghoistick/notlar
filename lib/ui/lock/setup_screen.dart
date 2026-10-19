import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import 'lock_widgets.dart';

/// İlk açılış: ana parola belirlenir, ardından kurtarma anahtarı gösterilir.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;
  String? _recoveryKey;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final problem = validateNewPassword(_password.text, _confirm.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = await ref
          .read(sessionProvider.notifier)
          .createVault(_password.text);
      _password.clear();
      _confirm.clear();
      setState(() => _recoveryKey = key);
    } catch (e) {
      setState(() => _error = 'Kurulum tamamlanamadı: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = _recoveryKey;
    if (key != null) {
      return _RecoveryKeyView(
        recoveryKey: key,
        onContinue: () => ref.read(sessionProvider.notifier).finishSetup(),
      );
    }

    return LockLayout(
      title: 'Ana parolanı belirle',
      message: 'Notların bu parolayla şifrelenir. Parolayı unutursan '
          'notlarına yalnızca bir sonraki adımda vereceğim kurtarma '
          'anahtarıyla ulaşabilirsin.',
      children: [
        PasswordField(
          controller: _password,
          label: 'Ana parola',
          autofocus: true,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        PasswordField(
          controller: _confirm,
          label: 'Parolayı tekrar yaz',
          errorText: _error,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 20),
        BusyButton(label: 'Parolayı belirle', busy: _busy, onPressed: _submit),
      ],
    );
  }
}

class _RecoveryKeyView extends StatefulWidget {
  final String recoveryKey;
  final VoidCallback onContinue;

  const _RecoveryKeyView({required this.recoveryKey, required this.onContinue});

  @override
  State<_RecoveryKeyView> createState() => _RecoveryKeyViewState();
}

class _RecoveryKeyViewState extends State<_RecoveryKeyView> {
  bool _saved = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.recoveryKey));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Kopyalandı. Kaydettikten sonra panoyu temizlemeyi unutma.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LockLayout(
      title: 'Kurtarma anahtarın',
      message: 'Parolanı unutursan notlarını bu anahtarla açarsın. Bir kâğıda '
          'yaz ya da parola yöneticine kaydet. Bu anahtar bir daha '
          'gösterilmeyecek.',
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            widget.recoveryKey,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'Consolas',
              fontFamilyFallback: const ['Roboto Mono', 'monospace'],
              letterSpacing: 1.2,
              height: 1.6,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Kopyala'),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          value: _saved,
          onChanged: (v) => setState(() => _saved = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Kurtarma anahtarını güvenli bir yere kaydettim'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _saved ? widget.onContinue : null,
          child: const Text('Devam et'),
        ),
      ],
    );
  }
}
