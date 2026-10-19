import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/session.dart';
import '../core/crypto/blob_cipher.dart';
import '../core/crypto/subkeys.dart';
import '../core/hlc/hlc.dart';
import '../data/repository/notes_repository.dart';
import '../ui/home/home_state.dart';
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

/// Otomatik şifreli yedekleme.
///
/// Değişiklik olduktan sonra [quietPeriod] boyunca yeni değişiklik gelmezse
/// ve uygulama kilitlenirken yedek alınır. Yedek parolası, veri anahtarından
/// türetilen bir alt anahtarla şifrelenmiş olarak cihazda saklanır.
class BackupService extends ChangeNotifier {
  static const quietPeriod = Duration(minutes: 2);
  static const checkInterval = Duration(minutes: 1);

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

  BackupService({
    required NotesRepository repo,
    required Future<Uint8List> Function(String purpose) subkey,
  })  : _repo = repo,
        _subkey = subkey;

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
  bool _disposed = false;

  /// Kullanıcının dikkat etmesi gereken bir durum var mı (parola yok,
  /// 7-Zip yok ya da son yedek başarısız)?
  bool get needsAttention =>
      loaded && (!hasPassword || sevenZipPath == null || lastError != null);

  bool get canRun => hasPassword && sevenZipPath != null && !running;

  static Future<String> defaultDirectory() async {
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
    sevenZipPath = await SevenZip.locate();
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
    sevenZipPath = await SevenZip.locate();
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

  // --------------------------------------------------------- Geri yükleme

  /// Yedek arşivini açıp içeriğini okur. [password] verilmezse kayıtlı
  /// yedek parolası denenir; o da açmazsa [BackupPasswordRequired] fırlatılır.
  Future<BackupContent> readBackup(String archivePath, {String? password}) async {
    final exe = sevenZipPath ?? await SevenZip.locate();
    if (exe == null) {
      throw const BackupException(
          '7-Zip bulunamadı. Yedeği açmak için 7-zip.org adresinden kur.');
    }
    final pw = password ?? await _readPassword();
    if (pw == null) throw const BackupPasswordRequired();

    final Uint8List tar;
    try {
      tar = await SevenZip(exe).extractSingle(archivePath, backupInnerName, pw);
    } on SevenZipException {
      if (password == null) throw const BackupPasswordRequired();
      throw const BackupException(
          'Yedek açılamadı. Parola yanlış ya da dosya bozuk olabilir.');
    }
    return parseBackupTar(tar);
  }

  // -------------------------------------------------------------- Yedek

  Future<bool> isDirty() async {
    final h = await _repo.latestChangeHlc();
    if (h == null) return false;
    return h != await _repo.getMeta(_kLastHlc);
  }

  Future<void> _tick() async {
    if (!auto || !canRun) return;
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
      final exe = sevenZipPath ?? await SevenZip.locate();
      if (exe == null) {
        throw const BackupException(
            '7-Zip bulunamadı. 7-zip.org adresinden kurduktan sonra tekrar dene.');
      }
      final password = await _readPassword();
      if (password == null) {
        throw const BackupException('Yedek parolası belirlenmemiş.');
      }
      final dirPath = directory ?? await defaultDirectory();

      final hlc = await _repo.latestChangeHlc();
      final now = DateTime.now();
      final snapshot = await BackupSnapshot.fromRepository(_repo, now: now);
      final tar = await buildBackupTar(snapshot);

      final dir = Directory(dirPath);
      await dir.create(recursive: true);
      final finalPath = p.join(dir.path, backupFileName(now));
      final tmpPath = '$finalPath.tmp';
      if (await File(tmpPath).exists()) await File(tmpPath).delete();

      final zip = SevenZip(exe);
      await zip.createFromBytes(
        archivePath: tmpPath,
        innerName: backupInnerName,
        data: tar,
        password: password,
      );
      await zip.test(tmpPath, password);
      await File(tmpPath).rename(finalPath);

      await _repo.setMeta(_kLastHlc, hlc);
      await _repo.setMeta(_kLastAt, now.toIso8601String());
      await _repo.setMeta(_kLastFile, finalPath);
      await _repo.setMeta(_kLastError, null);
      lastSuccessAt = now;
      lastFile = finalPath;

      await _prune(dir);
      return true;
    } catch (e) {
      lastError = e is BackupException || e is SevenZipException
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
  final service = BackupService(repo: repo, subkey: vault.subkey);
  service.start();
  ref.onDispose(service.dispose);
  return service;
});
