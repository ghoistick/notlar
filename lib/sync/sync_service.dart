import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import '../app/session.dart';
import '../app/vault.dart';
import '../data/repository/notes_repository.dart';
import '../ui/home/home_state.dart';
import 'google_account.dart';
import 'sync_engine.dart';
import 'sync_store.dart';

/// Eşitlemeyi zamanlar ve arayüze durumunu bildirir.
///
/// Uygulama açıldığında, dakikada bir ve kilitlenirken eşitler. Bir eşitleme
/// sürerken yenisi başlamaz.
class SyncService extends ChangeNotifier {
  static const interval = Duration(minutes: 1);
  static const _kEnabled = 'sync_enabled';
  static const _kLastAt = 'sync_last_at';

  final NotesRepository _repo;
  final GoogleAccount _account;
  final Vault _vault;

  SyncService({
    required NotesRepository repo,
    required GoogleAccount account,
    required Vault vault,
  })  : _repo = repo,
        _account = account,
        _vault = vault;

  bool enabled = true;
  bool running = false;
  DateTime? lastSyncAt;
  String? lastError;
  SyncReport? lastReport;

  Timer? _timer;
  SyncEngine? _engine;
  http.Client? _engineClient;
  bool _disposed = false;

  bool get available => _account.connected;

  Future<void> start() async {
    enabled = (await _repo.getMeta(_kEnabled) ?? 'true') == 'true';
    lastSyncAt = DateTime.tryParse(await _repo.getMeta(_kLastAt) ?? '');
    _account.addListener(_onAccountChanged);
    _notify();
    if (_disposed) return;
    _timer = Timer.periodic(interval, (_) => syncNow());
    unawaited(syncNow());
  }

  void _onAccountChanged() {
    if (!_account.connected) {
      _engine = null;
      _engineClient = null;
    }
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    await _repo.setMeta(_kEnabled, '$value');
    _notify();
    if (value) unawaited(syncNow());
  }

  SyncEngine _engineFor(http.Client client) {
    if (_engine == null || !identical(_engineClient, client)) {
      _engine = SyncEngine(
        repo: _repo,
        store: DriveSyncStore(drive.DriveApi(client)),
        subkey: _vault.subkey,
        keyringBytes: _vault.keyringBytes,
      );
      _engineClient = client;
    }
    return _engine!;
  }

  /// Eşitlemeyi şimdi çalıştırır; başarılıysa true döner.
  Future<bool> syncNow() async {
    final client = _account.client;
    if (client == null || running || !enabled || _disposed) return false;
    running = true;
    _notify();

    try {
      lastReport = await _engineFor(client).syncOnce();
      lastSyncAt = DateTime.now();
      lastError = null;
      return true;
    } on SyncException catch (e) {
      lastError = e.message;
      return false;
    } catch (e) {
      lastError = 'Eşitleme yapılamadı: ${describeGoogleError(e)}';
      return false;
    } finally {
      running = false;
      _notify();
    }
  }

  /// Kilitlemeden önce bekleyen değişiklikleri gönder.
  Future<void> syncBeforeLock() async {
    if (!available || !enabled) return;
    await syncNow().timeout(const Duration(seconds: 30), onTimeout: () => false);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }
}

final syncServiceProvider = Provider.autoDispose<SyncService>((ref) {
  final service = SyncService(
    repo: ref.watch(repositoryProvider),
    account: ref.watch(googleAccountProvider),
    vault: ref.read(vaultProvider),
  );
  service.start();
  ref.onDispose(service.dispose);
  return service;
});
