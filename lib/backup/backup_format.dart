import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../data/db/database.dart';
import '../data/repository/notes_repository.dart';
import 'tar.dart';

const backupFormatName = 'notlar-yedek';
const backupFormatVersion = 1;

/// Arşivin içindeki tek dosyanın adı (7-Zip arşivinin içinde).
const backupInnerName = 'notlar.tar';

/// Yedeklenecek verinin bir anlık görüntüsü.
class BackupSnapshot {
  final List<Folder> folders;
  final List<Tag> tags;
  final List<Note> notes;
  final Map<String, List<String>> tagNames; // not kimliği -> etiket adları
  final DateTime createdAt;

  const BackupSnapshot({
    required this.folders,
    required this.tags,
    required this.notes,
    required this.tagNames,
    required this.createdAt,
  });

  /// Çöp kutusundakiler hariç tüm notlar (arşivlenenler dahil).
  static Future<BackupSnapshot> fromRepository(
    NotesRepository repo, {
    DateTime? now,
  }) async {
    return BackupSnapshot(
      folders: await repo.listFolders(),
      tags: await repo.listTags(),
      notes: await repo.notesForBackup(),
      tagNames: await repo.tagNamesByNote(),
      createdAt: now ?? DateTime.now(),
    );
  }
}

/// Yedeğin içeriği: klasör ağacıyla birebir dizinler, her not bir Markdown
/// dosyası ve en üstte manifest.json.
///
///   notlar/
///     manifest.json
///     Projeler/
///       Not Uygulaması/
///         2026-10-15 Mimari notları.md
///     2026-10-14 Klasörsüz not.md
Future<Uint8List> buildBackupTar(BackupSnapshot s) async {
  const root = 'notlar';
  final w = TarWriter();
  final mtime = s.createdAt.millisecondsSinceEpoch ~/ 1000;
  final dirs = folderDirPaths(s.folders);

  w.addDirectory(root, mtime: mtime);
  for (final d in (dirs.values.toList()..sort())) {
    w.addDirectory('$root/$d', mtime: mtime);
  }

  final used = <String>{};
  final files = <Map<String, Object>>[];

  for (final note in s.notes) {
    final dir = note.folderId == null ? null : dirs[note.folderId];
    final base = noteFileBase(note);
    String pathFor(String name) => dir == null ? '$root/$name' : '$root/$dir/$name';

    var path = pathFor('$base.md');
    var n = 2;
    while (used.contains(path.toLowerCase())) {
      path = pathFor('$base ($n).md');
      n++;
    }
    used.add(path.toLowerCase());

    final content = utf8.encode(noteToMarkdown(
      note,
      folderPath: dir,
      tags: s.tagNames[note.id] ?? const [],
    ));
    w.addFile(path, content, mtime: note.updatedAt ~/ 1000);
    files.add({
      'path': path.substring(root.length + 1),
      'id': note.id,
      'size': content.length,
      'sha256': await _sha256(content),
    });
  }

  final manifest = {
    'format': backupFormatName,
    'version': backupFormatVersion,
    'createdAt': isoWithOffset(s.createdAt),
    'counts': {
      'notes': s.notes.length,
      'folders': s.folders.length,
      'tags': s.tags.length,
    },
    'folders': [
      for (final f in s.folders)
        {
          'id': f.id,
          'name': f.name,
          'parentId': f.parentId,
          'color': f.color,
          'position': f.position,
          'path': dirs[f.id],
        },
    ],
    'tags': [
      for (final t in s.tags)
        {'id': t.id, 'name': t.name, 'color': t.color, 'parentId': t.parentId},
    ],
    'files': files,
  };
  w.addFile('$root/manifest.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      mtime: mtime);

  return w.finish();
}

/// Notun Markdown dosyası: YAML ön bilgisi + gövde.
///
/// Metin değerleri JSON tırnaklarıyla yazılır; bu geçerli YAML'dır ve özel
/// karakterleri güvenle taşır.
String noteToMarkdown(
  Note note, {
  String? folderPath,
  List<String> tags = const [],
}) {
  final b = StringBuffer()
    ..writeln('---')
    ..writeln('id: ${jsonEncode(note.id)}')
    ..writeln('kind: ${note.kind.name}')
    ..writeln('type: ${note.type.name}')
    ..writeln('title: ${jsonEncode(note.title)}');
  if (folderPath != null) b.writeln('folder: ${jsonEncode(folderPath)}');
  if (tags.isNotEmpty) b.writeln('tags: ${jsonEncode(tags)}');
  if (note.color != null) b.writeln('color: ${note.color}');
  if (note.pinned) b.writeln('pinned: true');
  if (note.archived) b.writeln('archived: true');
  b
    ..writeln('created: ${isoWithOffset(DateTime.fromMillisecondsSinceEpoch(note.createdAt))}')
    ..writeln('updated: ${isoWithOffset(DateTime.fromMillisecondsSinceEpoch(note.updatedAt))}')
    ..writeln('---')
    ..writeln()
    ..write(note.body);
  if (!note.body.endsWith('\n')) b.writeln();
  return b.toString();
}

/// Klasör kimliği -> arşiv içindeki dizin yolu. Aynı üst klasörde aynı adlı
/// iki klasör varsa ikincisine " (2)" eklenir. Üst klasörü bulunmayanlar
/// köke konur.
Map<String, String> folderDirPaths(List<Folder> folders) {
  final ids = {for (final f in folders) f.id};
  final byParent = <String?, List<Folder>>{};
  for (final f in folders) {
    final parent = f.parentId != null && ids.contains(f.parentId) ? f.parentId : null;
    byParent.putIfAbsent(parent, () => []).add(f);
  }

  final out = <String, String>{};
  void walk(String? parentId, String prefix, Set<String> seen) {
    final kids = [...?byParent[parentId]]
      ..sort((a, b) {
        final p = a.position.compareTo(b.position);
        return p != 0 ? p : a.name.compareTo(b.name);
      });
    final used = <String>{};
    for (final k in kids) {
      if (seen.contains(k.id)) continue;
      final seg = sanitizePathSegment(k.name);
      var name = seg;
      var n = 2;
      while (used.contains(name.toLowerCase())) {
        name = '$seg ($n)';
        n++;
      }
      used.add(name.toLowerCase());
      final path = prefix.isEmpty ? name : '$prefix/$name';
      out[k.id] = path;
      walk(k.id, path, {...seen, k.id});
    }
  }

  walk(null, '', const {});
  return out;
}

/// "2026-10-15 Başlık" — dosya adı olarak güvenli hale getirilmiş.
String noteFileBase(Note note) {
  final d = DateTime.fromMillisecondsSinceEpoch(note.createdAt);
  final date = '${d.year}-${_two(d.month)}-${_two(d.day)}';
  final title = note.title.trim().isNotEmpty
      ? note.title.trim()
      : (note.kind == NoteKind.snippet ? 'Kısa not' : 'Başlıksız');
  return sanitizePathSegment('$date $title');
}

final _invalidChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
final _reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
    caseSensitive: false);

/// Windows, Linux ve Android'de geçerli dosya/klasör adı.
String sanitizePathSegment(String name, {int maxLength = 80}) {
  var s = name.replaceAll(_invalidChars, '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > maxLength) s = s.substring(0, maxLength).trim();
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) return '_';
  if (_reserved.hasMatch(s)) return '${s}_';
  return s;
}

String isoWithOffset(DateTime local) {
  final d = local.toLocal();
  final off = d.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}'
      'T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}'
      '$sign${_two(abs.inHours)}:${_two(abs.inMinutes % 60)}';
}

String _two(int v) => v.toString().padLeft(2, '0');

Future<String> _sha256(List<int> data) async {
  final hash = await Sha256().hash(data);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
