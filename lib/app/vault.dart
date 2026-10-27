import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../core/crypto/key_manager.dart';
import '../core/crypto/keyring.dart';
import '../core/crypto/subkeys.dart';
import '../data/db/connection.dart';
import '../data/db/database.dart';
import '../data/repository/notes_repository.dart';
import 'paths.dart';

/// Kasa: anahtarları ve şifreli veritabanını yönetir.
///
/// Diskte iki dosya tutar (uygulamanın destek klasöründe):
///   keyring.json  - sarmalanmış veri anahtarı (açık anahtar içermez)
///   notlar.db     - şifreli veritabanı
///
/// Argon2id hesabı ayrı bir isolate'te yapılır; parola kontrol edilirken
/// arayüz donmaz.
class Vault {
  final Directory? _baseDir;
  final KdfSettings _kdfSettings;

  AppDatabase? _db;
  NotesRepository? _repo;
  Uint8List? _dataKey;

  Vault({
    Directory? baseDir,
    KdfSettings kdfSettings = KdfSettings.production,
  })  : _baseDir = baseDir,
        _kdfSettings = kdfSettings;

  bool get isUnlocked => _repo != null;

  NotesRepository get repository =>
      _repo ?? (throw StateError('Kasa kilitli.'));

  Future<bool> isInitialized() async => (await _keyringFile()).exists();

  /// keyring.json içeriği. Yalnızca sarmalanmış anahtarlar içerir; ana parola
  /// ya da kurtarma anahtarı olmadan işe yaramaz. Yeni cihazın senkronizasyona
  /// katılabilmesi için Drive'a yüklenir.
  Future<Uint8List> keyringBytes() async => (await _keyringFile()).readAsBytes();

  /// Açık kasada, veri anahtarından amaca özel alt anahtar türetir
  /// (ör. yedek parolasını şifrelemek için).
  Future<Uint8List> subkey(String purpose) {
    final key = _dataKey;
    if (key == null) throw StateError('Kasa kilitli.');
    return deriveSubkey(SecretKey(Uint8List.fromList(key)), purpose);
  }

  /// İlk kurulum. Kurtarma anahtarını döner; kullanıcıya bir kez gösterilir.
  Future<String> create(String password) async {
    if (await isInitialized()) {
      throw StateError('Kasa zaten kurulmuş.');
    }
    final kdf = _kdfSettings;
    final result = await Isolate.run(() async {
      final s = await KeyManager(kdfSettings: kdf).setup(password);
      return (
        keyring: s.keyring.encode(),
        dataKey: Uint8List.fromList(await s.dataKey.extractBytes()),
        recoveryKey: s.recoveryKey,
      );
    });
    await _writeKeyring(result.keyring);
    await _open(result.dataKey);
    return result.recoveryKey;
  }

  /// Başka bir cihazda kurulmuş kasaya katılır: Drive'dan indirilen anahtar
  /// dosyası, o kasanın ana parolasıyla açılır. Parola yanlışsa
  /// [WrongPasswordException] fırlatır; bu durumda diske hiçbir şey yazılmaz.
  Future<void> join(Uint8List keyringBytes, String password) async {
    if (await isInitialized()) {
      throw StateError('Bu cihazda zaten bir kasa var.');
    }
    try {
      Keyring.decode(keyringBytes);
    } catch (_) {
      throw const FormatException('Drive\'daki anahtar dosyası okunamadı.');
    }
    final dataKey = await Isolate.run(() async {
      final key = await KeyManager()
          .unlockWithPassword(Keyring.decode(keyringBytes), password);
      return Uint8List.fromList(await key.extractBytes());
    });
    await _writeKeyring(keyringBytes);
    await _open(dataKey);
  }

  /// Parola yanlışsa [WrongPasswordException] fırlatır.
  Future<void> unlock(String password) async {
    final bytes = await (await _keyringFile()).readAsBytes();
    final dataKey = await Isolate.run(() async {
      final key = await KeyManager()
          .unlockWithPassword(Keyring.decode(bytes), password);
      return Uint8List.fromList(await key.extractBytes());
    });
    await _open(dataKey);
  }

  /// Parola unutulduğunda: kurtarma anahtarıyla açar ve yeni parola belirler.
  /// Anahtar geçersizse [InvalidRecoveryKeyException] fırlatır.
  Future<void> resetPasswordWithRecoveryKey(
    String recoveryKey,
    String newPassword,
  ) async {
    final bytes = await (await _keyringFile()).readAsBytes();
    final kdf = _kdfSettings;
    final result = await Isolate.run(() async {
      final km = KeyManager(kdfSettings: kdf);
      final keyring = Keyring.decode(bytes);
      final key = await km.unlockWithRecoveryKey(keyring, recoveryKey);
      final updated = await km.changePassword(keyring, key, newPassword);
      return (
        keyring: updated.encode(),
        dataKey: Uint8List.fromList(await key.extractBytes()),
      );
    });
    await _writeKeyring(result.keyring);
    await _open(result.dataKey);
  }

  /// Hızlı kilit açmadan gelen veri anahtarıyla açar.
  Future<void> unlockWithDataKey(Uint8List dataKey) =>
      _open(Uint8List.fromList(dataKey));

  /// Açık kasanın veri anahtarının kopyası (hızlı kilit açmayı kurmak için).
  Uint8List dataKeyCopy() {
    final key = _dataKey;
    if (key == null) throw StateError('Kasa kilitli.');
    return Uint8List.fromList(key);
  }

  /// Veritabanını kapatır ve anahtarı bellekten siler.
  Future<void> lock() async {
    final db = _db;
    _repo = null;
    _db = null;
    final key = _dataKey;
    if (key != null) key.fillRange(0, key.length, 0);
    _dataKey = null;
    await db?.close();
  }

  Future<void> _open(Uint8List dataKey) async {
    if (_db != null) await lock();

    final dbKey =
        await deriveSubkey(SecretKey(dataKey), KeyPurpose.localDatabase);
    final file = File(p.join((await _directory()).path, 'notlar.db'));
    final db = AppDatabase(openEncryptedDatabase(file, dbKey));

    try {
      _repo = await NotesRepository.open(db);
    } catch (_) {
      await db.close();
      rethrow;
    }
    _db = db;
    _dataKey = dataKey;
  }

  /// Önce geçici dosyaya yazar, sonra yerine koyar. Yazma sırasında elektrik
  /// kesilse bile eski keyring bozulmaz.
  Future<void> _writeKeyring(Uint8List bytes) async {
    final target = await _keyringFile();
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);

    if (await target.exists()) {
      final bak = File('${target.path}.bak');
      if (await bak.exists()) await bak.delete();
      await target.rename(bak.path);
      await tmp.rename(target.path);
      await bak.delete();
    } else {
      await tmp.rename(target.path);
    }
  }

  Future<Directory> _directory() async {
    final base = _baseDir;
    if (base == null) return appDataDirectory();
    await base.create(recursive: true);
    return base;
  }

  Future<File> _keyringFile() async =>
      File(p.join((await _directory()).path, 'keyring.json'));
}
