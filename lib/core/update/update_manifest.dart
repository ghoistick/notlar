import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Sürümlerin yayımlandığı herkese açık depo. Kaynak kod ayrı, özel depoda.
const releaseRepo = 'ghoistick/musvedde-surumler';

/// Her zaman en son sürümün latest.json dosyasını gösterir.
const latestManifestUrl =
    'https://github.com/$releaseRepo/releases/latest/download/latest.json';

String releaseAssetUrl(String version, String fileName) =>
    'https://github.com/$releaseRepo/releases/download/v$version/$fileName';

/// latest.json: en son sürümün bilgisi ve Ed25519 imzası.
///
/// İmza; uygulama adı, sürüm, yayın tarihi, notlar, indirme adresi, dosyanın
/// SHA-256 özeti ve boyutunun tamamını kapsar. Biri bunlardan herhangi birini
/// değiştirirse imza geçersiz olur ve güncelleme reddedilir.
class UpdateManifest {
  final String app;
  final String version;
  final String publishedAt;
  final String notes;
  final String url;
  final String sha256;
  final int size;
  final String signature;

  const UpdateManifest({
    this.app = 'musvedde',
    required this.version,
    required this.publishedAt,
    required this.notes,
    required this.url,
    required this.sha256,
    required this.size,
    this.signature = '',
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> j) {
    final w = j['windows'] as Map<String, dynamic>;
    return UpdateManifest(
      app: j['app'] as String,
      version: j['version'] as String,
      publishedAt: j['publishedAt'] as String? ?? '',
      notes: j['notes'] as String? ?? '',
      url: w['url'] as String,
      sha256: (w['sha256'] as String).toLowerCase(),
      size: w['size'] as int,
      signature: j['signature'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'app': app,
        'version': version,
        'publishedAt': publishedAt,
        'notes': notes,
        'windows': {'url': url, 'sha256': sha256, 'size': size},
        'signature': signature,
      };

  UpdateManifest withSignature(String sig) => UpdateManifest(
        app: app,
        version: version,
        publishedAt: publishedAt,
        notes: notes,
        url: url,
        sha256: sha256,
        size: size,
        signature: sig,
      );

  /// İmzalanan içerik: alanlar sabit sırada, JSON dizisi olarak.
  List<int> signingPayload() => utf8.encode(jsonEncode([
        'musvedde-update-v1',
        app,
        version,
        publishedAt,
        notes,
        'windows',
        url,
        sha256,
        size,
      ]));

  Future<bool> verify(List<int> publicKey) async {
    if (signature.isEmpty || publicKey.length != 32) return false;
    try {
      return await Ed25519().verify(
        signingPayload(),
        signature: Signature(
          base64Decode(signature),
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<UpdateManifest> signedWith(SimpleKeyPair keyPair) async {
    final sig = await Ed25519().sign(signingPayload(), keyPair: keyPair);
    return withSignature(base64Encode(sig.bytes));
  }
}
