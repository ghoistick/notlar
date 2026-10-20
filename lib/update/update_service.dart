import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/app_settings.dart';
import '../core/net/http_client.dart';
import '../core/update/release_key.dart';
import '../core/update/update_manifest.dart';
import '../core/version.dart';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);

  @override
  String toString() => message;
}

/// Güncelleme denetimi (yalnızca Windows).
///
/// Güvenlik zinciri:
///  1. latest.json indirilir; imzası uygulamaya gömülü açık anahtarla
///     doğrulanır. İmza geçersizse hiçbir şey yapılmaz.
///  2. Yalnızca mevcut sürümden yeni bir sürüm kabul edilir (eski sürüme
///     geri döndürme saldırısı engellenir).
///  3. Kurulum dosyası indirilirken boyutu ve SHA-256 özeti, imzalı
///     bilgideki değerlerle karşılaştırılır. Uyuşmazsa dosya silinir.
class UpdateService extends ChangeNotifier {
  static const _kLastCheck = 'lastUpdateCheck';
  static const checkEvery = Duration(hours: 24);

  final AppSettingsStore _settings;
  UpdateService(this._settings);

  static bool get supported => Platform.isWindows;
  static bool get configured => releasePublicKeyBase64.isNotEmpty;

  bool checking = false;
  bool downloading = false;
  double? progress;
  UpdateManifest? available;
  File? downloaded;
  String? error;
  DateTime? lastCheckedAt;
  bool upToDate = false;

  bool _disposed = false;

  /// Açılışta: günde en fazla bir kez, yalnızca yayın sürümünde.
  Future<void> checkOnStartup() async {
    if (!supported || !configured || isDevBuild) return;
    final data = await _settings.load();
    final last = DateTime.tryParse(data[_kLastCheck] as String? ?? '');
    if (last != null && DateTime.now().difference(last) < checkEvery) return;
    await check(silent: true);
  }

  /// [silent] ise ağ hataları kullanıcıya gösterilmez (açılış denetimi).
  Future<void> check({bool silent = false}) async {
    if (checking || !supported) return;
    if (!configured) {
      error = 'Güncelleme anahtarı henüz tanımlanmadı.';
      _notify();
      return;
    }
    checking = true;
    error = null;
    upToDate = false;
    _notify();

    try {
      final manifest = await _fetchManifest();
      lastCheckedAt = DateTime.now();
      await _settings.update(_kLastCheck, lastCheckedAt!.toIso8601String());

      if (compareVersions(manifest.version, appVersion) > 0) {
        available = manifest;
      } else {
        available = null;
        upToDate = true;
      }
    } on UpdateException catch (e) {
      // İmza hatası sessiz geçilmez: biri sahte bir güncelleme sunuyor olabilir.
      error = e.message;
    } catch (e) {
      if (!silent) error = 'Güncelleme bilgisi alınamadı. İnternet bağlantını kontrol et.';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<UpdateManifest> _fetchManifest() async {
    final client = await createHttpClient();
    try {
      final req = await client.getUrl(Uri.parse(latestManifestUrl));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();
      final manifest =
          UpdateManifest.fromJson(jsonDecode(body) as Map<String, dynamic>);

      final ok = await manifest.verify(base64Decode(releasePublicKeyBase64));
      if (!ok || manifest.app != 'musvedde') {
        throw const UpdateException(
            'Güncelleme bilgisinin imzası doğrulanamadı; güncelleme yapılmadı.');
      }
      if (!manifest.url.startsWith('https://github.com/$releaseRepo/')) {
        throw const UpdateException('Güncelleme adresi beklenen depoya ait değil.');
      }
      return manifest;
    } finally {
      client.close(force: true);
    }
  }

  /// Kurulum dosyasını indirir ve doğrular.
  Future<File?> download() async {
    final m = available;
    if (m == null || downloading) return null;
    downloading = true;
    progress = 0;
    error = null;
    _notify();

    final dir = await Directory.systemTemp.createTemp('musvedde_update');
    final target = File(p.join(dir.path, 'MusveddeKurulum-${m.version}.exe'));
    final part = File('${target.path}.part');
    final client = await createHttpClient();

    try {
      final req = await client.getUrl(Uri.parse(m.url));
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');

      final sink = part.openWrite();
      final hasher = Sha256().newHashSink();
      var received = 0;
      try {
        await for (final chunk in res) {
          received += chunk.length;
          if (received > m.size) {
            throw const UpdateException('İndirilen dosya beklenenden büyük.');
          }
          sink.add(chunk);
          hasher.add(chunk);
          progress = received / m.size;
          _notify();
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      final hash = (await hasher.hash())
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      if (received != m.size || hash != m.sha256) {
        throw const UpdateException(
            'İndirilen dosya doğrulanamadı (özet uyuşmuyor); silindi.');
      }
      await part.rename(target.path);
      downloaded = target;
      return target;
    } catch (e) {
      if (await part.exists()) await part.delete();
      error = e is UpdateException ? e.message : 'Güncelleme indirilemedi.';
      return null;
    } finally {
      client.close(force: true);
      downloading = false;
      _notify();
    }
  }

  /// Kurulumu sessiz modda başlatır. Kurulum bitince uygulamayı yeniden
  /// açar. Çağıran, bundan hemen sonra uygulamayı kapatmalıdır.
  Future<void> launchInstaller(File installer) async {
    await Process.start(
      installer.path,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
      mode: ProcessStartMode.detached,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final updateServiceProvider = Provider<UpdateService>((ref) {
  final s = UpdateService(ref.read(settingsStoreProvider));
  ref.onDispose(s.dispose);
  return s;
});

/// Ana ekran açıldığında bir kez çalışır.
final startupUpdateCheckProvider = FutureProvider<void>(
    (ref) => ref.read(updateServiceProvider).checkOnStartup());
