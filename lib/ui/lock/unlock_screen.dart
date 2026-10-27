import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/quick_unlock.dart';
import '../../app/session.dart';
import '../../core/crypto/key_manager.dart';
import '../../update/update_service.dart';
import '../update/update_dialog.dart';
import 'lock_widgets.dart';

enum _Mode { loading, pin, password, recovery }

/// Kilit ekranı: PIN / parmak izi (kuruluysa), ana parola, kurtarma anahtarı.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _pin = TextEditingController();
  final _password = TextEditingController();
  final _recovery = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  _Mode _mode = _Mode.loading;
  QuickUnlockState? _quick;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _loadQuick();
  }

  @override
  void dispose() {
    _pin.dispose();
    _password.dispose();
    _recovery.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _loadQuick() async {
    QuickUnlockState? st;
    try {
      st = await ref.read(quickUnlockProvider).state();
    } catch (_) {}
    if (!mounted) return;

    if (st != null && st.passwordDue(DateTime.now())) {
      setState(() {
        _mode = _Mode.password;
        _notice = 'Ana parolanı unutmaman için 14 günde bir ana parola '
            'soruluyor. Sonra yine PIN ile açabilirsin.';
      });
      return;
    }
    setState(() {
      _quick = st;
      _mode = st != null ? _Mode.pin : _Mode.password;
    });
    if (st?.biometric == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
    }
  }

  void _toPassword({String? error}) => setState(() {
        _mode = _Mode.password;
        _error = error;
      });

  // ------------------------------------------------------------------ PIN

  Future<void> _unlockPin() async {
    if (!QuickUnlock.isValidPin(_pin.text) || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).unlockWithPin(_pin.text);
    } on WrongPinException catch (e) {
      _pin.clear();
      if (e.attemptsLeft == 0) {
        _quick = null;
        _toPassword(
            error: 'Çok fazla yanlış PIN denemesi. Güvenlik için hızlı kilit '
                'açma kapatıldı; ana parolanla aç.');
      } else {
        setState(() => _error = 'PIN yanlış. ${e.attemptsLeft} deneme hakkın kaldı.');
      }
    } on QuickUnlockUnavailable catch (e) {
      _quick = null;
      _toPassword(error: e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Kilit açılamadı: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometric() async {
    if (_busy) return;
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Müsvedde\'yi açmak için kimliğini doğrula',
        biometricOnly: true,
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      await ref.read(sessionProvider.notifier).unlockWithBiometric();
    } on QuickUnlockUnavailable catch (e) {
      _quick = null;
      _toPassword(error: e.message);
    } catch (_) {
      // Vazgeçildi ya da parmak izi kullanılamıyor: PIN ile devam edilir.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------- Parola

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

  // ------------------------------------------------------------- Görünüm

  Widget _updateButton() => ListenableBuilder(
        listenable: ref.watch(updateServiceProvider),
        builder: (context, _) {
          final update = ref.read(updateServiceProvider).available;
          if (update == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: OutlinedButton.icon(
              onPressed: () => showAboutUpdateDialog(context),
              icon: const Icon(Icons.system_update_alt, size: 18),
              label: Text('Yeni sürüm hazır: ${update.version}'),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    switch (_mode) {
      case _Mode.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));

      case _Mode.pin:
        return LockLayout(
          title: 'Müsvedde',
          message: 'PIN kodunu gir.',
          children: [
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: QuickUnlock.maxPinLength,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(counterText: '', errorText: _error),
              onSubmitted: (_) => _unlockPin(),
            ),
            const SizedBox(height: 16),
            BusyButton(label: 'Aç', busy: _busy, onPressed: _unlockPin),
            if (_quick?.biometric == true) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _biometric,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Parmak iziyle aç'),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => _toPassword(),
              child: const Text('Ana parolayla aç'),
            ),
            _updateButton(),
          ],
        );

      case _Mode.recovery:
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
            BusyButton(label: 'Yeni parolayı kaydet', busy: _busy, onPressed: _reset),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => _toPassword(),
              child: const Text('Geri dön'),
            ),
          ],
        );

      case _Mode.password:
        return LockLayout(
          title: 'Müsvedde',
          message: _notice ?? 'Devam etmek için ana parolanı gir.',
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
            if (_quick != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _mode = _Mode.pin;
                          _error = null;
                        }),
                child: const Text('PIN ile aç'),
              ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _mode = _Mode.recovery;
                        _error = null;
                      }),
              child: const Text('Parolamı unuttum'),
            ),
            _updateButton(),
          ],
        );
    }
  }
}
