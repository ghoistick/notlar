import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import '../../core/crypto/key_manager.dart';
import 'lock_widgets.dart';

/// Kilit ekranı. "Parolamı unuttum" ile kurtarma anahtarı moduna geçer.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _password = TextEditingController();
  final _recovery = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  bool _recoveryMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _recovery.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).unlock(_password.text);
    } on WrongPasswordException {
      if (mounted) setState(() => _error = 'Parola yanlış.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Kilit açılamadı: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final problem = validateNewPassword(_newPassword.text, _confirm.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .resetPassword(_recovery.text, _newPassword.text);
    } on InvalidRecoveryKeyException {
      if (mounted) setState(() => _error = 'Kurtarma anahtarı geçersiz.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Parola sıfırlanamadı: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleMode() => setState(() {
        _recoveryMode = !_recoveryMode;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    if (_recoveryMode) {
      return LockLayout(
        title: 'Parolanı sıfırla',
        message: 'Kurtarma anahtarını ve yeni ana parolanı gir. '
            'Notların silinmez, yalnızca parola değişir.',
        children: [
          TextField(
            controller: _recovery,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Kurtarma anahtarı',
              hintText: 'XXXX-XXXX-XXXX-…',
            ),
          ),
          const SizedBox(height: 12),
          PasswordField(
            controller: _newPassword,
            label: 'Yeni ana parola',
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          PasswordField(
            controller: _confirm,
            label: 'Yeni parolayı tekrar yaz',
            errorText: _error,
            onSubmitted: (_) => _reset(),
          ),
          const SizedBox(height: 20),
          BusyButton(
              label: 'Yeni parolayı kaydet', busy: _busy, onPressed: _reset),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _toggleMode,
            child: const Text('Geri dön'),
          ),
        ],
      );
    }

    return LockLayout(
      title: 'Notlar',
      message: 'Devam etmek için ana parolanı gir.',
      children: [
        PasswordField(
          controller: _password,
          label: 'Ana parola',
          autofocus: true,
          errorText: _error,
          onSubmitted: (_) => _unlock(),
        ),
        const SizedBox(height: 20),
        BusyButton(label: 'Kilidi aç', busy: _busy, onPressed: _unlock),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _toggleMode,
          child: const Text('Parolamı unuttum'),
        ),
      ],
    );
  }
}
