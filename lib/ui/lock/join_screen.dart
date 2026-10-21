import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis_auth/googleapis_auth.dart';

import '../../app/session.dart';
import '../../core/crypto/key_manager.dart';
import '../../sync/google_account.dart';
import '../../sync/google_config.dart';
import 'lock_widgets.dart';

/// Başka bir cihazda kullanılan Müsvedde'ye katılma:
/// Google'a bağlan → Drive'daki anahtar dosyasını al → ana parolayla aç.
class JoinScreen extends ConsumerStatefulWidget {
  final VoidCallback onBack;
  const JoinScreen({super.key, required this.onBack});

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  final _password = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _authUrl;

  AutoRefreshingAuthClient? _client;
  Uint8List? _keyring;
  bool _joined = false;

  @override
  void dispose() {
    _password.dispose();
    if (!_joined) _client?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!googleConfigured) {
      setState(() => _error = 'Google istemci bilgileri bu sürümde tanımlı değil.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = await googleConsent((url) {
        if (mounted) setState(() => _authUrl = url);
      });
      final keyring = await fetchRemoteKeyring(client);
      if (keyring == null) {
        client.close();
        _error = 'Bu Google hesabında Müsvedde senkronizasyonu bulunamadı. '
            'Önce diğer cihazda Senkronizasyon penceresinden Google hesabını '
            'bağla ve bir kez eşitle; ya da burada yeni bir kasa oluştur.';
      } else {
        _client = client;
        _keyring = keyring;
      }
    } on TimeoutException {
      _error = 'Giriş 5 dakika içinde tamamlanmadı. Tekrar dene.';
    } catch (e) {
      _error = 'Google hesabına bağlanılamadı: ${describeGoogleError(e)}';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _authUrl = null;
        });
      }
    }
  }

  Future<void> _join() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .joinVault(_keyring!, _password.text, _client!.credentials);
      _joined = true;
      _client!.close();
    } on WrongPasswordException {
      if (mounted) {
        setState(() => _error = 'Parola yanlış. Diğer cihazda kullandığın ana parolayı gir.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Katılım tamamlanamadı: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final connected = _keyring != null;

    return LockLayout(
      title: 'Mevcut senkronizasyona katıl',
      message: connected
          ? 'Google hesabı bağlandı ve senkronizasyon bulundu. Şimdi diğer '
              'cihazda kullandığın ana parolayı gir.'
          : 'Başka bir cihazda kullandığın Müsvedde\'nin notlarını bu cihaza '
              'getirir. Önce o cihazda bağladığın Google hesabıyla giriş yap.',
      children: [
        if (!connected) ...[
          BusyButton(
            label: 'Google hesabına bağlan',
            busy: _busy,
            onPressed: _connect,
          ),
          if (_busy && _authUrl != null) ...[
            const SizedBox(height: 12),
            Text(
              'Tarayıcıda Google giriş sayfası açıldı. Sayfa açılmadıysa '
              'bağlantıyı kopyalayıp tarayıcına yapıştır.',
              style: muted,
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _authUrl!)),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Giriş bağlantısını kopyala'),
            ),
          ],
        ] else ...[
          PasswordField(
            controller: _password,
            label: 'Ana parola',
            autofocus: true,
            onSubmitted: (_) => _join(),
          ),
          const SizedBox(height: 20),
          BusyButton(label: 'Katıl', busy: _busy, onPressed: _join),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : widget.onBack,
          child: const Text('Geri dön'),
        ),
      ],
    );
  }
}
