import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backup/backup_service.dart';
import '../../backup/restore.dart';
import '../../data/repository/notes_repository.dart';
import '../../sync/google_account.dart';
import '../common/format.dart';
import '../home/home_state.dart';
import '../lock/lock_widgets.dart';

/// Yedekten geri yükleme: dosya seç → (gerekirse parola) → önizleme → onay.
///
/// Mevcut notların üzerine yazılmaz; yalnızca uygulamada bulunmayan notlar,
/// klasörler ve etiketler eklenir.
Future<void> restoreFromBackup(BuildContext context, WidgetRef ref) async {
  final service = ref.read(backupServiceProvider);

  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Müsvedde yedekleri',
        extensions: ['7z', 'zip'],
        mimeTypes: ['application/zip', 'application/x-7z-compressed'],
      ),
    ],
    initialDirectory: service.toDrive ? null : service.directory,
    confirmButtonText: 'Seç',
  );
  if (file == null || !context.mounted) return;

  await _restore(
    context,
    ref,
    (password) => service.readBackup(file.path, password: password),
  );
}

/// Drive'daki yedeklerden birini seçip geri yükler (telefon).
Future<void> restoreFromDrive(BuildContext context, WidgetRef ref) async {
  final service = ref.read(backupServiceProvider);

  final List<RemoteBackup> backups;
  try {
    backups = await _withProgress(
        context, 'Drive\'daki yedekler alınıyor…', service.remoteBackups);
  } catch (e) {
    if (context.mounted) {
      await _info(context, 'Yedekler alınamadı', _describe(e));
    }
    return;
  }
  if (!context.mounted) return;
  if (backups.isEmpty) {
    await _info(context, 'Yedek yok', 'Drive\'da henüz bir yedek bulunmuyor.');
    return;
  }

  final chosen = await showDialog<RemoteBackup>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Drive\'daki yedekler'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ListView.builder(
          itemCount: backups.length,
          itemBuilder: (_, i) {
            final b = backups[i];
            return ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(formatLongDate(b.time.millisecondsSinceEpoch)),
              subtitle: Text(b.file.name),
              onTap: () => Navigator.of(ctx).pop(b),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('İptal'),
        ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;

  await _restore(
    context,
    ref,
    (password) => service.readRemoteBackup(chosen, password: password),
  );
}

String _describe(Object e) => e is BackupException ? e.message : describeGoogleError(e);

/// Ortak akış: aç (gerekirse parola sor) → önizleme → onay → uygula.
Future<void> _restore(
  BuildContext context,
  WidgetRef ref,
  Future<BackupContent> Function(String? password) open,
) async {
  final repo = ref.read(repositoryProvider);

  // ---- Arşivi aç
  BackupContent? content;
  String? password;
  String? passwordError;
  while (content == null) {
    try {
      content = await _withProgress(context, 'Yedek açılıyor…', () => open(password));
    } on BackupPasswordRequired {
      if (!context.mounted) return;
      password = await _askPassword(context, error: passwordError);
      if (password == null) return;
    } on BackupException catch (e) {
      if (!context.mounted) return;
      if (password == null) {
        await _info(context, 'Yedek açılamadı', e.message);
        return;
      }
      passwordError = 'Bu parola yedeği açmadı.';
      password = await _askPassword(context, error: passwordError);
      if (password == null) return;
    } on InvalidBackupException catch (e) {
      if (context.mounted) await _info(context, 'Geçersiz yedek', e.message);
      return;
    } catch (e) {
      if (context.mounted) await _info(context, 'Yedek açılamadı', _describe(e));
      return;
    }
  }

  // ---- Önizleme
  final plan = await repo.importBatch(content.batch, dryRun: true);
  if (!context.mounted) return;

  final b = content.batch;
  if (plan.isEmpty) {
    await _info(
      context,
      'Eklenecek bir şey yok',
      'Yedekteki ${b.notes.length} notun hepsi zaten uygulamada bulunuyor.',
    );
    return;
  }

  final date = content.createdAt == null
      ? null
      : formatLongDate(content.createdAt!.millisecondsSinceEpoch);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Yedekten geri yükle'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (date != null) Text('Yedek tarihi: $date'),
            const SizedBox(height: 8),
            Text('Yedekte ${b.notes.length} not, ${b.folders.length} klasör, '
                '${b.tags.length} etiket var.'),
            const SizedBox(height: 12),
            Text(
              'Eklenecek: ${plan.notesAdded} not, ${plan.foldersAdded} klasör, '
              '${plan.tagsAdded} etiket.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (plan.notesSkipped > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Uygulamada zaten bulunan ${plan.notesSkipped} not olduğu gibi '
                'kalacak; hiçbir notun üzerine yazılmaz. Çöp kutusundaki notlar '
                'da "bulunan" sayılır; onları çöp kutusundan geri alabilirsin.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Geri yükle'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  // ---- Uygula
  final result = await _withProgress(
      context, 'Geri yükleniyor…', () => repo.importBatch(content!.batch));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('${result.notesAdded} not, ${result.foldersAdded} klasör ve '
        '${result.tagsAdded} etiket geri yüklendi.'),
  ));
}

Future<T> _withProgress<T>(
  BuildContext context,
  String message,
  Future<T> Function() action,
) async {
  final nav = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox.square(
              dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(message)),
        ]),
      ),
    ),
  );
  try {
    return await action();
  } finally {
    nav.pop();
  }
}

Future<void> _info(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 380, child: Text(message)),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Tamam'),
        ),
      ],
    ),
  );
}

Future<String?> _askPassword(BuildContext context, {String? error}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PasswordPrompt(error: error),
  );
}

class _PasswordPrompt extends StatefulWidget {
  final String? error;
  const _PasswordPrompt({this.error});

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isNotEmpty) Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Yedek parolası'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Kayıtlı yedek parolası bu dosyayı açmadı. Yedek, parolayı '
            'değiştirmeden önce alınmış olabilir. Bu yedeğin parolasını gir.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          PasswordField(
            controller: _password,
            label: 'Yedek parolası',
            autofocus: true,
            errorText: widget.error,
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Aç')),
      ],
    );
  }
}
