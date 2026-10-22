import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis_auth/googleapis_auth.dart';

import '../data/repository/notes_repository.dart';
import '../sync/google_account.dart';
import 'vault.dart';

final vaultProvider = Provider<Vault>((ref) => Vault());

/// Uygulamanın hangi ekranda olacağını belirleyen oturum durumu.
sealed class SessionState {
  const SessionState();
}

class SessionLoading extends SessionState {
  const SessionLoading();
}

/// Kasa hiç kurulmamış: ilk açılış.
class SessionNeedsSetup extends SessionState {
  const SessionNeedsSetup();
}

class SessionLocked extends SessionState {
  const SessionLocked();
}

class SessionUnlocked extends SessionState {
  final NotesRepository repository;
  const SessionUnlocked(this.repository);
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

class SessionNotifier extends Notifier<SessionState> {
  Vault get _vault => ref.read(vaultProvider);

  @override
  SessionState build() {
    _init();
    return const SessionLoading();
  }

  Future<void> _init() async {
    state = await _vault.isInitialized()
        ? const SessionLocked()
        : const SessionNeedsSetup();
  }

  /// Kasayı kurar ve kurtarma anahtarını döner. Oturum hemen açılmaz;
  /// kullanıcı anahtarı kaydettiğini onayladıktan sonra [finishSetup] çağrılır.
  Future<String> createVault(String password) => _vault.create(password);

  void finishSetup() => state = SessionUnlocked(_vault.repository);

  /// Başka bir cihazdaki kasaya katılır. Google oturumu da saklanır; ana
  /// ekran açılınca ilk eşitleme bütün notları getirir.
  ///
  /// Masaüstünde Google oturum bilgisi [googleCredentials] şifreli saklanır;
  /// telefonda oturumu Google Play Hizmetleri tuttuğu için yalnızca bağlı
  /// hesabın e-postası ([mobileEmail]) kaydedilir.
  Future<void> joinVault(
    Uint8List keyring,
    String password, {
    AccessCredentials? googleCredentials,
    bool mobileConnected = false,
    String? mobileEmail,
  }) async {
    await _vault.join(keyring, password);
    if (googleCredentials != null) {
      await saveGoogleCredentials(
          _vault.repository, _vault.subkey, googleCredentials);
    }
    if (mobileConnected) {
      await markMobileGoogleConnected(_vault.repository, mobileEmail);
    }
    state = SessionUnlocked(_vault.repository);
  }

  Future<void> unlock(String password) async {
    await _vault.unlock(password);
    state = SessionUnlocked(_vault.repository);
  }

  Future<void> resetPassword(String recoveryKey, String newPassword) async {
    await _vault.resetPasswordWithRecoveryKey(recoveryKey, newPassword);
    state = SessionUnlocked(_vault.repository);
  }

  /// Önce ekran kilit ekranına geçer, ardından veritabanı kapanır.
  /// Böylece açık ekranlar kapalı veritabanından okumaya çalışmaz.
  Future<void> lock() async {
    state = const SessionLocked();
    await Future<void>.delayed(Duration.zero);
    await _vault.lock();
  }
}
