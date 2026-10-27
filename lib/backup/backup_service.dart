import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/paths.dart';
import '../app/session.dart';
import '../core/crypto/blob_cipher.dart';
import '../core/crypto/subkeys.dart';
import '../core/hlc/hlc.dart';
import '../data/repository/notes_repository.dart';
import '../sync/google_account.dart';
import '../sync/sync_store.dart';
import '../ui/home/home_state.dart';
import 'android_zip.dart';
import 'backup_format.dart';
import 'restore.dart';
import 'retention.dart';
import 'seven_zip.dart';

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}

/// Kayıtlı yedek parolası bu arşivi açmadı; kullanıcıdan parola istenmeli.
class BackupPasswordRequired implements Exception {
  const BackupPasswordRequired();
}

/// Drive'daki bir yedek.
class RemoteBackup {
  final RemoteFile file;
  final DateTime time;
  const RemoteBackup(this.file, this.time);
}

/// Arşiv aracı: masaüstünde 7-Zip (.7z), Android'de zip4j (.zip, AES-256).
abstract class _Engine {
  String get ext;
  Future<void> create(String path, Uint8List tar, String password);
  Future<void> verify(String path, Uint8List tar, String password);
  Future<Uint8List> extract(String path, String password);
}

class _SevenZipEngine implements _Engine {
  final SevenZip zip;
  _SevenZipEngine(String exe) : zip = SevenZip(exe);

  @override
  String get ext => '7z';

  @override
  Future<void> create(String path, Uint8List tar, String password) =>
      zip.createFromBytes(
        archivePath: path,
        innerName: backupInnerName,
        data: tar,
        password: password,
      );

  @override
  Future<void> verify(String path, Uint8List tar, String password) =>
      zip.test(path, password);

  @override
  Future<Uint8List> extract(String path, String password) =>
      zip.extractSingle(path, backupInnerName, password);
}

class _AndroidEngine implements _Engine {
  final AndroidZip zip = AndroidZip();

  @override
  String get ext => 'zip';

  @override
  Future<void> create(String path, Uint8List tar, String password) =>
      zip.createFromBytes(
        archivePath: path,
        innerName: backupInnerName,
        data: tar,
        password: password,
      );

  @override
  Future<void> verify(String path, Uint8List tar, String password) =>
      zip.verify(path, backupInnerName, password, tar);

  @override
  Future<Uint8List> extract(String path, String password) =>
      zip.extractSingle(path, backupInnerName, password);
}

/// Otomatik şifreli yedekleme.
///
/// Değişiklik olduktan sonra [quietPeriod] boyunca yeni değişiklik gelmezse
/// ve uygulama kilitlenirken yedek alınır. Yedek parolası, veri anahtarından
/// türetilen bir alt anahtarla şifrelenmiş olarak cihazda saklanır.
///
/// Masaüstü: 7-Zip ile .7z, yerel klasöre.
/// Android: AES-256 şifreli .zip, Google Drive'ın uygulama klasörüne
/// (appDataFolder); telefonda yerel kopya tutulmaz.
class BackupService extends ChangeNotifier {
  static const quietPeriod = Duration(minutes: 2);
  static const checkInterval = Duration(minutes: 1);
  static const retryAfterFailure = Duration(minutes: 5);

  static const _kDir = 'backup_dir';
  static const _kAuto = 'backup_auto';
  static const _kPassword = 'backup_password';
  static const _kLastHlc = 'backup_last_hlc';
  static const _kLastAt = 'backup_last_at';
  static const _kLastFile = 'backup_last_file';
  static const _kLastError = 'backup_last_error';
  static final _passwordAad = utf8.encode('notlar/backup-password/v1');

  final NotesRepository _repo;
  final Future<Uint8List> Function(String purpose) _subkey;
  final GoogleAccount? _google;

  BackupService({
    required NotesRepository repo,
    required Future<Uint8List> Function(String purpose) subkey,
    GoogleAccount? google,
  })  : _repo = repo,
        _subkey = subkey,
        _google = google;

  bool loaded = false;
  bool running = false;
  String? directory;
  bool auto = true;
  bool hasPassword = false;
  String? sevenZipPath;
  DateTime? lastSuccessAt;
  String? lastFile;
  String? lastError;

  Timer? _timer;
  DateTime? _failedAt;
  bool _disposed = false;

  /// Telefonda yedek Drive'a gider.
  bool get toDrive => AndroidZip.isSupported;

  /// Drive bağlantısı var mı? (yalnızca telefonda anlamlı)
  bool get driveConnected => _google?.client != null;

  bool get _engineReady => AndroidZip.isSupported || sevenZipPath != null;

  /// Kullanıcının dikkat etmesi gereken bir durum var mı (parola yok,
  /// 7-Zip yok, Drive bağlı değil ya da son yedek başarısız)?
  bool get needsAttention =>
      loaded &&
      (!hasPassword ||
          !_engineReady ||
          (toDrive && !driveConnected) ||
          lastError != null);

  bool get canRun =>
      hasPassword && _engineReady && !running && (!toDrive || driveConnected);

  static Future<String> defaultDirectory() async {
    final override = dataDirOverride;
    if (override != null) return p.join(override, 'Yedekler');
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Notlar_Yedekleri');
  }

  Future<void> start() async {
    directory = await _repo.getMeta(_kDir) ?? await defaultDirectory();
    auto = (await _repo.getMeta(_kAuto) ?? 'true') == 'true';
    hasPassword = await _repo.getMeta(_kPassword) != null;
    final at = await _repo.getMeta(_kLastAt);
    lastSuccessAt = at == null ? null : DateTime.tryParse(at);
    lastFile = await _repo.getMeta(_kLastFile);
    lastError = await _repo.getMeta(_kLastError);
    sevenZipPath = AndroidZip.isSupported ? null : await SevenZip.locate();
    loaded = true;
    _notify();
    if (_disposed) return;
    _timer = Timer.periodic(checkInterval, (_) => _tick());
  }

  // ------------------------------------------------------------- Ayarlar

  Future<void> setDirectory(String dir) async {
    directory = dir;
    await _repo.setMeta(_kDir, dir);
    _notify();
  }

  Future<void> setAuto(bool value) async {
    auto = value;
    await _repo.setMeta(_kAuto, value.toString());
    _notify();
  }

  Future<void> setPassword(String password) async {
    final key = SecretKey(await _subkey(KeyPurpose.backup));
    final blob = await BlobCipher()
        .encrypt(key, utf8.encode(password), aad: _passwordAad);
    await _repo.setMeta(_kPassword, base64Encode(blob));
    hasPassword = true;
    _notify();
  }

  /// 7-Zip sonradan kurulduysa yeniden arar.
  Future<void> relocateSevenZip() async {
    sevenZipPath = AndroidZip.isSupported ? null : await SevenZip.locate();
    _notify();
  }

  Future<String?> _readPassword() async {
    final stored = await _repo.getMeta(_kPassword);
    if (stored == null) return null;
    final key = SecretKey(await _subkey(KeyPurpose.backup));
    final clear = await BlobCipher()
        .decrypt(key, base64Decode(stored), aad: _passwordAad);
    return utf8.decode(clear);
  }

  Future<_Engine?> _engine() async {
    if (AndroidZip.isSupported) return _AndroidEngine();
    final exe = sevenZipPath ?? await SevenZip.locate();
    if (exe == null) return null;
    sevenZipPath = exe;
    return _SevenZipEngine(exe);
  }

  SyncStore? _remoteStore() {
    final c = _google?.client;
    return c == null ? null : DriveSyncStore(drive.DriveApi(c));
  }

  // --------------------------------------------------------- Geri yükleme

  /// Yedek arşivini açıp içeriğini okur. [password] verilmezse kayıtlı
  /// yedek parolası denenir; o da açmazsa [BackupPasswordRequired] fırlatılır.
  Future<BackupContent> readBackup(String archivePath, {String? password}) async {
    if (AndroidZip.isSupported && archivePath.toLowerCase().endsWith('.7z')) {
      throw const BackupException(
          'Bu bir .7z yedeği (masaüstünde alınmış). Telefonda yalnızca '
          '.zip yedekleri açılır.');
    }
    final engine = await _engine();
    if (engine == null) {
      throw const BackupException(
          '7-Zip bulunamadı. Yedeği açmak için 7-zip.org adresinden kur.');
    }
    final pw = password ?? await _readPassword();
    if (pw == null) throw const BackupPasswordRequired();

    final Uint8List tar;
    try {
      tar = await engine.extract(archivePath, pw);
    } on SevenZipException {
      if (password == null) throw const BackupPasswordRequired();
      throw const BackupException(
          'Yedek açılamadı. Parola yanlış ya da dosya bozuk olabilir.');
    } on AndroidZipException catch (e) {
      if (e.wrongPassword) {
        if (password == null) throw const BackupPasswordRequired();
        throw const BackupException(
            'Yedek açılamadı. Parola yanlış ya da dosya bozuk olabilir.');
      }
      throw BackupException(e.message);
    }
    return parseBackupTar(tar);
  }

  /// Drive'daki yedekler, en yeni önce.
  Future<List<RemoteBackup>> remoteBackups() async {
    final store = _remoteStore();
    if (store == null) throw const BackupException('Google Drive bağlı değil.');
    final out = <RemoteBackup>[
      for (final f in await store.list(backupNamePrefix))
        if (parseBackupTime(f.name) case final t?) RemoteBackup(f, t),
    ]..sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  /// Drive'daki bir yedeği indirip okur.
  Future<BackupContent> readRemoteBackup(RemoteBackup b, {String? password}) async {
    final store = _remoteStore();
    if (store == null) throw const BackupException('Google Drive bağlı değil.');
    final bytes = await store.read(b.file.id);
    final base = await getTemporaryDirectory();
    final dir = await base.createTemp('musvedde_restore_');
    try {
      final f = File(p.join(dir.path, b.file.name));
      await f.writeAsBytes(bytes, flush: true);
      return await readBackup(f.path, password: password);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------- Yedek

  Future<bool> isDirty() async {
    final h = await _repo.latestChangeHlc();
    if (h == null) return false;
    return h != await _repo.getMeta(_kLastHlc);
  }

  Future<void> _tick() async {
    if (!auto || !canRun) return;
    final failed = _failedAt;
    if (failed != null && DateTime.now().difference(failed) < retryAfterFailure) {
      return;
    }
    try {
      final h = await _repo.latestChangeHlc();
      if (h == null || h == await _repo.getMeta(_kLastHlc)) return;
      final lastChange = DateTime.fromMillisecondsSinceEpoch(Hlc.parse(h).millis);
      if (DateTime.now().difference(lastChange) < quietPeriod) return;
      await backupNow();
    } catch (_) {
      // Zamanlayıcı hatası bir sonraki denemede tekrar ele alınır.
    }
  }

  /// Kilitlemeden önce: bekleyen değişiklik varsa yedek al.
  Future<void> backupBeforeLock() async {
    if (!auto || !canRun) return;
    if (!await isDirty()) return;
    await backupNow().timeout(const Duration(seconds: 60), onTimeout: () => false);
  }

  Future<bool> backupNow() async {
    if (running) return false;
    running = true;
    lastError = null;
    _notify();

    try {
      final engine = await _engine();
      if (engine == null) {
        throw const BackupException(
            '7-Zip bulunamadı. 7-zip.org adresinden kurduktan sonra tekrar dene.');
      }
      final password = await _readPassword();
      if (password == null) {
        throw const BackupException('Yedek parolası belirlenmemiş.');
      }
      final remote = toDrive ? _remoteStore() : null;
      if (toDrive && remote == null) {
        throw const BackupException(
            'Google Drive bağlı değil. Önce senkronizasyon ayarlarından bağlan.');
      }

      final hlc = await _repo.latestChangeHlc();
      final now = DateTime.now();
      final snapshot = await BackupSnapshot.fromRepository(_repo, now: now);
      final tar = await buildBackupTar(snapshot);

      // Telefonda ZIP önbellekte üretilir, Drive'a yüklenince silinir.
      final dirPath = toDrive
          ? p.join((await getTemporaryDirectory()).path, 'yedek')
          : (directory ?? await defaultDirectory());
      final dir = Directory(dirPath);
      await dir.create(recursive: true);

      final name = backupFileName(now, ext: engine.ext);
      final finalPath = p.join(dir.path, name);
      final tmpPath = '$finalPath.tmp';
      if (await File(tmpPath).exists()) await File(tmpPath).delete();

      String shownFile;
      try {
        await engine.create(tmpPath, tar, password);
        await engine.verify(tmpPath, tar, password);

        if (remote != null) {
          await remote.create(name, await File(tmpPath).readAsBytes());
          shownFile = 'Drive: $name';
        } else {
          await File(tmpPath).rename(finalPath);
          shownFile = finalPath;
        }
      } finally {
        try {
          if (await File(tmpPath).exists()) await File(tmpPath).delete();
        } catch (_) {}
      }

      await _repo.setMeta(_kLastHlc, hlc);
      await _repo.setMeta(_kLastAt, now.toIso8601String());
      await _repo.setMeta(_kLastFile, shownFile);
      await _repo.setMeta(_kLastError, null);
      lastSuccessAt = now;
      lastFile = shownFile;
      _failedAt = null;

      // Eski yedeklerin silinmesi başarısız olursa yedek yine başarılıdır.
      try {
        if (remote != null) {
          await _pruneRemote(remote);
        } else {
          await _prune(dir);
        }
      } catch (_) {}
      return true;
    } catch (e) {
      _failedAt = DateTime.now();
      lastError = e is BackupException ||
              e is SevenZipException ||
              e is AndroidZipException
          ? e.toString()
          : 'Yedek alınamadı: $e';
      try {
        await _repo.setMeta(_kLastError, lastError);
      } catch (_) {}
      return false;
    } finally {
      running = false;
      _notify();
    }
  }

  Future<void> _prune(Directory dir) async {
    final files = <String, File>{};
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.7z.tmp')) {
        // Yarım kalmış eski denemeler.
        if (DateTime.now().difference(await e.lastModified()) >
            const Duration(hours: 1)) {
          await e.delete().catchError((_) => e);
        }
        continue;
      }
      files[name] = e;
    }
    for (final name in backupsToDelete(files.keys, DateTime.now())) {
      await files[name]!.delete().catchError((_) => files[name]!);
    }
  }

  Future<void> _pruneRemote(SyncStore store) async {
    final files = {
      for (final f in await store.list(backupNamePrefix)) f.name: f,
    };
    for (final name in backupsToDelete(files.keys, DateTime.now())) {
      await store.delete(files[name]!.id);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Kasa açık olduğu sürece çalışan yedekleme servisi.
final backupServiceProvider = Provider.autoDispose<BackupService>((ref) {
  final repo = ref.watch(repositoryProvider);
  final vault = ref.read(vaultProvider);
  final google = ref.watch(googleAccountProvider);
  final service = BackupService(repo: repo, subkey: vault.subkey, google: google);
  service.start();
  ref.onDispose(service.dispose);
  return service;
});
