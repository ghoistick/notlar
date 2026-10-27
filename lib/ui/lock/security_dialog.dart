import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/app_settings.dart';
import '../../app/quick_unlock.dart';
import '../../app/session.dart';
import '../common/dialogs.dart';

Future<void> showSecurityDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _SecurityDialog());
}

class _SecurityDialog extends ConsumerStatefulWidget {
  const _SecurityDialog();

  @override
  ConsumerState<_SecurityDialog> createState() => _SecurityDialogState();
}

class _SecurityDialogState extends ConsumerState<_SecurityDialog> {
  QuickUnlockState? _state;
  bool _biometricAvailable = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = await ref.read(quickUnlockProvider).state();
    var bio = false;
    try {
      final auth = LocalAuthentication();
      bio = await auth.isDeviceSupported() &&
          (await auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _state = st;
      _biometricAvailable = bio;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPin() async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _PinDialog(
        biometricAvailable: _biometricAvailable,
        biometricInitially: _state?.biometric ?? _biometricAvailable,
      ),
    );
    if (result == null) return;
    final (pin, biometric) = result;
    await _run(() => ref.read(quickUnlockProvider).enable(
          dataKey: ref.read(vaultProvider).dataKeyCopy(),
          pin: pin,
          biometric: biometric,
        ));
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value) {
      // Parmak izinin gerçekten çalıştığını açmadan önce doğrula.
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Parmak iziyle açmayı etkinleştir',
        biometricOnly: true,
      );
      if (!ok) return;
    }
    await _run(() => ref
        .read(quickUnlockProvider)
        .setBiometric(value, ref.read(vaultProvider).dataKeyCopy()));
  }

  Future<void> _disable() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Hızlı kilit açma kapatılsın mı?',
      message: 'Bundan sonra uygulamayı yalnızca ana parolanla açabilirsin.',
      confirmLabel: 'Kapat',
    );
    if (ok) await _run(() => ref.read(quickUnlockProvider).disable());
  }

  static String _lockLabel(int m) => switch (m) {
        0 => 'Hemen',
        -1 => 'Hiçbir zaman',
        60 => '1 saat sonra',
        _ => '$m dakika sonra',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final st = _state;
    final autoLock = ref.watch(autoLockProvider);

    return AlertDialog(
      title: const Text('Kilit ve güvenlik'),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Hızlı kilit açma',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      st == null
                          ? 'Kapalı. Uygulamayı her seferinde ana parolanla açıyorsun.'
                          : 'Açık: PIN${st.biometric ? ' ve parmak izi' : ''}.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'PIN yalnızca bu cihazda geçerli ve cihazın güvenli '
                      'deposundaki bir anahtarla birlikte çalışır. '
                      '${QuickUnlock.maxAttempts} yanlış denemede kapanır. Ana '
                      'parolanı unutmaman için 14 günde bir ana parola sorulur.',
                      style: muted,
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.tonal(
                        onPressed: _busy ? null : _setPin,
                        child: Text(st == null ? 'PIN belirle' : 'PIN\'i değiştir'),
                      ),
                      if (st != null)
                        OutlinedButton(
                          onPressed: _busy ? null : _disable,
                          child: const Text('Kapat'),
                        ),
                    ]),
                    if (st != null && _biometricAvailable)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: st.biometric,
                        onChanged: _busy ? null : _toggleBiometric,
                        title: const Text('Parmak iziyle aç'),
                        subtitle: Text(
                          'Parmak izi, PIN\'den daha kolay ama güvenliği telefonun '
                          'kilidine dayanır.',
                          style: muted,
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text('Otomatik kilitleme',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      'Uygulama arka plana geçtikten (telefonda başka uygulamaya '
                      'geçince, bilgisayarda simge durumuna küçültünce) ne kadar '
                      'sonra kilitlensin?',
                      style: muted,
                    ),
                    const SizedBox(height: 8),
                    DropdownButton<int>(
                      value: autoLock,
                      onChanged: (v) {
                        if (v != null) ref.read(autoLockProvider.notifier).set(v);
                      },
                      items: [
                        for (final m in AutoLockNotifier.options)
                          DropdownMenuItem(value: m, child: Text(_lockLabel(m))),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: scheme.error)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Kapat'),
        ),
      ],
    );
  }
}

/// PIN'i iki kez sorar; parmak izi seçeneğini de sunar.
class _PinDialog extends StatefulWidget {
  final bool biometricAvailable;
  final bool biometricInitially;

  const _PinDialog({required this.biometricAvailable, required this.biometricInitially});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  late bool _biometric = widget.biometricAvailable && widget.biometricInitially;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!QuickUnlock.isValidPin(_pin.text)) {
      setState(() => _error =
          'PIN ${QuickUnlock.minPinLength}-${QuickUnlock.maxPinLength} rakamdan oluşmalı.');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PIN\'ler aynı değil.');
      return;
    }
    if (RegExp(r'^(\d)\1+$').hasMatch(_pin.text) || '0123456789'.contains(_pin.text)) {
      setState(() => _error = 'Bu PIN tahmin edilmesi çok kolay; başka bir PIN seç.');
      return;
    }
    Navigator.of(context).pop((_pin.text, _biometric));
  }

  Widget _field(TextEditingController c, String label, {bool autofocus = false}) =>
      TextField(
        controller: c,
        autofocus: autofocus,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: QuickUnlock.maxPinLength,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, counterText: ''),
        onSubmitted: (_) => _submit(),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('PIN belirle'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(_pin, 'PIN (${QuickUnlock.minPinLength}-${QuickUnlock.maxPinLength} rakam)',
              autofocus: true),
          const SizedBox(height: 12),
          _field(_confirm, 'PIN\'i tekrar yaz'),
          if (widget.biometricAvailable)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _biometric,
              onChanged: (v) => setState(() => _biometric = v ?? false),
              title: const Text('Parmak iziyle de açılsın'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('İptal')),
        FilledButton(onPressed: _submit, child: const Text('Kaydet')),
      ],
    );
  }
}
