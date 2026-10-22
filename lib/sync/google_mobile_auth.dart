import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'google_config.dart';

/// Telefonda Google Drive erişimi.
///
/// Yalnızca **izin** istenir (drive.appdata); kimlik doğrulama adımı
/// (Android Credential Manager) kullanılmaz. Uygulamanın kullanıcının kim
/// olduğunu bilmesine gerek yok; Drive'daki kendi klasörüne erişmesi yeterli.
/// İzin adımı hesap seçimini ve onay ekranını kendisi gösterir. Erişim
/// anahtarlarını Google Play Hizmetleri saklar ve yeniler.
abstract final class GoogleMobileAuth {
  static Future<void>? _init;

  static Future<void> _ensureInitialized() => _init ??= GoogleSignIn.instance
      .initialize(serverClientId: googleServerClientId.isEmpty ? null : googleServerClientId);

  static GoogleSignInAuthorizationClient get _authz =>
      GoogleSignIn.instance.authorizationClient;

  /// Daha önce izin verildiyse, kullanıcıya bir şey göstermeden true döner.
  static Future<bool> isAuthorized() async {
    await _ensureInitialized();
    return await _authz.authorizationForScopes(googleScopes) != null;
  }

  /// Hesap seçimi ve Drive uygulama klasörü izni (gerekirse ekran gösterir).
  static Future<void> authorize() async {
    await _ensureInitialized();
    await _authz.authorizeScopes(googleScopes);
  }

  /// Bağlantıyı kaldırır.
  static Future<void> disconnect() async {
    await _ensureInitialized();
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      // Kimlik doğrulama adımı kullanılmadığı için oturum bulunmayabilir.
    }
  }
}

/// Her isteğe güncel erişim anahtarını ekleyen HTTP istemcisi.
class MobileAuthClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final authz = GoogleSignIn.instance.authorizationClient;
    var auth = await authz.authorizationForScopes(googleScopes);
    // İzin düşmüşse (ör. kullanıcı Google hesabından kaldırdı) yeniden istenir.
    auth ??= await authz.authorizeScopes(googleScopes);
    request.headers['Authorization'] = 'Bearer ${auth.accessToken}';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
