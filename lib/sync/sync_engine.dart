import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/crypto/blob_cipher.dart';
import '../core/crypto/subkeys.dart';
import '../data/db/database.dart';
import '../data/repository/notes_repository.dart';
import 'sync_store.dart';

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);

  @override
  String toString() => message;
}

/// Drive'daki senkronizasyon başka bir kasaya (başka bir veri anahtarına) ait.
class VaultMismatchException extends SyncException {
  const VaultMismatchException()
      : super('Drive\'daki senkronizasyon başka bir kasaya ait. Bu cihaz, '
            'senkronizasyona katılmadan ayrıca kurulmuş. Hiçbir veri '
            'gönderilmedi.');
}

class SyncReport {
  int pulledSegments = 0;
  int pushedSegments = 0;
  int pushedOps = 0;
  final applied = ApplyResult();

  bool get changedSomething =>
      pulledSegments > 0 || pushedSegments > 0 || applied.applied > 0;
}

/// Senkronizasyon motoru.
///
/// Drive'daki gizli klasör:
///   vault.json                     kasanın kimliği (veri anahtarından türetilir)
///   keyring.json                   sarmalanmış veri anahtarı (yeni cihaz için)
///   seg-<cihaz>-<sıra>.bin         şifreli, sıkıştırılmış değişiklik paketleri
///
/// Her cihaz yalnızca kendi paketlerini yazar ve hiçbir paketi değiştirmez;
/// iki cihazın aynı dosyaya yazması hiç söz konusu olmaz. Eşitleme her zaman
/// önce alır, sonra gönderir; çakışma tespiti buna dayanır.
class SyncEngine {
  static final _segmentName = RegExp(r'^seg-([0-9a-z]+)-(\d{8})\.bin$');
  static const _kSeq = 'sync_seq';
  static const _kCursorPrefix = 'sync_cursor_';

  final NotesRepository repo;
  final SyncStore store;
  final Future<Uint8List> Function(String purpose) subkey;
  final Future<Uint8List> Function() keyringBytes;
  final int batchSize;

  bool _vaultChecked = false;

  SyncEngine({
    required this.repo,
    required this.store,
    required this.subkey,
    required this.keyringBytes,
    this.batchSize = 2000,
  });

  static String segmentName(String device, int seq) =>
      'seg-$device-${seq.toString().padLeft(8, '0')}.bin';

  Future<SyncReport> syncOnce() async {
    final report = SyncReport();
    final key = SecretKey(await subkey(KeyPurpose.sync));
    if (!_vaultChecked) {
      await _ensureVault();
      _vaultChecked = true;
    }

    // ---- 1. Al: diğer cihazların yeni paketleri, sırayla.
    final byDevice = <String, List<(int, RemoteFile)>>{};
    for (final f in await store.list('seg-')) {
      final m = _segmentName.firstMatch(f.name);
      if (m == null) continue;
      final dev = m.group(1)!;
      if (dev == repo.deviceId) continue;
      byDevice.putIfAbsent(dev, () => []).add((int.parse(m.group(2)!), f));
    }
    for (final entry in byDevice.entries) {
      final dev = entry.key;
      final segs = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      final cursor = int.tryParse(await repo.getMeta('$_kCursorPrefix$dev') ?? '') ?? 0;
      for (final (seq, file) in segs) {
        if (seq <= cursor) continue;
        final ops = await _decode(key, dev, seq, await store.read(file.id));
        report.applied.add(await repo.applyRemoteOps(dev, ops));
        await repo.setMeta('$_kCursorPrefix$dev', '$seq');
        report.pulledSegments++;
      }
    }

    // ---- 2. Gönder: bu cihazın bekleyen değişiklikleri.
    while (true) {
      final pending = await repo.pendingOps(limit: batchSize);
      if (pending.isEmpty) break;
      final seq = (int.tryParse(await repo.getMeta(_kSeq) ?? '') ?? 0) + 1;
      final data = await _encode(key, repo.deviceId, seq, pending);
      await store.create(segmentName(repo.deviceId, seq), data);
      // Yükleme bittikten sonra işaretlenir. Arada kesilirse aynı değişiklikler
      // bir sonraki pakette tekrar gider; alıcı tekrarları ayıklar.
      await repo.markSynced([for (final p in pending) p.opId]);
      await repo.setMeta(_kSeq, '$seq');
      report.pushedOps += pending.length;
      report.pushedSegments++;
    }

    await repo.setMeta('sync_last_at', DateTime.now().toIso8601String());
    return report;
  }

  // ---------------------------------------------------- Kasa kimliği

  Future<String> _fingerprint() async {
    final bytes = await subkey('vault-id');
    return bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _ensureVault() async {
    final fp = await _fingerprint();
    final marker = (await store.list('vault.json'))
        .where((f) => f.name == 'vault.json')
        .firstOrNull;

    if (marker == null) {
      await store.create(
        'vault.json',
        Uint8List.fromList(utf8.encode(jsonEncode({
          'format': 'musvedde-vault',
          'version': 1,
          'fingerprint': fp,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        }))),
      );
    } else {
      final m = jsonDecode(utf8.decode(await store.read(marker.id)))
          as Map<String, dynamic>;
      if (m['fingerprint'] != fp) throw const VaultMismatchException();
    }

    // Anahtar dosyası: yeni cihaz katılırken buradan alır. Yalnızca yoksa
    // yüklenir; var olanın üzerine yazmak, başka bir cihazda değiştirilmiş
    // parolayı geri alabilirdi.
    final remote = (await store.list('keyring.json'))
        .where((f) => f.name == 'keyring.json')
        .firstOrNull;
    if (remote == null) {
      await store.create('keyring.json', await keyringBytes());
    }
  }

  // ----------------------------------------------------- Paket biçimi

  static List<int> _aad(String device, int seq) =>
      utf8.encode('musvedde/sync-segment/v1|$device|$seq');

  Future<Uint8List> _encode(
    SecretKey key,
    String device,
    int seq,
    List<ChangeLogData> ops,
  ) async {
    final json = jsonEncode({
      'v': 1,
      'device': device,
      'seq': seq,
      'ops': [for (final o in ops) RemoteOp.fromChange(o).toJson()],
    });
    final packed = gzip.encode(utf8.encode(json));
    return BlobCipher().encrypt(key, packed, aad: _aad(device, seq));
  }

  Future<List<RemoteOp>> _decode(
    SecretKey key,
    String device,
    int seq,
    Uint8List data,
  ) async {
    final List<int> packed;
    try {
      packed = await BlobCipher().decrypt(key, data, aad: _aad(device, seq));
    } on DecryptionFailedException {
      throw SyncException(
          'Senkronizasyon paketi açılamadı ($device/$seq): bozuk ya da başka '
          'bir kasaya ait.');
    }
    final m = jsonDecode(utf8.decode(gzip.decode(packed))) as Map<String, dynamic>;
    if (m['device'] != device || m['seq'] != seq) {
      throw SyncException('Senkronizasyon paketi beklenen yerde değil ($device/$seq).');
    }
    return [
      for (final o in m['ops'] as List) RemoteOp.fromJson(o as Map<String, dynamic>),
    ];
  }
}
