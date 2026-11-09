import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backup/backup_service.dart';
import '../../sync/google_account.dart';
import '../common/format.dart';
import '../lock/lock_widgets.dart';
import 'restore_flow.dart';

/// Pencere kendi `ref`ini kullanır; çağıran widget kapanmış olsa da
/// (ör. telefonda çekmece) sorunsuz çalışır.
Future<void> showBackupDialog(BuildContext context, [WidgetRef? _]) {
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, __) => _BackupDialog(
        service: ref.watch(backupServiceProvider),
        google: ref.watch(googleAccountProvider),
        onRestore: () => restoreFromBackup(ctx, ref),
        onRestoreDrive: () => restoreFromDrive(ctx, ref),
      ),
    ),
  );
}

class _BackupDialog extends StatelessWidget {
  final BackupService service;
  final GoogleAccount google;
  final VoidCallback onRestore;
  final VoidCallback onRestoreDrive;
  const _BackupDialog({
    required this.service,
    required this.google,
    required this.onRestore,
    required this.onRestoreDrive,
  });

  Future<void> _changeDirectory(BuildContext context) async {
    final dir = await getDirectoryPath(
      initialDirectory: service.directory,
      confirmButtonText: 'Bu klasörü kullan',
    );
    if (dir != null) await service.setDirectory(dir);
  }

  Future<void> _openDirectory() async {
    final dir = service.directory;
    if (dir == null) return;
    await Directory(dir).create(recursive: true);
    if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir]);
    }
  }

  Future<void> _setPassword(BuildContext context) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _BackupPasswordDialog(isChange: service.hasPassword),
    );
    if (password != null) await service.setPassword(password);
  }

  /// Kayıtlı Google oturumu açılış sırasında okunur; pencere o bitmeden
  /// açıldıysa kısa bir süre bekler.
  Future<void> _waitForGoogle() async {
    if (google.loaded) return;
    final done = Completer<void>();
    void check() {
      if (google.loaded && !done.isCompleted) done.complete();
    }

    google.addListener(check);
    try {
      await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    } finally {
      google.removeListener(check);
    }
  }

  /// "Şimdi yedekle" her zaman basılabilir: eksik olan (parola, Drive
  /// bağlantısı) sırayla istenir, sonra yedek alınır.
  Future<void> _backupNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    void say(String msg) =>
        messenger.showSnackBar(SnackBar(content: Text(msg)));

    if (!service.hasPassword) {
      await _setPassword(context);
      if (!service.hasPassword) return; // vazgeçildi
    }

    if (service.toDrive && !service.driveConnected) {
      await _waitForGoogle();
      if (!service.driveConnected) {
        if (google.busy) return; // bağlanma zaten sürüyor
        await google.connect();
        if (!service.driveConnected) {
          say(google.error ?? 'Google Drive\'a bağlanılamadı.');
          return;
        }
      }
    }

    final ok = await service.backupNow();
    if (!ok) {
      say(service.lastError ?? 'Yedek alınamadı.');
    } else if (service.toDrive) {
      say('Yedek Google Drive\'a (uygulama klasörü) alındı ve doğrulandı.');
    } else {
      final file = service.lastFile;
      say(file == null
          ? 'Yedek alındı ve doğrulandı.'
          : 'Yedek alındı ve doğrulandı: $file');
    }
  }

  /// Yedeğin gideceği yer ve "Şimdi yedekle" düğmesi: pencerenin başında.
  Widget _destination(BuildContext context, BackupService s) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final phone = s.toDrive;

    final String place;
    final String detail;
    final List<Widget> actions;
    if (phone) {
      place = 'Google Drive (uygulama klasörü)';
      if (s.driveConnected) {
        detail = google.email == null ? 'Bağlı' : 'Hesap: ${google.email}';
      } else if (!google.loaded || google.busy) {
        detail = 'Google bağlantısı denetleniyor…';
      } else {
        detail = 'Henüz bağlı değil. Yedeklerken Google hesabını seçmen '
            'istenecek.';
      }
      actions = [
        if (google.loaded && !google.busy && !s.driveConnected)
          TextButton(onPressed: google.connect, child: const Text('Bağlan')),
      ];
    } else {
      place = 'Bu bilgisayarda';
      detail = s.directory ?? '…';
      actions = [
        TextButton(
          onPressed: () => _changeDirectory(context),
          child: const Text('Klasörü değiştir'),
        ),
        TextButton(onPressed: _openDirectory, child: const Text('Klasörü aç')),
      ];
    }

    final busy = s.running || (phone && google.busy);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(phone ? Icons.cloud_outlined : Icons.folder_outlined,
                size: 28, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Yedeğin alınacağı yer', style: muted),
                  const SizedBox(height: 2),
                  Text(place,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  SelectableText(detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ]),
          if (actions.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 4, children: actions),
            )
          else
            const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              onPressed: !s.loaded || busy ? null : () => _backupNow(context),
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.backup_outlined),
              label: Text(s.running ? 'Yedek alınıyor…' : 'Şimdi yedekle'),
            ),
          ),
          if (s.loaded && !s.hasPassword) ...[
            const SizedBox(height: 6),
            Text('İlk yedekte bir yedek parolası belirlemen istenecek.',
                style: muted),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return ListenableBuilder(
      listenable: Listenable.merge([service, google]),
      builder: (context, _) {
        final s = service;
        final phone = s.toDrive;
        final engineReady = phone || s.sevenZipPath != null;
        return AlertDialog(
          title: const Text('Yedekleme'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _destination(context, s),
                  const SizedBox(height: 12),
                  _StatusBox(service: s),
                  if (s.loaded && !phone && s.sevenZipPath == null) ...[
                    const SizedBox(height: 12),
                    _Warning(
                      text: '7-Zip bulunamadı. Yedek almak ve yedekleri açmak '
                          'için 7-zip.org adresinden 7-Zip\'i kur.',
                      action: TextButton(
                        onPressed: s.relocateSevenZip,
                        child: const Text('Yeniden ara'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    phone
                        ? 'Notlar AES-256 ile şifreli bir ZIP arşivi olarak '
                            'Drive\'ın uygulamaya özel klasörüne kaydedilir. Bu '
                            'klasör Drive\'da görünmez; yedekleri buradan ya da '
                            'bilgisayardaki Müsvedde\'den geri yükleyebilirsin. '
                            'İçinde notlar Markdown dosyaları olarak, klasör '
                            'yapınla birlikte durur.'
                        : 'Notlar şifreli bir 7-Zip arşivi olarak kaydedilir. '
                            'Arşivi uygulama olmadan da 7-Zip ve yedek parolanla '
                            'açabilirsin; içinde notlar Markdown dosyaları olarak, '
                            'klasör yapınla birlikte durur.',
                    style: muted,
                  ),
                  const SizedBox(height: 20),
                  Text('Yedek parolası',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    s.hasPassword
                        ? 'Belirlendi. Değiştirirsen yeni parola yalnızca bundan '
                            'sonraki yedeklerde geçerli olur; eski yedekler eski '
                            'parolayla açılır.'
                        : phone
                            ? 'Henüz belirlenmedi. Bilgisayardaki Müsvedde\'de '
                                'kullandığın yedek parolasını girersen iki cihazın '
                                'yedekleri aynı parolayla açılır.'
                            : 'Henüz belirlenmedi. Arşivleri 7-Zip ile açarken '
                                'bu parolayı gireceksin.',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => _setPassword(context),
                    child: Text(s.hasPassword ? 'Parolayı değiştir' : 'Parola belirle'),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: s.auto,
                    onChanged: s.setAuto,
                    title: const Text('Otomatik yedekle'),
                    subtitle: Text(
                      'Değişiklikten 2 dakika sonra ve uygulamayı kilitlerken. '
                      'Son 24 saatin tüm yedekleri ve 30 güne kadar her günün '
                      'son yedeği saklanır; daha eskiler silinir.',
                      style: muted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Geri yükleme',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    'Bir yedekteki notlardan uygulamada bulunmayanları geri '
                    'getirir. Mevcut notların üzerine yazılmaz.',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (phone)
                      OutlinedButton.icon(
                        onPressed: !s.driveConnected || s.running
                            ? null
                            : onRestoreDrive,
                        icon: const Icon(Icons.cloud_download_outlined, size: 18),
                        label: const Text('Drive\'daki yedekten…'),
                      ),
                    OutlinedButton.icon(
                      onPressed: !engineReady || s.running ? null : onRestore,
                      icon: const Icon(Icons.restore, size: 18),
                      label: Text(phone ? 'Dosyadan…' : 'Yedekten geri yükle…'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Kapat'),
            ),
          ],
        );
      },
    );
  }
}

class _StatusBox extends StatelessWidget {
  final BackupService service;
  const _StatusBox({required this.service});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = service;

    final String text;
    IconData icon = Icons.check_circle_outline;
    Color color = scheme.primary;

    if (!s.loaded) {
      text = 'Yükleniyor…';
      icon = Icons.hourglass_empty;
    } else if (s.running) {
      text = 'Yedek alınıyor…';
      icon = Icons.sync;
    } else if (s.lastError != null) {
      text = s.lastError!;
      icon = Icons.error_outline;
      color = scheme.error;
    } else if (s.lastSuccessAt != null) {
      final when = formatLongDate(s.lastSuccessAt!.millisecondsSinceEpoch);
      final file = s.lastFile;
      final String where;
      if (s.toDrive) {
        // Telefonda lastFile "Drive: notlar-yedek-....zip" biçimindedir.
        final name = file?.replaceFirst('Drive: ', '');
        where = '\nKonum: Google Drive (uygulama klasörü)'
            '${name == null ? '' : '\n$name'}';
      } else {
        where = file == null ? '' : '\nKonum: $file';
      }
      text = 'Son yedek: $when$where';
    } else {
      text = 'Henüz yedek alınmadı.';
      icon = Icons.info_outline;
      color = scheme.onSurfaceVariant;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ]),
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;
  final Widget action;
  const _Warning({required this.text, required this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 20, color: scheme.error),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
        action,
      ]),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  final bool isChange;
  const _BackupPasswordDialog({required this.isChange});

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = validateNewPassword(_password.text, _confirm.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.isChange ? 'Yedek parolasını değiştir' : 'Yedek parolası'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Bu parolayı unutursan yedekleri açamazsın. Ana parolandan farklı '
            'bir parola seçmen önerilir.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          PasswordField(
            controller: _password,
            label: 'Yedek parolası',
            autofocus: true,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          PasswordField(
            controller: _confirm,
            label: 'Parolayı tekrar yaz',
            errorText: _error,
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Kaydet')),
      ],
    );
  }
}
