import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'blob_cipher.dart';
import 'keyring.dart';

class WrongPasswordException extends CryptoException {
  const WrongPasswordException() : super('Ana parola yanlış.');
}

class InvalidRecoveryKeyException extends CryptoException {
  const InvalidRecoveryKeyException() : super('Kurtarma anahtarı geçersiz.');
}

/// İlk kurulumun sonucu. [recoveryKey] yalnızca bu anda gösterilir;
/// hiçbir yerde saklanmaz, kullanıcı yazıp güvenli bir yerde tutmalıdır.
class SetupResult {
  final Keyring keyring;
  final SecretKey dataKey;
  final String recoveryKey;

  const SetupResult({
    required this.keyring,
    required this.dataKey,
    required this.recoveryKey,
  });
}

/// Anahtar hiyerarşisi:
///
///   ana parola ──Argon2id──► parola anahtarı ──┐
///                                               ├─ sarmalar ─► veri anahtarı
///   kurtarma anahtarı ──HKDF──► kurtarma anahtarı ┘
///
/// Tüm notları şifreleyen veri anahtarı rastgele üretilir ve hiç değişmez.
/// Parola değişince yalnızca sarmalama yenilenir, veri yeniden şifrelenmez.
class KeyManager {
  static const int _saltLength = 16;
  static const int _recoveryKeyBytes = 20; // 160 bit, 32 karakter
  static final _aadPassword = utf8.encode('notlar/keyring/password/v1');
  static final _aadRecovery = utf8.encode('notlar/keyring/recovery/v1');
  static final _hkdfInfoRecovery = utf8.encode('notlar/recovery-kek/v1');

  final BlobCipher _cipher;
  final KdfSettings _kdfSettings;
  final Random _random;

  KeyManager({
    BlobCipher? cipher,
    KdfSettings kdfSettings = KdfSettings.production,
    Random? random,
  })  : _cipher = cipher ?? BlobCipher(),
        _kdfSettings = kdfSettings,
        _random = random ?? Random.secure();

  /// İlk kurulum: veri anahtarı ve kurtarma anahtarı üretilir.
  Future<SetupResult> setup(String password) async {
    _checkPassword(password);

    final dataKeyBytes = _randomBytes(BlobCipher.keyLength);
    final dataKey = SecretKey(dataKeyBytes);

    final passwordKdf =
        KdfParams(settings: _kdfSettings, salt: _randomBytes(_saltLength));
    final passwordKey = await _derivePasswordKey(password, passwordKdf);
    final passwordWrapped =
        await _cipher.encrypt(passwordKey, dataKeyBytes, aad: _aadPassword);

    final recoveryBytes = _randomBytes(_recoveryKeyBytes);
    final recoverySalt = _randomBytes(_saltLength);
    final recoveryKek = await _deriveRecoveryKey(recoveryBytes, recoverySalt);
    final recoveryWrapped =
        await _cipher.encrypt(recoveryKek, dataKeyBytes, aad: _aadRecovery);

    return SetupResult(
      keyring: Keyring(
        passwordKdf: passwordKdf,
        passwordWrapped: passwordWrapped,
        recoverySalt: recoverySalt,
        recoveryWrapped: recoveryWrapped,
      ),
      dataKey: dataKey,
      recoveryKey: RecoveryKeyCodec.encode(recoveryBytes),
    );
  }

  /// Ana parola ile veri anahtarını açar.
  Future<SecretKey> unlockWithPassword(Keyring keyring, String password) async {
    final passwordKey = await _derivePasswordKey(password, keyring.passwordKdf);
    try {
      final bytes = await _cipher.decrypt(
        passwordKey,
        keyring.passwordWrapped,
        aad: _aadPassword,
      );
      return SecretKey(bytes);
    } on DecryptionFailedException {
      throw const WrongPasswordException();
    }
  }

  /// Kurtarma anahtarı ile veri anahtarını açar (parola unutulduğunda).
  Future<SecretKey> unlockWithRecoveryKey(
    Keyring keyring,
    String recoveryKey,
  ) async {
    final List<int> recoveryBytes;
    try {
      recoveryBytes = RecoveryKeyCodec.decode(recoveryKey, _recoveryKeyBytes);
    } on FormatException {
      throw const InvalidRecoveryKeyException();
    }

    final kek = await _deriveRecoveryKey(recoveryBytes, keyring.recoverySalt);
    try {
      final bytes = await _cipher.decrypt(
        kek,
        keyring.recoveryWrapped,
        aad: _aadRecovery,
      );
      return SecretKey(bytes);
    } on DecryptionFailedException {
      throw const InvalidRecoveryKeyException();
    }
  }

  /// Ana parolayı değiştirir. Veri anahtarı ve kurtarma anahtarı aynı kalır.
  Future<Keyring> changePassword(
    Keyring keyring,
    SecretKey dataKey,
    String newPassword,
  ) async {
    _checkPassword(newPassword);

    final dataKeyBytes = await dataKey.extractBytes();
    final passwordKdf =
        KdfParams(settings: _kdfSettings, salt: _randomBytes(_saltLength));
    final passwordKey = await _derivePasswordKey(newPassword, passwordKdf);
    final passwordWrapped =
        await _cipher.encrypt(passwordKey, dataKeyBytes, aad: _aadPassword);

    return keyring.copyWith(
      passwordKdf: passwordKdf,
      passwordWrapped: passwordWrapped,
    );
  }

  Future<SecretKey> _derivePasswordKey(String password, KdfParams params) {
    final argon = Argon2id(
      memory: params.settings.memoryKiB,
      iterations: params.settings.iterations,
      parallelism: params.settings.parallelism,
      hashLength: BlobCipher.keyLength,
    );
    return argon.deriveKeyFromPassword(password: password, nonce: params.salt);
  }

  /// Kurtarma anahtarı zaten yüksek entropili olduğu için Argon2 gerekmez.
  Future<SecretKey> _deriveRecoveryKey(List<int> recoveryBytes, List<int> salt) {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: BlobCipher.keyLength);
    return hkdf.deriveKey(
      secretKey: SecretKey(recoveryBytes),
      nonce: salt,
      info: _hkdfInfoRecovery,
    );
  }

  void _checkPassword(String password) {
    if (password.isEmpty) {
      throw ArgumentError('Ana parola boş olamaz.');
    }
  }

  Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));
}

/// Kurtarma anahtarını okunabilir metne çevirir: XXXX-XXXX-...-XXXX
///
/// Karışabilecek harfler (I, L, O, U) alfabede yoktur. Girişte küçük harf,
/// boşluk ve tire esnek kabul edilir; O→0, I/L→1 olarak düzeltilir.
class RecoveryKeyCodec {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const _groupSize = 4;

  static String encode(List<int> bytes) {
    final raw = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        raw.write(_alphabet[(buffer >> bits) & 31]);
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) {
      raw.write(_alphabet[(buffer << (5 - bits)) & 31]);
    }

    final s = raw.toString();
    final groups = <String>[];
    for (var i = 0; i < s.length; i += _groupSize) {
      groups.add(s.substring(i, min(i + _groupSize, s.length)));
    }
    return groups.join('-');
  }

  static List<int> decode(String input, int expectedBytes) {
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');

    final expectedChars = (expectedBytes * 8 / 5).ceil();
    if (cleaned.length != expectedChars) {
      throw const FormatException('Kurtarma anahtarı uzunluğu hatalı.');
    }

    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final ch in cleaned.split('')) {
      final value = _alphabet.indexOf(ch);
      if (value < 0) {
        throw FormatException('Geçersiz karakter: $ch');
      }
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
      }
      buffer &= (1 << bits) - 1;
    }
    return out.sublist(0, expectedBytes);
  }
}
