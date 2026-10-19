import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository/notes_repository.dart';
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

  Future<void> unlock(String password) async {
    await _vault.unlock(password);
    state = SessionUnlocked(_vault.repository);
  }

  Future<void> resetPassword(String recoveryKey, String newPassword) async {
    await _vault.resetPasswordWithRecoveryKey(recoveryKey, newPassword);
    state = SessionUnlocked(_vault.repository);
  }

  Future<void> lock() async {
    await _vault.lock();
    state = const SessionLocked();
  }
}
