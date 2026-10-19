import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/ui/common/format.dart';
import 'package:notlar/ui/home/folder_tree.dart';

Folder _f(String id, String name, {String? parent, int pos = 0}) => Folder(
      id: id,
      parentId: parent,
      name: name,
      color: null,
      position: pos,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      hlc: 'h',
    );

void main() {
  group('notePreview', () {
    test('başlıkları, kod bloklarını ve işaretleri atlar', () {
      const body = '''
# Başlık
- **Önemli** madde
```
kod
```
[x] bitti {kırmızı}renkli{/}
''';
      expect(notePreview(body), 'Önemli madde bitti renkli');
    });

    test('uzun metni keser', () {
      final body = 'a' * 300;
      final p = notePreview(body, maxLength: 50);
      expect(p.length, 51);
      expect(p.endsWith('…'), isTrue);
    });
  });

  test('formatShortDate: bugün saat, bu yıl gün-ay, eski yıl tam tarih', () {
    final now = DateTime(2026, 10, 15, 18);
    expect(formatShortDate(DateTime(2026, 10, 15, 9, 5).millisecondsSinceEpoch,
        now: now), '09:05');
    expect(formatShortDate(DateTime(2026, 3, 2).millisecondsSinceEpoch, now: now),
        '2 Mar');
    expect(formatShortDate(DateTime(2025, 1, 7).millisecondsSinceEpoch, now: now),
        '07.01.2025');
  });

  group('klasör ağacı', () {
    final folders = [
      _f('b', 'Zeytin'),
      _f('a', 'Çalışma'),
      _f('a1', 'Alt', parent: 'a'),
      _f('o', 'Yetim', parent: 'silinmis'),
    ];

    test('kapalıyken yalnızca kökler, Türkçe sıralı; yetim köke düşer', () {
      final rows = flattenTree(buildFolderTree(folders));
      expect(rows.map((r) => r.folder.name), ['Çalışma', 'Yetim', 'Zeytin']);
      expect(rows.first.hasChildren, isTrue);
    });

    test('açık klasörün çocukları girintili gelir', () {
      final rows = flattenTree(buildFolderTree(folders), expanded: {'a'});
      expect(rows.map((r) => '${r.depth}:${r.folder.name}'),
          ['0:Çalışma', '1:Alt', '0:Yetim', '0:Zeytin']);
    });
  });
}
