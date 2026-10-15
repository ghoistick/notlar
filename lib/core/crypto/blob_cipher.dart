import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Kripto katmanındaki tüm hataların temeli.
class CryptoException implements Exception {
  final String message;
  const CryptoException(this.message);

  @override
  String toString() => 'CryptoException: $message';
}

/// Anahtar yanlış ya da veri bozulmuş/değiştirilmiş.
class DecryptionFailedException extends CryptoException {
  const DecryptionFailedException()
      : super('Şifre çözülemedi: anahtar yanlış veya veri bozulmuş/değiştirilmiş.');
}

/// Uygulamadaki her şifreli verinin ortak formatı (sürüm 1):
///
///   [1 bayt sürüm][24 bayt nonce][şifreli metin][16 bayt MAC]
///
/// Algoritma XChaCha20-Poly1305. Sürüm baytı da doğrulamaya (AAD) dahildir,
/// yani başlık değiştirilirse şifre çözme başarısız olur.
///
/// [aad] ile şifreli veri amacına bağlanır (ör. 'note:<id>'). Bir notun şifreli
/// gövdesi başka bir notun yerine konursa çözme başarısız olur.
class BlobCipher {
  static const int formatVersion = 1;
  static const int nonceLength = 24;
  static const int macLength = 16;
  static const int keyLength = 32;
  static const int _headerLength = 1 + nonceLength;

  final Xchacha20 _algorithm = Xchacha20.poly1305Aead();

  Future<Uint8List> encrypt(
    SecretKey key,
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _fullAad(aad),
    );
    final out = BytesBuilder(copy: false)
      ..addByte(formatVersion)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> decrypt(
    SecretKey key,
    List<int> blob, {
    List<int> aad = const [],
  }) async {
    if (blob.length < _headerLength + macLength) {
      throw const DecryptionFailedException();
    }
    if (blob[0] != formatVersion) {
      throw CryptoException('Desteklenmeyen format sürümü: ${blob[0]}');
    }

    final nonce = blob.sublist(1, _headerLength);
    final cipherText = blob.sublist(_headerLength, blob.length - macLength);
    final mac = Mac(blob.sublist(blob.length - macLength));

    try {
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
        aad: _fullAad(aad),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const DecryptionFailedException();
    }
  }

  List<int> _fullAad(List<int> aad) => [formatVersion, ...aad];
}
