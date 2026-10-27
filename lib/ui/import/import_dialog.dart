import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../importers/standard_notes.dart';
import '../home/home_state.dart';

Future<void> showImportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, __) => AlertDialog(
        title: const Text('İçe aktar'),
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Standard Notes'),
              subtitle: const Text('Şifresiz ("Decrypted") yedek: .zip ya da .txt'),
              onTap: () {
                Navigator.of(ctx).pop();
                _importStandardNotes(context, ref);
              },
            ),
            const ListTile(
              enabled: false,
              leading: Icon(Icons.notes_outlined),
              title: Text('Simplenote'),
              subtitle: Text('Yakında'),
            ),
            const ListTile(
              enabled: false,
              leading: Icon(Icons.sticky_note_2_outlined),
              title: Text('Google Keep'),
              subtitle: Text('Yakında'),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Kapat'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _importStandardNotes(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(repositoryProvider);
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Standard Notes yedeği', extensions: ['zip', 'txt', 'json']),
  ]);
  if (file == null || !context.mounted) return;

  StandardNotesResult parsed;
  try {
    parsed = await _withProgress(
        context, 'Yedek okunuyor…', () => StandardNotesImporter.readFile(file.path));
  } on ImportFormatException catch (e) {
    if (context.mounted) await _info(context, 'İçe aktarılamadı', e.message);
    return;
  } on FormatException catch (e) {
    if (context.mounted) await _info(context, 'İçe aktarılamadı', e.message);
    return;
  }
  if (!context.mounted) return;

  final b = parsed.batch;
  final plan = await repo.importBatch(b, dryRun: true);
  if (!context.mounted) return;

  if (plan.notesAdded == 0) {
    await _info(context, 'Eklenecek bir şey yok',
        'Yedekteki ${b.notes.length} notun hepsi zaten Müsvedde\'de bulunuyor.');
    return;
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final muted = Theme.of(ctx).textTheme.bodySmall
          ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant);
      return AlertDialog(
        title: const Text('Standard Notes\'tan içe aktar'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Yedekte ${b.notes.length} not ve ${b.tags.length} etiket var.'),
              const SizedBox(height: 12),
              Text(
                'Eklenecek: ${plan.notesAdded} not, ${plan.tagsAdded} yeni etiket.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                'Notlar "${StandardNotesImporter.folderName}" klasörüne konacak; '
                'sonra istediğin klasörlere taşıyabilirsin. Aynı adlı mevcut '
                'etiketlerle birleştirilir.',
                style: muted,
              ),
              if (plan.notesSkipped > 0) ...[
                const SizedBox(height: 8),
                Text('${plan.notesSkipped} not zaten içe aktarılmış; tekrar eklenmeyecek.',
                    style: muted),
              ],
              if (parsed.skippedTrashed > 0) ...[
                const SizedBox(height: 8),
                Text('Standard Notes\'un çöp kutusundaki ${parsed.skippedTrashed} not '
                    'aktarılmayacak.', style: muted),
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
            child: const Text('İçe aktar'),
          ),
        ],
      );
    },
  );
  if (ok != true || !context.mounted) return;

  final result = await _withProgress(context, 'İçe aktarılıyor…', () => repo.importBatch(b));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('${result.notesAdded} not ve ${result.tagsAdded} etiket içe aktarıldı.'),
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
