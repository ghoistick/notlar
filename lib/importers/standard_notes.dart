import 'dart:convert';
import 'dart:io';

import '../data/repository/import_records.dart';
import 'zip_reader.dart';

class ImportFormatException implements Exception {
  final String message;
  const ImportFormatException(this.message);

  @override
  String toString() => message;
}

/// Standard Notes içe aktarımı.
///
/// Standard Notes'un "Decrypted" (şifresiz) yedeğini okur: ZIP'in kendisi ya
/// da içindeki "Standard Notes Backup and Import File.txt" seçilebilir.
/// Notlar Standard Notes'taki kimlikleriyle aktarılır; aynı yedeği tekrar
/// içe aktarmak hiçbir şeyi çoğaltmaz.
abstract final class StandardNotesImporter {
  static const backupFileName = 'Standard Notes Backup and Import File.txt';

  /// Bütün notlar bu klasöre konur; kullanıcı sonra istediği yere taşır.
  static const folderId = 'standardnotes-import';
  static const folderName = 'Standard Notes';

  static Future<StandardNotesResult> readFile(String path) async {
    final bytes = await File(path).readAsBytes();
    String text;
    if (SimpleZipReader.looksLikeZip(bytes)) {
      final zip = SimpleZipReader(bytes);
      final entry = zip.findByFileName(backupFileName);
      if (entry == null) {
        throw const ImportFormatException(
            'ZIP içinde Standard Notes yedek dosyası bulunamadı.');
      }
      text = utf8.decode(zip.read(entry), allowMalformed: true);
    } else {
      text = utf8.decode(bytes, allowMalformed: true);
    }
    return parse(text);
  }

  static StandardNotesResult parse(String text) {
    final Map<String, dynamic> root;
    try {
      root = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const ImportFormatException('Dosya bir Standard Notes yedeği gibi görünmüyor.');
    }
    final items = root['items'];
    if (items is! List) {
      throw const ImportFormatException('Dosya bir Standard Notes yedeği gibi görünmüyor.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    int time(Object? v) =>
        v is String ? (DateTime.tryParse(v)?.millisecondsSinceEpoch ?? now) : now;

    var encrypted = 0;
    var trashed = 0;
    final tags = <ImportTag>[];
    final tagNamesByNote = <String, List<String>>{};
    final noteItems = <Map<String, dynamic>>[];

    for (final raw in items) {
      if (raw is! Map<String, dynamic> || raw['deleted'] == true) continue;
      final content = raw['content'];
      if (content is String) {
        // Şifreli yedekte içerik "004:…" biçiminde okunamaz bir metindir.
        encrypted++;
        continue;
      }
      if (content is! Map<String, dynamic>) continue;

      switch (raw['content_type']) {
        case 'Tag':
          final title = (content['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) continue;
          tags.add(ImportTag(id: raw['uuid'] as String, name: title));
          for (final ref in (content['references'] as List? ?? const [])) {
            if (ref is Map && ref['content_type'] == 'Note' && ref['uuid'] is String) {
              tagNamesByNote.putIfAbsent(ref['uuid'] as String, () => []).add(title);
            }
          }
        case 'Note':
          noteItems.add(raw);
      }
    }

    if (encrypted > 0 && noteItems.isEmpty) {
      throw const ImportFormatException(
          'Bu yedek şifreli. Standard Notes\'ta yedeği "Decrypted" '
          'seçeneğiyle yeniden dışa aktar.');
    }

    final notes = <ImportNote>[];
    for (final raw in noteItems) {
      final content = raw['content'] as Map<String, dynamic>;
      if (content['trashed'] == true) {
        trashed++;
        continue;
      }
      final appData = content['appData'];
      final sn = appData is Map ? appData['org.standardnotes.sn'] : null;
      final meta = sn is Map ? sn : const {};
      final id = raw['uuid'] as String;

      notes.add(ImportNote(
        id: id,
        folderId: folderId,
        title: (content['title'] as String?) ?? '',
        body: (content['text'] as String?) ?? '',
        pinned: meta['pinned'] == true,
        archived: meta['archived'] == true,
        createdAt: time(raw['created_at']),
        updatedAt: time(meta['client_updated_at'] ?? raw['updated_at']),
        tagNames: tagNamesByNote[id] ?? const [],
      ));
    }

    return StandardNotesResult(
      batch: ImportBatch(
        folders: const [ImportFolder(id: folderId, name: folderName)],
        tags: tags,
        notes: notes,
      ),
      skippedTrashed: trashed,
      skippedEncrypted: encrypted,
    );
  }
}

class StandardNotesResult {
  final ImportBatch batch;

  /// Standard Notes'un çöp kutusunda olduğu için aktarılmayan notlar.
  final int skippedTrashed;

  /// Okunamayan (şifreli) kayıtlar.
  final int skippedEncrypted;

  const StandardNotesResult({
    required this.batch,
    required this.skippedTrashed,
    required this.skippedEncrypted,
  });
}
