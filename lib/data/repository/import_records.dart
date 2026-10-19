import '../db/tables.dart';

/// Dışarıdan alınan veri (yedekten geri yükleme ya da başka uygulamalardan
/// içe aktarma) bu ortak biçime çevrilir, sonra tek yoldan veritabanına yazılır.

class ImportFolder {
  final String id;
  final String name;
  final String? parentId;
  final String? color;
  final int position;

  const ImportFolder({
    required this.id,
    required this.name,
    this.parentId,
    this.color,
    this.position = 0,
  });
}

class ImportTag {
  final String id;
  final String name;
  final String? color;

  const ImportTag({required this.id, required this.name, this.color});
}

class ImportNote {
  final String id;
  final String? folderId;
  final NoteKind kind;
  final NoteType type;
  final String title;
  final String body;
  final String? color;
  final bool pinned;
  final bool archived;
  final int createdAt;
  final int updatedAt;

  /// Etiketler ada göre eşleştirilir; yoksa oluşturulur.
  final List<String> tagNames;

  const ImportNote({
    required this.id,
    this.folderId,
    this.kind = NoteKind.note,
    this.type = NoteType.text,
    this.title = '',
    this.body = '',
    this.color,
    this.pinned = false,
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
    this.tagNames = const [],
  });
}

class ImportBatch {
  final List<ImportFolder> folders;
  final List<ImportTag> tags;
  final List<ImportNote> notes;

  const ImportBatch({
    this.folders = const [],
    this.tags = const [],
    this.notes = const [],
  });
}

/// Ne eklendi, ne atlandı. Önizlemede (dryRun) "eklenecek" anlamına gelir.
class ImportResult {
  int foldersAdded = 0;
  int tagsAdded = 0;
  int notesAdded = 0;

  /// Kimliği zaten bulunan notlar: üzerine yazılmaz.
  int notesSkipped = 0;

  bool get isEmpty => foldersAdded == 0 && tagsAdded == 0 && notesAdded == 0;
}
