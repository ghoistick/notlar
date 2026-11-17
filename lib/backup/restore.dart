import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/db/tables.dart';
import '../data/repository/import_records.dart';
import 'backup_format.dart';
import 'tar.dart';

class InvalidBackupException implements Exception {
  final String message;
  const InvalidBackupException(this.message);

  @override
  String toString() => message;
}

/// Yedekten okunan içerik.
class BackupContent {
  final DateTime? createdAt;
  final ImportBatch batch;
  const BackupContent({required this.createdAt, required this.batch});
}

/// [buildBackupTar] ile yazılmış arşivi okur.
BackupContent parseBackupTar(Uint8List tarBytes) {
  final List<TarEntry> entries;
  try {
    entries = readTar(tarBytes);
  } catch (_) {
    throw const InvalidBackupException('Yedek dosyası okunamadı; bozuk olabilir.');
  }

  const root = 'notlar';
  final manifestEntry =
      entries.where((e) => e.path == '$root/manifest.json').firstOrNull;
  if (manifestEntry == null) {
    throw const InvalidBackupException(
        'Bu dosya bir Müsvedde yedeği değil (manifest bulunamadı).');
  }

  final Map<String, dynamic> m;
  try {
    m = jsonDecode(utf8.decode(manifestEntry.data)) as Map<String, dynamic>;
  } catch (_) {
    throw const InvalidBackupException('Yedeğin içerik listesi bozuk.');
  }
  if (m['format'] != backupFormatName) {
    throw const InvalidBackupException('Bu dosya bir Müsvedde yedeği değil.');
  }
  if ((m['version'] as int? ?? 0) > backupFormatVersion) {
    throw const InvalidBackupException(
        'Bu yedek uygulamanın daha yeni bir sürümüyle alınmış. '
        'Önce uygulamayı güncelle.');
  }

  final folders = <ImportFolder>[];
  final pathToFolder = <String, String>{};
  for (final f in (m['folders'] as List? ?? const [])) {
    final map = f as Map<String, dynamic>;
    final id = map['id'] as String;
    folders.add(ImportFolder(
      id: id,
      name: map['name'] as String,
      parentId: map['parentId'] as String?,
      color: map['color'] as String?,
      position: map['position'] as int? ?? 0,
    ));
    final path = map['path'] as String?;
    if (path != null) pathToFolder[path] = id;
  }

  final tags = [
    for (final t in (m['tags'] as List? ?? const []))
      ImportTag(
        id: (t as Map<String, dynamic>)['id'] as String,
        name: t['name'] as String,
        color: t['color'] as String?,
      ),
  ];

  final notes = <ImportNote>[];
  for (final e in entries) {
    if (e.isDirectory || !e.path.endsWith('.md')) continue;
    final rel = e.path.startsWith('$root/') ? e.path.substring(root.length + 1) : e.path;
    final slash = rel.lastIndexOf('/');
    final dirPath = slash < 0 ? null : rel.substring(0, slash);
    final fileName = slash < 0 ? rel : rel.substring(slash + 1);

    notes.add(noteFromMarkdown(
      utf8.decode(e.data, allowMalformed: true),
      fallbackTitle: fileName.substring(0, fileName.length - 3),
      folderIdForPath: (p) => pathToFolder[p],
      dirPath: dirPath,
    ));
  }

  return BackupContent(
    createdAt: DateTime.tryParse(m['createdAt'] as String? ?? ''),
    batch: ImportBatch(folders: folders, tags: tags, notes: notes),
  );
}

/// Ön bilgili (YAML front matter) bir Markdown dosyasını nota çevirir.
/// Ön bilgi yoksa dosya adı başlık, içeriğin tamamı gövde olur.
ImportNote noteFromMarkdown(
  String text, {
  required String fallbackTitle,
  String? Function(String path)? folderIdForPath,
  String? dirPath,
}) {
  final (fm, body) = splitFrontMatter(text);
  final now = DateTime.now().millisecondsSinceEpoch;

  int time(Object? v) =>
      v is String ? (DateTime.tryParse(v)?.millisecondsSinceEpoch ?? now) : now;

  final folderPath = fm['folder'] as String? ?? dirPath;
  final tags = fm['tags'];

  return ImportNote(
    id: fm['id'] is String ? fm['id'] as String : uuidV7(),
    folderId: folderPath == null ? null : folderIdForPath?.call(folderPath),
    kind: _enumByName(NoteKind.values, fm['kind'], NoteKind.note),
    type: _enumByName(NoteType.values, fm['type'], NoteType.text),
    title: fm['title'] is String ? fm['title'] as String : fallbackTitle,
    body: body,
    color: fm['color'] as String?,
    pinned: fm['pinned'] == true,
    archived: fm['archived'] == true,
    createdAt: time(fm['created']),
    updatedAt: time(fm['updated'] ?? fm['created']),
    tagNames: tags is List ? tags.whereType<String>().toList() : const [],
  );
}

/// "---\nanahtar: değer\n---\n\ngövde\n" -> ({anahtar: değer}, "gövde")
///
/// Müsvedde'nin yazdığı biçimin yanında başka uygulamaların (Obsidian, Hugo
/// vb.) basit YAML ön bilgisini de okur:
///  - tek tırnaklı metin: 'Ali''nin notu'
///  - tırnaksız satır içi liste: [iş, ev]
///  - alt alta liste:  tags:\n  - iş\n  - ev
///  - dosyanın sonunda biten ön bilgi (kapanış --- satırından sonra metin yok)
/// İç içe yapılar (girintili anahtarlar) yok sayılır.
(Map<String, Object?>, String) splitFrontMatter(String text) {
  var t = text.replaceAll('\r\n', '\n');
  if (t.startsWith('\uFEFF')) t = t.substring(1);
  if (!t.startsWith('---\n')) return (const {}, t);

  var end = t.indexOf('\n---\n', 3);
  final int bodyStart;
  if (end >= 0) {
    bodyStart = end + 5;
  } else if (t.endsWith('\n---')) {
    end = t.length - 4;
    bodyStart = t.length;
  } else {
    return (const {}, t);
  }

  // "---\n---\n" gibi boş bir ön bilgide end, başlığın başından önce kalır.
  final header = end > 4 ? t.substring(4, end) : '';
  var body = t.substring(bodyStart);
  if (body.startsWith('\n')) body = body.substring(1);
  if (body.endsWith('\n')) body = body.substring(0, body.length - 1);

  final map = <String, Object?>{};
  String? listKey; // değeri boş bırakılmış, altında "- öğe" beklenen anahtar
  for (final line in header.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    if (trimmed == '-' || trimmed.startsWith('- ')) {
      if (listKey != null) {
        final v = _yamlValue(trimmed.substring(1).trim());
        if (v != null) {
          final list = map[listKey];
          if (list is List<Object?>) {
            list.add(v);
          } else {
            map[listKey] = <Object?>[v];
          }
        }
      }
      continue;
    }

    // Girintili satır: iç içe yapı; desteklenmiyor.
    if (line.startsWith(' ') || line.startsWith('\t')) {
      listKey = null;
      continue;
    }

    final i = line.indexOf(':');
    if (i <= 0) {
      listKey = null;
      continue;
    }
    final key = line.substring(0, i).trim();
    final raw = line.substring(i + 1).trim();
    map[key] = _yamlValue(raw);
    listKey = raw.isEmpty ? key : null;
  }
  return (map, body);
}

Object? _yamlValue(String raw) {
  if (raw.isEmpty || raw == 'null' || raw == '~') return null;
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'")) {
    return raw.substring(1, raw.length - 1).replaceAll("''", "'");
  }
  if (raw.startsWith('"') || raw.startsWith('[')) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      // Tırnaksız liste: [iş, ev]
      if (raw.startsWith('[') && raw.endsWith(']')) {
        final inner = raw.substring(1, raw.length - 1).trim();
        if (inner.isEmpty) return <Object?>[];
        return [
          for (final part in inner.split(','))
            if (_yamlValue(part.trim()) case final Object v) v,
        ];
      }
      return raw;
    }
  }
  return raw;
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
