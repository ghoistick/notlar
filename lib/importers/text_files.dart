import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:path/path.dart' as p;

import '../backup/restore.dart';
import '../data/db/tables.dart';
import '../data/repository/import_records.dart';

/// İçe aktarılacak tek bir dosya.
class TextSourceFile {
  /// Seçilen klasöre göre '/' ayraçlı yol ("Proje/Alt/Not.md").
  /// Tek tek seçilen dosyalarda yalnızca dosya adı.
  final String path;
  final Uint8List bytes;
  final DateTime? modified;

  const TextSourceFile(this.path, this.bytes, {this.modified});
}

class TextFilesResult {
  final ImportBatch batch;

  /// Klasör içe aktarımında seçilen klasörün adı; dosya seçiminde null.
  final String? rootName;

  /// .md, .markdown ve .txt dışındaki dosyalar.
  final int skippedUnsupported;

  /// [TextFilesImporter.maxBytes] sınırını aşan dosyalar.
  final int skippedLarge;

  /// Metin olarak okunamayan (ikili ya da erişilemeyen) dosyalar.
  final int skippedUnreadable;

  /// Seçimde birebir aynı içerikli olduğu için bir kez alınan dosyalar.
  final int duplicates;

  const TextFilesResult({
    required this.batch,
    this.rootName,
    this.skippedUnsupported = 0,
    this.skippedLarge = 0,
    this.skippedUnreadable = 0,
    this.duplicates = 0,
  });
}

/// .txt ve .md dosyalarının içe aktarımı (tek dosya, çoklu dosya, klasör).
///
/// Kimlikler:
///  - Müsvedde'nin kendi Markdown dosyasıysa (ön bilgide id, kind, type)
///    notun kendi kimliği kullanılır.
///  - Diğer dosyalarda kimlik içerikten üretilir: "md-" + SHA-256(başlık +
///    gövde). Aynı dosyayı tekrar içe aktarmak bir şey eklemez; değişmiş bir
///    dosya yeni not olur, var olan nota dokunulmaz.
///
/// Klasörler:
///  - Dosya seçiminde notlar "İçe aktarılan dosyalar" klasörüne konur.
///  - Klasör seçiminde seçilen klasör kökte açılır, alt klasörler iç içe
///    kurulur. Klasör kimlikleri göreli yoldan üretilir; aynı klasörü tekrar
///    içe aktarmak klasörleri çoğaltmaz.
abstract final class TextFilesImporter {
  static const folderId = 'files-import';
  static const folderName = 'İçe aktarılan dosyalar';
  static const extensions = ['md', 'markdown', 'txt'];
  static const maxBytes = 5 * 1024 * 1024;

  static bool isSupported(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 &&
        extensions.contains(fileName.substring(dot + 1).toLowerCase());
  }

  // ------------------------------------------------------------ Okuma

  /// Kullanıcının seçtiği dosyalar. Android'de yol her zaman gerçek bir dosya
  /// olmadığından içerik XFile üzerinden okunur.
  static Future<TextFilesResult> readFiles(List<XFile> files) async {
    final sources = <TextSourceFile>[];
    var unsupported = 0, large = 0, unreadable = 0;
    for (final f in files) {
      if (!isSupported(f.name)) {
        unsupported++;
        continue;
      }
      try {
        if (await f.length() > maxBytes) {
          large++;
          continue;
        }
        DateTime? modified;
        try {
          modified = await f.lastModified();
        } catch (_) {
          // Bazı Android sağlayıcıları değiştirilme zamanı vermez.
        }
        sources.add(TextSourceFile(f.name, await f.readAsBytes(),
            modified: modified));
      } catch (_) {
        unreadable++;
      }
    }
    return build(sources,
        skippedUnsupported: unsupported,
        skippedLarge: large,
        skippedUnreadable: unreadable);
  }

  /// Bir klasör ve alt klasörleri (yalnızca masaüstü). Adı nokta ile
  /// başlayan dosya ve klasörler (.git, .obsidian…) atlanır.
  static Future<TextFilesResult> readDirectory(String dirPath) async {
    final root = Directory(dirPath);
    var rootName = p.basename(p.normalize(dirPath));
    if (rootName.isEmpty || rootName.endsWith(':')) rootName = 'Klasör';

    final sources = <TextSourceFile>[];
    var unsupported = 0, large = 0, unreadable = 0;

    Future<void> walk(Directory dir, String rel) async {
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        unreadable++;
        return;
      }
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        final path = rel.isEmpty ? name : '$rel/$name';
        if (e is Directory) {
          await walk(e, path);
        } else if (e is File) {
          if (!isSupported(name)) {
            unsupported++;
            continue;
          }
          try {
            final stat = await e.stat();
            if (stat.size > maxBytes) {
              large++;
              continue;
            }
            sources.add(TextSourceFile(path, await e.readAsBytes(),
                modified: stat.modified));
          } on FileSystemException {
            unreadable++;
          }
        }
      }
    }

    await walk(root, '');
    return build(sources,
        rootName: rootName,
        skippedUnsupported: unsupported,
        skippedLarge: large,
        skippedUnreadable: unreadable);
  }

  // ------------------------------------------------------- Dönüştürme

  /// Okunan dosyalardan içe aktarma paketi kurar. [rootName] verilirse
  /// klasör yapısı kurulur; verilmezse hepsi [folderId] klasörüne gider.
  static TextFilesResult build(
    List<TextSourceFile> files, {
    String? rootName,
    int skippedUnsupported = 0,
    int skippedLarge = 0,
    int skippedUnreadable = 0,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final folders = <String, ImportFolder>{};
    final notes = <ImportNote>[];
    final seen = <String>{};
    var unreadable = skippedUnreadable, duplicates = 0;

    String folderFor(String path) {
      if (rootName == null) {
        folders.putIfAbsent(
            folderId, () => const ImportFolder(id: folderId, name: folderName));
        return folderId;
      }
      final segments = [rootName, ...(path.split('/')..removeLast())];
      String? parent;
      var joined = '';
      for (final seg in segments) {
        joined = joined.isEmpty ? seg : '$joined/$seg';
        final id = folderIdForPath(joined);
        final parentId = parent;
        folders.putIfAbsent(
            id, () => ImportFolder(id: id, name: seg, parentId: parentId));
        parent = id;
      }
      return parent!;
    }

    // Aynı seçim her seferinde aynı sırayla işlensin.
    final sorted = [...files]..sort((a, b) => a.path.compareTo(b.path));
    for (final f in sorted) {
      final text = decodeText(f.bytes);
      if (text == null) {
        unreadable++;
        continue;
      }
      final note = noteFromText(
        text,
        fileName: f.path.split('/').last,
        modified: f.modified?.millisecondsSinceEpoch ?? now,
      );
      if (!seen.add(note.id)) {
        duplicates++;
        continue;
      }
      notes.add(_withFolder(note, folderFor(f.path)));
    }

    return TextFilesResult(
      batch: ImportBatch(folders: folders.values.toList(), notes: notes),
      rootName: rootName,
      skippedUnsupported: skippedUnsupported,
      skippedLarge: skippedLarge,
      skippedUnreadable: unreadable,
      duplicates: duplicates,
    );
  }

  /// Bir dosyanın metnini nota çevirir.
  ///
  /// Başlık sırası: ön bilgideki title, ilk satırdaki "# Başlık", dosya adı.
  /// .txt dosyalarında ön bilgi ve başlık satırı aranmaz; başlık dosya adıdır.
  /// "# Başlık" satırı gövdede kalır.
  static ImportNote noteFromText(
    String text, {
    required String fileName,
    String? folderId,
    required int modified,
  }) {
    final stem = _stem(fileName);

    if (fileName.toLowerCase().endsWith('.txt')) {
      final body = _trimFinalNewline(text.replaceAll('\r\n', '\n'));
      return ImportNote(
        id: _contentId(stem, body),
        folderId: folderId,
        title: stem,
        body: body,
        createdAt: modified,
        updatedAt: modified,
      );
    }

    final (fm, rawBody) = splitFrontMatter(text);

    // Müsvedde'nin kendi dosyası: bütün alanlar ve kimlik korunur.
    if (fm['id'] is String &&
        NoteKind.values.any((k) => k.name == fm['kind']) &&
        NoteType.values.any((t) => t.name == fm['type'])) {
      return _withFolder(
          noteFromMarkdown(text, fallbackTitle: stem), folderId);
    }

    final body = fm.isEmpty ? _trimFinalNewline(rawBody) : rawBody;
    final fmTitle = fm['title'];
    final title = fmTitle is String && fmTitle.trim().isNotEmpty
        ? fmTitle.trim()
        : (_firstHeading(body) ?? stem);

    final created =
        _time(fm['created'] ?? fm['date'] ?? fm['created_at']) ?? modified;
    final updated = _time(fm['updated'] ??
            fm['modified'] ??
            fm['updated_at'] ??
            fm['lastmod']) ??
        max<int>(modified, created);

    return ImportNote(
      id: _contentId(title, body),
      folderId: folderId,
      title: title,
      body: body,
      pinned: fm['pinned'] == true,
      archived: fm['archived'] == true,
      createdAt: created,
      updatedAt: updated,
      tagNames: _tags(fm['tags'] ?? fm['tag'] ?? fm['keywords']),
    );
  }

  /// Klasör kimliği: kökten itibaren göreli yolun özeti.
  static String folderIdForPath(String path) =>
      'dir-${_hex(utf8.encode(path.toLowerCase())).substring(0, 24)}';

  // ---------------------------------------------------------- Kodlama

  /// Baytları metne çevirir: UTF-16 (BOM'lu), UTF-8 (BOM'lu ya da BOM'suz),
  /// geçersiz UTF-8 ise Windows-1254. İkili dosyalarda null döner.
  static String? decodeText(Uint8List b) {
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return _utf16(b, 2, littleEndian: true);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return _utf16(b, 2, littleEndian: false);
    }
    var bytes = b;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      bytes = Uint8List.sublistView(b, 3);
    }
    // Metin dosyasında NUL baytı olmaz; varsa ikili dosyadır.
    if (bytes.contains(0)) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return _cp1254(bytes);
    }
  }

  static String _utf16(Uint8List b, int start, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = start; i + 1 < b.length; i += 2) {
      units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// Windows-1254'ün 0x80–0x9F aralığı (tanımsızlar U+FFFD).
  static const _cp1254Control = [
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0xFFFD, 0xFFFD, //
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0xFFFD, 0x0178, //
  ];

  /// 0xA0–0xFF Latin-1 ile aynıdır; yalnızca altı Türkçe harf farklıdır.
  static String _cp1254(List<int> bytes) {
    final codes = List<int>.filled(bytes.length, 0);
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      codes[i] = b < 0x80
          ? b
          : b < 0xA0
              ? _cp1254Control[b - 0x80]
              : switch (b) {
                  0xD0 => 0x011E, // Ğ
                  0xDD => 0x0130, // İ
                  0xDE => 0x015E, // Ş
                  0xF0 => 0x011F, // ğ
                  0xFD => 0x0131, // ı
                  0xFE => 0x015F, // ş
                  _ => b,
                };
    }
    return String.fromCharCodes(codes);
  }

  // -------------------------------------------------------- Yardımcılar

  static String _stem(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  static String _trimFinalNewline(String s) =>
      s.endsWith('\n') ? s.substring(0, s.length - 1) : s;

  static final _h1 = RegExp(r'^#\s+(.*?)\s*#*\s*$');

  /// İlk dolu satır "# Başlık" ise başlık metni.
  static String? _firstHeading(String body) {
    for (final line in body.split('\n')) {
      if (line.trim().isEmpty) continue;
      final m = _h1.firstMatch(line.trim());
      final t = m?.group(1)?.trim();
      return t == null || t.isEmpty ? null : t;
    }
    return null;
  }

  static int? _time(Object? v) => v is String
      ? DateTime.tryParse(v.trim())?.millisecondsSinceEpoch
      : null;

  /// Liste ya da "a, b" / "a b" biçiminde etiketler. Baştaki # atılır,
  /// harf farkı gözetmeden tekrarlar çıkarılır.
  static List<String> _tags(Object? v) {
    final raw = <String>[];
    if (v is List) {
      raw.addAll(v.whereType<String>());
    } else if (v is String) {
      raw.addAll(v.contains(',') ? v.split(',') : v.split(RegExp(r'\s+')));
    }
    final out = <String>[];
    final seen = <String>{};
    for (var t in raw) {
      t = t.trim();
      while (t.startsWith('#')) {
        t = t.substring(1).trim();
      }
      if (t.isNotEmpty && seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  static String _contentId(String title, String body) =>
      'md-${_hex(utf8.encode('$title\u0000$body')).substring(0, 32)}';

  static String _hex(List<int> data) => const DartSha256()
      .hashSync(data)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static ImportNote _withFolder(ImportNote n, String? folderId) => ImportNote(
        id: n.id,
        folderId: folderId,
        kind: n.kind,
        type: n.type,
        title: n.title,
        body: n.body,
        color: n.color,
        pinned: n.pinned,
        archived: n.archived,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
        tagNames: n.tagNames,
      );
}
