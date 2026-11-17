import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository/import_records.dart';
import '../../data/repository/notes_repository.dart';
import '../../importers/google_keep.dart';
import '../../importers/standard_notes.dart';
import '../../importers/text_files.dart';
import '../home/home_state.dart';

/// Klasör seçimi yalnızca masaüstünde.
bool get _canPickFolder => !(Platform.isAndroid || Platform.isIOS);

Future<void> showImportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, __) {
        /// Pencereyi kapatıp işlemi başlatır. Depo, pencere kapanmadan önce
        /// okunur: bu pencerenin `ref`i kapandıktan sonra kullanılamaz
        /// (dosya seçiciden dönünce okumak sessizce hata veriyordu).
        void run(
            Future<void> Function(BuildContext, NotesRepository) action) {
          final repo = ref.read(repositoryProvider);
          Navigator.of(ctx).pop();
          action(context, repo);
        }

        return AlertDialog(
          title: const Text('İçe aktar'),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Standard Notes'),
                subtitle:
                    const Text('Şifresiz ("Decrypted") yedek: .zip ya da .txt'),
                onTap: () => run(_importStandardNotes),
              ),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('Metin ve Markdown dosyaları'),
                subtitle:
                    const Text('.md, .markdown ya da .txt; bir ya da birden çok dosya'),
                onTap: () => run(_importTextFiles),
              ),
              if (_canPickFolder)
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('Markdown klasörü'),
                  subtitle:
                      const Text('Alt klasörler, klasör ağacı olarak aktarılır'),
                  onTap: () => run(_importFolder),
                ),
              const ListTile(
                enabled: false,
                leading: Icon(Icons.notes_outlined),
                title: Text('Simplenote'),
                subtitle: Text('Yakında'),
              ),
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: const Text('Google Keep'),
                subtitle: const Text(
                    'Google Takeout: .zip ya da Keep klasöründeki .json dosyaları'),
                onTap: () => run(_importGoogleKeep),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Kapat'),
            ),
          ],
        );
      },
    ),
  );
}

// ------------------------------------------------------------ Standard Notes

Future<void> _importStandardNotes(BuildContext context, NotesRepository repo) async {
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
  await _reviewAndImport(
    context,
    repo,
    title: 'Standard Notes\'tan içe aktar',
    batch: b,
    summary: 'Yedekte ${b.notes.length} not ve ${b.tags.length} etiket var.',
    allPresent:
        'Yedekteki ${b.notes.length} notun hepsi zaten Müsvedde\'de bulunuyor.',
    placement: 'Notlar "${StandardNotesImporter.folderName}" klasörüne konacak; '
        'sonra istediğin klasörlere taşıyabilirsin. Aynı adlı mevcut '
        'etiketlerle birleştirilir.',
    remarks: [
      if (parsed.skippedTrashed > 0)
        'Standard Notes\'un çöp kutusundaki ${parsed.skippedTrashed} not '
            'aktarılmayacak.',
    ],
  );
}

// ---------------------------------------------------------------- Google Keep

Future<void> _importGoogleKeep(BuildContext context, NotesRepository repo) async {
  final files = await openFiles(
    acceptedTypeGroups: Platform.isAndroid
        ? const []
        : const [
            XTypeGroup(label: 'Google Takeout (Keep)', extensions: ['zip', 'json']),
          ],
  );
  if (files.isEmpty || !context.mounted) return;

  final KeepResult parsed;
  try {
    parsed = await _withProgress(context, 'Keep notları okunuyor…',
        () => GoogleKeepImporter.readFiles(files));
  } on FormatException catch (e) {
    if (context.mounted) {
      await _info(context, 'İçe aktarılamadı', 'ZIP dosyası okunamadı: ${e.message}');
    }
    return;
  } catch (e) {
    if (context.mounted) await _info(context, 'İçe aktarılamadı', '$e');
    return;
  }
  if (!context.mounted) return;

  final b = parsed.batch;
  final remarks = [
    if (parsed.skippedTrashed > 0)
      'Keep\'in çöp kutusundaki ${parsed.skippedTrashed} not aktarılmayacak.',
    if (parsed.withAttachments > 0)
      '${parsed.withAttachments} notun resim ya da ses ekleri alınmayacak; '
          'yalnızca metinleri aktarılacak.',
    if (parsed.skippedEmpty > 0)
      'Metni olmayan ${parsed.skippedEmpty} not (yalnızca ek içeren) atlandı.',
    if (parsed.duplicates > 0)
      '${parsed.duplicates} not seçimde birden fazla kez bulunduğu için bir kez alınacak.',
    if (parsed.unreadable > 0)
      '${parsed.unreadable} dosya okunamadığı için atlandı.',
  ];

  if (b.notes.isEmpty &&
      parsed.skippedTrashed == 0 &&
      parsed.skippedEmpty == 0) {
    await _info(context, 'İçe aktarılamadı', keepNotFoundMessage);
    return;
  }

  final tagCount = {
    for (final n in b.notes)
      for (final t in n.tagNames) t.toLowerCase(),
  }.length;

  await _reviewAndImport(
    context,
    repo,
    title: 'Google Keep\'ten içe aktar',
    batch: b,
    summary: 'Seçimde ${b.notes.length} Keep notu ve $tagCount etiket var.',
    allPresent:
        'Seçilen ${b.notes.length} notun hepsi zaten Müsvedde\'de bulunuyor.',
    placement: 'Notlar kısa not olarak "${GoogleKeepImporter.folderName}" '
        'klasörüne konacak; sonra istediğin klasörlere taşıyabilirsin. '
        'Keep etiketleri aynı adlı mevcut etiketlerle birleştirilir.',
    remarks: remarks,
  );
}

// ------------------------------------------------- Metin ve Markdown dosyaları

Future<void> _importTextFiles(BuildContext context, NotesRepository repo) async {
  // Android'de .md dosyalarının türü çoğu zaman tanınmadığından süzgeç
  // konmaz; desteklenmeyen dosyalar okunurken ayıklanır.
  final files = await openFiles(
    acceptedTypeGroups: Platform.isAndroid
        ? const []
        : const [
            XTypeGroup(
                label: 'Metin ve Markdown',
                extensions: TextFilesImporter.extensions),
          ],
  );
  if (files.isEmpty || !context.mounted) return;

  final TextFilesResult parsed;
  try {
    parsed = await _withProgress(context, 'Dosyalar okunuyor…',
        () => TextFilesImporter.readFiles(files));
  } catch (e) {
    if (context.mounted) await _info(context, 'İçe aktarılamadı', '$e');
    return;
  }
  if (!context.mounted) return;

  await _reviewTextFiles(
    context,
    repo,
    parsed,
    title: 'Dosyalardan içe aktar',
    placement: 'Notlar "${TextFilesImporter.folderName}" klasörüne konacak; '
        'sonra istediğin klasörlere taşıyabilirsin.',
  );
}

Future<void> _importFolder(BuildContext context, NotesRepository repo) async {
  final dir = await getDirectoryPath(confirmButtonText: 'Bu klasörü seç');
  if (dir == null || !context.mounted) return;

  final TextFilesResult parsed;
  try {
    parsed = await _withProgress(context, 'Klasör okunuyor…',
        () => TextFilesImporter.readDirectory(dir));
  } catch (e) {
    if (context.mounted) await _info(context, 'İçe aktarılamadı', '$e');
    return;
  }
  if (!context.mounted) return;

  await _reviewTextFiles(
    context,
    repo,
    parsed,
    title: 'Klasörden içe aktar',
    placement: 'Notlar kökte açılacak "${parsed.rootName}" klasörüne, alt '
        'klasör yapısı korunarak konacak.',
  );
}

Future<void> _reviewTextFiles(
  BuildContext context,
  NotesRepository repo,
  TextFilesResult r, {
  required String title,
  required String placement,
}) {
  final b = r.batch;
  final tagCount = {
    for (final n in b.notes)
      for (final t in n.tagNames) t.toLowerCase(),
  }.length;

  return _reviewAndImport(
    context,
    repo,
    title: title,
    batch: b,
    summary: tagCount == 0
        ? 'Seçimde ${b.notes.length} not var.'
        : 'Seçimde ${b.notes.length} not ve $tagCount etiket var.',
    allPresent:
        'Seçilen ${b.notes.length} notun hepsi zaten Müsvedde\'de bulunuyor.',
    placement: '$placement Ön bilgideki etiketler aynı adlı mevcut '
        'etiketlerle birleştirilir.',
    remarks: [
      if (r.duplicates > 0)
        'Birebir aynı içerikli ${r.duplicates} dosya yalnızca bir kez alınacak.',
      if (r.skippedUnsupported > 0)
        '${r.skippedUnsupported} dosya desteklenmeyen türde olduğu için atlandı.',
      if (r.skippedLarge > 0) '5 MB\'tan büyük ${r.skippedLarge} dosya atlandı.',
      if (r.skippedUnreadable > 0)
        '${r.skippedUnreadable} dosya metin olarak okunamadığı için atlandı.',
    ],
  );
}

// ------------------------------------------------------- Ortak önizleme akışı

/// Önce kuru çalıştırmayla ne ekleneceğini gösterir, onaylanırsa içe aktarır.
Future<void> _reviewAndImport(
  BuildContext context,
  NotesRepository repo, {
  required String title,
  required ImportBatch batch,
  required String summary,
  required String allPresent,
  required String placement,
  List<String> remarks = const [],
}) async {
  if (batch.notes.isEmpty) {
    await _info(context, 'İçe aktarılacak not yok',
        ['Seçimde içe aktarılabilecek bir dosya bulunamadı.', ...remarks]
            .join('\n\n'));
    return;
  }

  final plan = await repo.importBatch(batch, dryRun: true);
  if (!context.mounted) return;

  if (plan.notesAdded == 0) {
    await _info(context, 'Eklenecek bir şey yok', allPresent);
    return;
  }

  final added = [
    '${plan.notesAdded} not',
    '${plan.tagsAdded} yeni etiket',
    if (plan.foldersAdded > 0) '${plan.foldersAdded} klasör',
  ].join(', ');

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final muted = Theme.of(ctx).textTheme.bodySmall
          ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary),
              const SizedBox(height: 12),
              Text('Eklenecek: $added.',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text(placement, style: muted),
              if (plan.notesSkipped > 0) ...[
                const SizedBox(height: 8),
                Text('${plan.notesSkipped} not zaten içe aktarılmış; tekrar '
                    'eklenmeyecek.', style: muted),
              ],
              for (final r in remarks) ...[
                const SizedBox(height: 8),
                Text(r, style: muted),
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

  final result = await _withProgress(
      context, 'İçe aktarılıyor…', () => repo.importBatch(batch));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
        '${result.notesAdded} not ve ${result.tagsAdded} etiket içe aktarıldı.'),
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
