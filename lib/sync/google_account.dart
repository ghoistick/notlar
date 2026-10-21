import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';

import '../app/session.dart';
import '../core/crypto/blob_cipher.dart';
import '../core/crypto/subkeys.dart';
import '../core/net/http_client.dart';
import '../data/repository/notes_repository.dart';
import '../ui/home/home_state.dart';
import 'google_config.dart';
import 'transport_client.dart';

/// Google hesabı bağlantısı.
///
/// Giriş, tarayıcıda Google'ın kendi sayfasında yapılır; uygulama parolanı
/// hiç görmez. Google'ın verdiği oturum bilgisi (yenileme anahtarı) veri
/// anahtarından türetilen bir anahtarla şifrelenip cihazda saklanır.
class GoogleAccount extends ChangeNotifier {
  static const _kCredentials = 'google_credentials';
  static const _kEmail = 'google_email';
  static final _aad = utf8.encode('musvedde/google-credentials/v1');

  final NotesRepository _repo;
  final Future<Uint8List> Function(String purpose) _subkey;
  final _base = TransportClient();

  GoogleAccount({
    required NotesRepository repo,
    required Future<Uint8List> Function(String purpose) subkey,
  })  : _repo = repo,
        _subkey = subkey;

  bool loaded = false;
  bool busy = false;
  String? email;
  String? error;
  String? testResult;

  /// Giriş sürerken: tarayıcı açılmazsa kullanıcı bu adresi kopyalayabilir.
  String? pendingAuthUrl;

  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _updates;
  bool _disposed = false;

  bool get connected => _client != null;

  /// Senkronizasyon motoru bu istemciyle Drive'a erişir.
  AutoRefreshingAuthClient? get client => _client;

  ClientId get _clientId => ClientId(googleClientId, googleClientSecret);

  Future<void> start() async {
    try {
      email = await _repo.getMeta(_kEmail);
      final creds = await _loadCredentials();
      if (creds != null) {
        _attach(autoRefreshingClient(_clientId, creds, _base));
      }
    } catch (e) {
      error = 'Kayıtlı Google oturumu açılamadı: $e';
    }
    loaded = true;
    _notify();
  }

  void _attach(AutoRefreshingAuthClient client) {
    _updates?.cancel();
    _client?.close();
    _client = client;
    // Erişim anahtarı yenilendikçe yeni hali saklanır.
    _updates = client.credentialUpdates.listen(_saveCredentials);
  }

  // ----------------------------------------------------------- Bağlanma

  Future<void> connect() async {
    if (!googleConfigured) {
      error = 'Google istemci bilgileri tanımlanmadı (lib/sync/google_config.dart).';
      _notify();
      return;
    }
    busy = true;
    error = null;
    testResult = null;
    _notify();

    try {
      final client = await clientViaUserConsent(
        _clientId,
        googleScopes,
        _openBrowser,
        baseClient: _base,
        customPostAuthPage: _successPage,
      ).timeout(const Duration(minutes: 5));

      await _saveCredentials(client.credentials);
      _attach(client);
      await _loadEmail();
    } on TimeoutException {
      error = 'Giriş 5 dakika içinde tamamlanmadı. Tekrar dene.';
    } catch (e) {
      error = 'Google hesabına bağlanılamadı: ${_describe(e)}';
    } finally {
      pendingAuthUrl = null;
      busy = false;
      _notify();
    }
  }

  void _openBrowser(String url) {
    pendingAuthUrl = url;
    _notify();
    if (Platform.isWindows) {
      Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [url]);
    }
  }

  /// Bağlantıyı kaldırır: Google'daki izni geri alır ve oturumu siler.
  Future<void> disconnect() async {
    busy = true;
    _notify();
    try {
      final token = _client?.credentials.refreshToken ??
          _client?.credentials.accessToken.data;
      if (token != null) {
        await httpSend(
          'POST',
          Uri.parse('https://oauth2.googleapis.com/revoke'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: utf8.encode('token=${Uri.encodeQueryComponent(token)}'),
        );
      }
    } catch (_) {
      // İnternet yoksa da yerel oturum silinir.
    }
    await _updates?.cancel();
    _client?.close();
    _client = null;
    email = null;
    testResult = null;
    await _repo.setMeta(_kCredentials, null);
    await _repo.setMeta(_kEmail, null);
    busy = false;
    _notify();
  }

  Future<void> _loadEmail() async {
    try {
      final about = await drive.DriveApi(_client!)
          .about
          .get($fields: 'user(emailAddress)');
      email = about.user?.emailAddress;
      await _repo.setMeta(_kEmail, email);
    } catch (_) {
      // E-posta yalnızca gösterim için; alınamazsa bağlantı yine geçerli.
    }
  }

  // --------------------------------------------------------------- Test

  /// Uygulama klasörüne küçük bir dosya yazar, geri okur ve siler.
  Future<void> test() async {
    final c = _client;
    if (c == null || busy) return;
    busy = true;
    error = null;
    testResult = null;
    _notify();

    try {
      final api = drive.DriveApi(c);
      final sw = Stopwatch()..start();
      final content =
          utf8.encode('Müsvedde bağlantı testi ${DateTime.now().toIso8601String()}');

      final created = await api.files.create(
        drive.File()
          ..name = 'baglanti-testi.txt'
          ..parents = ['appDataFolder'],
        uploadMedia: drive.Media(Stream.value(content), content.length),
      );
      final media = await api.files.get(
        created.id!,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      final back = await media.stream.expand((chunk) => chunk).toList();
      await api.files.delete(created.id!);
      final list = await api.files.list(
          spaces: 'appDataFolder', $fields: 'files(id)', pageSize: 100);

      if (!listEquals(back, content)) {
        throw StateError('Okunan içerik yazılanla aynı değil.');
      }
      if (email == null) await _loadEmail();
      testResult = 'Bağlantı çalışıyor: yazma, okuma ve silme '
          '${sw.elapsedMilliseconds} ms sürdü. Uygulama klasöründe şu an '
          '${list.files?.length ?? 0} dosya var.';
    } catch (e) {
      error = 'Drive testi başarısız: ${_describe(e)}';
    } finally {
      busy = false;
      _notify();
    }
  }

  // ------------------------------------------------------------ Saklama

  Future<void> _saveCredentials(AccessCredentials c) async {
    final key = SecretKey(await _subkey(KeyPurpose.sync));
    final blob = await BlobCipher()
        .encrypt(key, utf8.encode(jsonEncode(c.toJson())), aad: _aad);
    await _repo.setMeta(_kCredentials, base64Encode(blob));
  }

  Future<AccessCredentials?> _loadCredentials() async {
    final stored = await _repo.getMeta(_kCredentials);
    if (stored == null) return null;
    final key = SecretKey(await _subkey(KeyPurpose.sync));
    final clear = await BlobCipher().decrypt(key, base64Decode(stored), aad: _aad);
    return AccessCredentials.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
  }

  String _describe(Object e) => describeGoogleError(e);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _updates?.cancel();
    _client?.close();
    super.dispose();
  }
}

/// Google ve ağ hatalarını anlaşılır bir dile çevirir.
String describeGoogleError(Object e) {
  if (e is drive.DetailedApiRequestError) {
    return 'Google yanıtı ${e.status}: ${e.message ?? ''}';
  }
  if (e is AccessDeniedException) return 'Erişim reddedildi (${e.message}).';
  if (e is UserConsentException) return 'Google girişi tamamlanmadı (${e.message}).';
  if (e is ServerRequestFailedException) {
    return 'Google oturumu yenilenemedi; bağlantıyı kaldırıp yeniden bağlan '
        '(${e.message}).';
  }
  return describeNetworkError(e);
}

const _successPage = '''<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><title>Müsvedde</title></head>
<body style="font-family:Segoe UI,sans-serif;padding:48px;color:#1D2733">
<h2>Müsvedde Google hesabına bağlandı</h2>
<p>Bu pencereyi kapatıp uygulamaya dönebilirsin.</p>
</body></html>''';

/// Kasa açık olduğu sürece geçerli Google bağlantısı.
final googleAccountProvider = Provider.autoDispose<GoogleAccount>((ref) {
  final repo = ref.watch(repositoryProvider);
  final vault = ref.read(vaultProvider);
  final account = GoogleAccount(repo: repo, subkey: vault.subkey);
  account.start();
  ref.onDispose(account.dispose);
  return account;
});
