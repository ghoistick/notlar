import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../core/crypto/blob_cipher.dart';
import '../core/crypto/keyring.dart';
import 'paths.dart';

/// Cihazın güvenli deposu (Android Keystore, Windows DPAPI).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Testler için.
class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class WrongPinException implements Exception {
  /// 0 ise hızlı kilit açma kapatıldı; ana parola gerekiyor.
  final int attemptsLeft;
  const WrongPinException(this.attemptsLeft);
}

class QuickUnlockUnavailable implements Exception {
  final String message;
  const QuickUnlockUnavailable(this.message);

  @override
  String toString() => message;
}

class QuickUnlockState {
  final bool biometric;
  final int attempts;
  final DateTime passwordAt;

  const QuickUnlockState({
    required this.biometric,
    required this.attempts,
    required this.passwordAt,
  });

  int get attemptsLeft => QuickUnlock.maxAttempts - attempts;

  /// Ana parolanın unutulmaması için belirli aralıklarla sorulur.
  bool passwordDue(DateTime now) =>
      now.difference(passwordAt) >= QuickUnlock.passwordEvery;
}

/// PIN ve parmak iziyle hızlı kilit açma.
///
/// Veri anahtarı iki yolla sarmalanıp `quick_unlock.json` dosyasında tutulur:
///  - PIN yolu: anahtar, PIN'den (Argon2id) ve cihaz sırrından **birlikte**
///    türetilir. Dosyayı başka bir yere kopyalayan biri cihaz sırrı olmadan
///    hiçbir şey yapamaz; cihazda ise deneme sayısı sınırlıdır.
///  - Parmak izi yolu: anahtar yalnızca cihaz sırrından türetilir; işletim
///    sisteminin parmak izi doğrulaması geçtikten sonra kullanılır.
///
/// Cihaz sırrı, işletim sisteminin güvenli deposunda (Android Keystore,
/// Windows DPAPI) saklanır ve cihazdan dışarı çıkarılamaz.
class QuickUnlock {
  static const maxAttempts = 5;
  static const passwordEvery = Duration(days: 14);
  static const minPinLength = 4;
  static const maxPinLength = 8;

  /// Telefonda makul sürede çalışan, yine de pahalı Argon2id ayarı.
  static const pinKdf = KdfSettings(memoryKiB: 19456, iterations: 2, parallelism: 1);

  static final _pinAad = utf8.encode('musvedde/quick/pin/v1');
  static final _bioAad = utf8.encode('musvedde/quick/bio/v1');

  final SecretStore _store;
  final Directory? _baseDir;
  final KdfSettings _kdf;
  final DateTime Function() _now;

  QuickUnlock({
    SecretStore? store,
    Directory? baseDir,
    KdfSettings kdf = pinKdf,
    DateTime Function()? now,
  })  : _store = store ?? DeviceSecretStore(),
        _baseDir = baseDir,
        _kdf = kdf,
        _now = now ?? DateTime.now;

  static bool isValidPin(String pin) =>
      RegExp('^\\d{$minPinLength,$maxPinLength}\$').hasMatch(pin);

  Future<QuickUnlockState?> state() async {
    final m = await _read();
    if (m == null) return null;
    return QuickUnlockState(
      biometric: m['bio'] != null,
      attempts: m['attempts'] as int? ?? 0,
      passwordAt: DateTime.parse(m['passwordAt'] as String),
    );
  }

  /// Hızlı kilit açmayı (yeniden) kurar. Önceki kurulum silinir.
  Future<void> enable({
    required Uint8List dataKey,
    required String pin,
    bool biometric = false,
  }) async {
    if (!isValidPin(pin)) {
      throw ArgumentError('PIN $minPinLength-$maxPinLength rakam olmalı.');
    }
    await disable();

    final secret = _random(32);
    final secretId = _random(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _store.write(_secretKeyName(secretId), base64Encode(secret));

    final salt = _random(16);
    final pinKey = await _pinWrapKey(secret, await _derivePin(pin, salt, _kdf));
    final pinBlob = await BlobCipher().encrypt(pinKey, dataKey, aad: _pinAad);

    await _write({
      'v': 1,
      'secretId': secretId,
      'pin': {
        'salt': base64Encode(salt),
        'm': _kdf.memoryKiB,
        't': _kdf.iterations,
        'p': _kdf.parallelism,
        'blob': base64Encode(pinBlob),
      },
      'bio': biometric ? await _bioEntry(secret, dataKey) : null,
      'attempts': 0,
      'passwordAt': _now().toIso8601String(),
    });
  }

  /// Parmak iziyle açmayı açar ya da kapatır (PIN ayarı korunur).
  Future<void> setBiometric(bool enabled, Uint8List dataKey) async {
    final m = await _read();
    if (m == null) throw const QuickUnlockUnavailable('Önce bir PIN belirle.');
    m['bio'] = enabled ? await _bioEntry(await _secret(m), dataKey) : null;
    await _write(m);
  }

  Future<Uint8List> unlockWithPin(String pin) async {
    final m = await _read();
    final pinMap = m?['pin'] as Map<String, dynamic>?;
    if (m == null || pinMap == null) {
      throw const QuickUnlockUnavailable('Hızlı kilit açma kurulu değil.');
    }
    final secret = await _secret(m);
    final settings = KdfSettings(
      memoryKiB: pinMap['m'] as int,
      iterations: pinMap['t'] as int,
      parallelism: pinMap['p'] as int,
    );
    final key = await _pinWrapKey(
      secret,
      await _derivePin(pin, base64Decode(pinMap['salt'] as String), settings),
    );

    try {
      final dataKey = await BlobCipher()
          .decrypt(key, base64Decode(pinMap['blob'] as String), aad: _pinAad);
      if ((m['attempts'] as int? ?? 0) != 0) {
        m['attempts'] = 0;
        await _write(m);
      }
      return dataKey;
    } on DecryptionFailedException {
      final attempts = (m['attempts'] as int? ?? 0) + 1;
      if (attempts >= maxAttempts) {
        await disable();
        throw const WrongPinException(0);
      }
      m['attempts'] = attempts;
      await _write(m);
      throw WrongPinException(maxAttempts - attempts);
    }
  }

  /// Çağıran, işletim sisteminin parmak izi doğrulamasını önceden yapmış olmalı.
  Future<Uint8List> unlockWithBiometric() async {
    final m = await _read();
    final bio = m?['bio'] as Map<String, dynamic>?;
    if (m == null || bio == null) {
      throw const QuickUnlockUnavailable('Parmak iziyle açma kurulu değil.');
    }
    final secret = await _secret(m);
    try {
      return await BlobCipher().decrypt(
        await _bioWrapKey(secret),
        base64Decode(bio['blob'] as String),
        aad: _bioAad,
      );
    } on DecryptionFailedException {
      await disable();
      throw const QuickUnlockUnavailable(
          'Hızlı kilit açma bilgileri bozulmuş; ana parolanla aç.');
    }
  }

  /// Ana parolayla açıldığında: 14 günlük süre ve deneme sayacı sıfırlanır.
  Future<void> notePasswordUsed() async {
    final m = await _read();
    if (m == null) return;
    m['passwordAt'] = _now().toIso8601String();
    m['attempts'] = 0;
    await _write(m);
  }

  Future<void> disable() async {
    final m = await _read();
    if (m != null && m['secretId'] is String) {
      await _store.delete(_secretKeyName(m['secretId'] as String));
    }
    final f = await _file();
    if (await f.exists()) await f.delete();
  }

  // ---------------------------------------------------------- Yardımcılar

  static String _secretKeyName(String id) => 'musvedde_quick_$id';

  Future<Uint8List> _secret(Map<String, dynamic> m) async {
    final s = await _store.read(_secretKeyName(m['secretId'] as String));
    if (s == null) {
      // Ör. uygulama verisi silinip yeniden kuruldu: güvenli depo boşaldı.
      await disable();
      throw const QuickUnlockUnavailable(
          'Bu cihazdaki hızlı kilit açma anahtarı bulunamadı; ana parolanla aç.');
    }
    return base64Decode(s);
  }

  Future<Map<String, dynamic>> _bioEntry(List<int> secret, Uint8List dataKey) async {
    final blob = await BlobCipher().encrypt(await _bioWrapKey(secret), dataKey, aad: _bioAad);
    return {'blob': base64Encode(blob)};
  }

  static Future<Uint8List> _derivePin(String pin, List<int> salt, KdfSettings s) {
    return Isolate.run(() async {
      final key = await Argon2id(
        memory: s.memoryKiB,
        iterations: s.iterations,
        parallelism: s.parallelism,
        hashLength: 32,
      ).deriveKeyFromPassword(password: pin, nonce: salt);
      return Uint8List.fromList(await key.extractBytes());
    });
  }

  static Future<SecretKey> _pinWrapKey(List<int> secret, List<int> pinBytes) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(secret),
        nonce: pinBytes,
        info: utf8.encode('musvedde/quick/pin-wrap/v1'),
      );

  static Future<SecretKey> _bioWrapKey(List<int> secret) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(secret),
        nonce: const <int>[],
        info: utf8.encode('musvedde/quick/bio-wrap/v1'),
      );

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  Future<File> _file() async {
    final dir = _baseDir ?? await appDataDirectory();
    return File(p.join(dir.path, 'quick_unlock.json'));
  }

  Future<Map<String, dynamic>?> _read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Map<String, dynamic> m) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(m), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }
}
