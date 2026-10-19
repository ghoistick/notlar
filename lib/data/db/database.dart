import 'package:drift/drift.dart';

import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [
  Folders,
  Notes,
  Tags,
  NoteTags,
  NoteHeadings,
  Revisions,
  Attachments,
  SavedSearches,
  ViewSettings,
  ChangeLog,
  LocalMeta,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  /// Tam metin arama indeksi.
  ///
  /// Sütunlara Türkçe karakterleri sadeleştirilmiş metin yazılır
  /// (bkz. foldForSearch). Sorgu da aynı işlemden geçtiği için "sifre"
  /// araması "şifre" geçen notları bulur.
  static const createFtsSql = '''
    CREATE VIRTUAL TABLE notes_fts USING fts5(
      note_id UNINDEXED,
      title,
      body,
      tags,
      headings,
      tokenize = 'unicode61 remove_diacritics 2'
    )
  ''';

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(createFtsSql);
        },
      );
}
