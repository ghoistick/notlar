import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import 'join_screen.dart';
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
  _Mode _mode = _Mode.choose;

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

  Widget _choice(BuildContext context) {
    return LockLayout(
      title: 'Müsvedde\'ye hoş geldin',
      message: 'Bu cihazda Müsvedde\'yi nasıl kullanmak istersin?',
      children: [
        _ChoiceCard(
          icon: Icons.note_add_outlined,
          title: 'Yeni kasa oluştur',
          text: 'Müsvedde\'yi ilk kez kullanıyorsan. Notların için yeni bir '
              'ana parola belirlersin.',
          onTap: () => setState(() => _mode = _Mode.create),
        ),
        const SizedBox(height: 12),
        _ChoiceCard(
          icon: Icons.cloud_download_outlined,
          title: 'Mevcut senkronizasyona katıl',
          text: 'Başka bir cihazda zaten kullanıyorsan. Google hesabına bağlanır, '
              'o cihazdaki ana parolanla notlarını buraya getirirsin.',
          onTap: () => setState(() => _mode = _Mode.join),
        ),
      ],
    );
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

    if (_mode == _Mode.choose) return _choice(context);
    if (_mode == _Mode.join) {
      return JoinScreen(onBack: () => setState(() => _mode = _Mode.choose));
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
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _mode = _Mode.choose),
          child: const Text('Geri dön'),
        ),
      ],
    );
  }
}

enum _Mode { choose, create, join }

class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(text,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
              ]),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
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
              fontFamily: 'IBM Plex Mono',
              fontFamilyFallback: const ['Consolas', 'Roboto Mono', 'monospace'],
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
