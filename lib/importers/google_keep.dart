import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:file_selector/file_selector.dart' show XFile;

import '../data/db/tables.dart';
import '../data/repository/import_records.dart';
import 'zip_reader.dart';

/// Okunacak bir dosya: Takeout ZIP'inin içindeki ya da tek tek seçilen .json.
class KeepSourceFile {
  final String name;
  final Uint8List bytes;
  const KeepSourceFile(this.name, this.bytes);
}

class KeepResult {
  final ImportBatch batch;

  /// Keep'in çöp kutusundaki notlar.
  final int skippedTrashed;

  /// Başlığı ve metni olmayan notlar (çoğunlukla yalnızca resim).
  final int skippedEmpty;

  /// Eki (resim, ses, çizim) olan notlar: metinleri alınır, ekleri alınmaz.
  final int withAttachments;

  /// Seçimde birden fazla kez bulunan notlar (ör. ZIP ve içindeki dosyalar
  /// birlikte seçildiyse).
  final int duplicates;

  /// Okunamayan dosyalar.
  final int unreadable;

  const KeepResult({
    required this.batch,
    this.skippedTrashed = 0,
    this.skippedEmpty = 0,
    this.withAttachments = 0,
    this.duplicates = 0,
    this.unreadable = 0,
  });
}

/// Google Keep içe aktarımı (Google Takeout).
///
/// Takeout her notu hem .html hem .json olarak verir; yalnızca .json okunur.
/// Takeout ZIP'inin kendisi ya da açılmış klasördeki .json dosyaları
/// seçilebilir. ZIP'te başka hizmetlerin dosyaları da olabilir: içerikten Keep
/// notu olduğu anlaşılmayan .json dosyaları sessizce atlanır.
///
/// Notlar kısa not (snippet) olarak "Google Keep" klasörüne konur. Keep
/// etiketleri Müsvedde etiketi, liste notları checklist olur.
///
/// Keep'te not kimliği yoktur; kimlik oluşturma zamanı ve başlıktan üretilir.
/// Aynı dışa aktarımı tekrar içe aktarmak bir şey eklemez; Keep'te sonradan
/// düzenlenmiş bir not da çoğaltılmaz (var olan nota dokunulmaz).
abstract final class GoogleKeepImporter {
  static const folderId = 'keep-import';
  static const folderName = 'Google Keep';

  /// Keep renkleri -> Müsvedde renk anahtarları (note_colors.dart).
  static const colorMap = {
    'RED': 'kirmizi',
    'PINK': 'kirmizi',
    'ORANGE': 'turuncu',
    'BROWN': 'turuncu',
    'YELLOW': 'sari',
    'GREEN': 'yesil',
    'TEAL': 'turkuaz',
    'BLUE': 'mavi',
    'CERULEAN': 'mavi',
    'PURPLE': 'mor',
    'GRAY': 'gri',
  };

  // ------------------------------------------------------------ Okuma

  /// Seçilen .zip ve .json dosyaları.
  static Future<KeepResult> readFiles(List<XFile> files) async {
    final sources = <KeepSourceFile>[];
    var unreadable = 0;
    for (final f in files) {
      final lower = f.name.toLowerCase();
      if (!lower.endsWith('.zip') && !lower.endsWith('.json')) continue;
      try {
        final bytes = await f.readAsBytes();
        if (SimpleZipReader.looksLikeZip(bytes)) {
          sources.addAll(_jsonEntries(bytes));
        } else {
          sources.add(KeepSourceFile(f.name, bytes));
        }
      } on FormatException {
        rethrow; // ZIP okunamadı: kullanıcıya nedeniyle gösterilir
      } catch (_) {
        unreadable++;
      }
    }
    return parseAll(sources, unreadable: unreadable);
  }

  static List<KeepSourceFile> _jsonEntries(Uint8List zipBytes) {
    final zip = SimpleZipReader(zipBytes);
    return [
      for (final e in zip.entries)
        if (!e.isDirectory && e.name.toLowerCase().endsWith('.json'))
          KeepSourceFile(e.name, zip.read(e)),
    ];
  }

  // ------------------------------------------------------- Dönüştürme

  static KeepResult parseAll(List<KeepSourceFile> files, {int unreadable = 0}) {
    var trashed = 0, empty = 0, attachments = 0, duplicates = 0;
    var bad = unreadable;
    final notes = <ImportNote>[];
    final seen = <String>{};

    final sorted = [...files]..sort((a, b) => a.name.compareTo(b.name));
    for (final f in sorted) {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(f.bytes, allowMalformed: true));
      } catch (_) {
        bad++;
        continue;
      }
      if (decoded is! Map<String, dynamic> || !looksLikeKeepNote(decoded)) {
        continue; // başka bir hizmetin dosyası
      }
      if (decoded['isTrashed'] == true) {
        trashed++;
        continue;
      }
      final note = noteFromJson(decoded);
      if (note == null) {
        empty++;
        continue;
      }
      if (!seen.add(note.id)) {
        duplicates++;
        continue;
      }
      final att = decoded['attachments'];
      if (att is List && att.isNotEmpty) attachments++;
      notes.add(note);
    }

    return KeepResult(
      batch: ImportBatch(
        folders: notes.isEmpty
            ? const []
            : const [ImportFolder(id: folderId, name: folderName)],
        notes: notes,
      ),
      skippedTrashed: trashed,
      skippedEmpty: empty,
      withAttachments: attachments,
      duplicates: duplicates,
      unreadable: bad,
    );
  }

  /// Keep notu imzası: Keep'e özgü zaman alanı ve içerik alanlarından biri.
  static bool looksLikeKeepNote(Map<String, dynamic> j) =>
      (j.containsKey('createdTimestampUsec') ||
          j.containsKey('userEditedTimestampUsec')) &&
      (j.containsKey('textContent') ||
          j.containsKey('listContent') ||
          j.containsKey('title'));

  /// Tek bir Keep notu. Başlığı ve metni yoksa null.
  static ImportNote? noteFromJson(Map<String, dynamic> j) {
    final title = (j['title'] as String? ?? '').trim();
    final list = j['listContent'];
    final isList = list is List && list.isNotEmpty;

    var body = isList
        ? [
            for (final item in list)
              if (item is Map)
                '- [${item['isChecked'] == true ? 'x' : ' '}] '
                    '${(item['text'] as String? ?? '').replaceAll('\n', ' ').trim()}',
          ].join('\n')
        : (j['textContent'] as String? ?? '').replaceAll('\r\n', '\n');

    // Nota eklenmiş bağlantılar gövdenin sonuna yazılır.
    final links = <String>[
      for (final a in (j['annotations'] as List? ?? const []))
        if (a is Map && a['url'] is String && (a['url'] as String).isNotEmpty)
          _link(a['title'] as String?, a['url'] as String),
    ];
    if (links.isNotEmpty) {
      body = body.trim().isEmpty
          ? links.join('\n')
          : '${body.trimRight()}\n\n${links.join('\n')}';
    }

    if (title.isEmpty && body.trim().isEmpty) return null;

    final created = _usecToMs(j['createdTimestampUsec']);
    final updated = _usecToMs(j['userEditedTimestampUsec']);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Kimlik: oluşturma zamanı + başlık (Keep'te kimlik yok). Zaman yoksa
    // içerikten üretilir.
    final idSource = created != null
        ? '${j['createdTimestampUsec']}\u0000$title'
        : '$title\u0000$body';

    return ImportNote(
      id: 'keep-${_hex(utf8.encode(idSource)).substring(0, 32)}',
      folderId: folderId,
      kind: NoteKind.snippet,
      type: isList ? NoteType.checklist : NoteType.text,
      title: title,
      body: body,
      color: colorMap[j['color']],
      pinned: j['isPinned'] == true,
      archived: j['isArchived'] == true,
      createdAt: created ?? updated ?? now,
      updatedAt: updated ?? created ?? now,
      tagNames: _labels(j['labels']),
    );
  }

  // -------------------------------------------------------- Yardımcılar

  static int? _usecToMs(Object? v) => v is num ? v ~/ 1000 : null;

  static String _link(String? title, String url) {
    final t = title?.trim() ?? '';
    return t.isEmpty
        ? url
        : '[${t.replaceAll('[', '\\[').replaceAll(']', '\\]')}]($url)';
  }

  static List<String> _labels(Object? v) {
    final out = <String>[];
    final seen = <String>{};
    for (final l in (v is List ? v : const [])) {
      final name = l is Map ? (l['name'] as String? ?? '').trim() : '';
      if (name.isNotEmpty && seen.add(name.toLowerCase())) out.add(name);
    }
    return out;
  }

  static String _hex(List<int> data) => const DartSha256()
      .hashSync(data)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Seçimde hiç Keep notu yoksa gösterilecek açıklama.
const keepNotFoundMessage =
    'Seçimde Google Keep notu bulunamadı. Google Takeout\'ta "Keep"i seçip '
    'dışa aktardığın .zip dosyasını ya da içindeki Keep klasöründeki .json '
    'dosyalarını seç.';

