import '../db/tables.dart';

/// Hangi notların listeleneceği.
enum NoteScope { active, archived, trash }

/// Sıralama ölçütü. Sabitlenmiş notlar her zaman en üstte kalır (çöp kutusu hariç).
enum NoteSort {
  updatedAt,
  createdAt,
  title, // Türk alfabesine göre
  size,
  color,
  tag, // notun alfabetik olarak ilk etiketine göre
  relevance, // arama varken en iyi eşleşme önce
}

/// Tarih filtresinin hangi alana uygulanacağı.
enum DateField { createdAt, updatedAt }

/// Not listesi sorgusu. Tüm filtreler birlikte uygulanır (VE).
class NoteQuery {
  /// Kullanıcının yazdığı arama metni; Türkçe karakterden bağımsız önek araması.
  final String? search;

  /// Belirli bir klasör. [includeSubfolders] true ise alt klasörler de dahil.
  final String? folderId;
  final bool includeSubfolders;

  /// Yalnızca hiçbir klasörde olmayan notlar.
  final bool rootOnly;

  final String? tagId;
  final NoteKind? kind;
  final String? color;
  final NoteScope scope;

  final DateField dateField;

  /// Milisaniye cinsinden (dahil).
  final int? from;
  final int? to;

  final NoteSort sort;
  final bool descending;

  const NoteQuery({
    this.search,
    this.folderId,
    this.includeSubfolders = true,
    this.rootOnly = false,
    this.tagId,
    this.kind,
    this.color,
    this.scope = NoteScope.active,
    this.dateField = DateField.updatedAt,
    this.from,
    this.to,
    this.sort = NoteSort.updatedAt,
    this.descending = true,
  });
}
