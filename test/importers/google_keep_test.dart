import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/data/db/tables.dart';
import 'package:notlar/importers/google_keep.dart';

KeepSourceFile json(String name, Map<String, Object?> j) =>
    KeepSourceFile(name, Uint8List.fromList(utf8.encode(jsonEncode(j))));

/// Takeout'tan alınan örnek (textContentHtml kısaltıldı).
const sample = <String, Object?>{
  'color': 'DEFAULT',
  'isTrashed': false,
  'isPinned': false,
  'isArchived': false,
  'textContent': 'Rehearsal\n\nhouse of cards\nsons of anarchy',
  'title': 'diziler',
  'userEditedTimestampUsec': 1688808392936000,
  'createdTimestampUsec': 1667381610698000,
  'textContentHtml': '<p>…</p>',
  'labels': [
    {'name': 'Kişisel'},
  ],
};

void main() {
  test('örnek not kısa not olarak alınır', () {
    final n = GoogleKeepImporter.noteFromJson(sample)!;
    expect(n.id, startsWith('keep-'));
    expect(n.folderId, GoogleKeepImporter.folderId);
    expect(n.kind, NoteKind.snippet);
    expect(n.type, NoteType.text);
    expect(n.title, 'diziler');
    expect(n.body, 'Rehearsal\n\nhouse of cards\nsons of anarchy');
    expect(n.tagNames, ['Kişisel']);
    expect(n.color, isNull);
    expect(n.createdAt, 1667381610698);
    expect(n.updatedAt, 1688808392936);
  });

  test('kimlik düzenlemeden etkilenmez', () {
    final a = GoogleKeepImporter.noteFromJson(sample)!;
    final edited = {
      ...sample,
      'textContent': 'değişti',
      'userEditedTimestampUsec': 1700000000000000,
    };
    expect(GoogleKeepImporter.noteFromJson(edited)!.id, a.id);
  });

  test('liste notu checklist olur', () {
    final n = GoogleKeepImporter.noteFromJson({
      'title': 'Alışveriş',
      'createdTimestampUsec': 1,
      'listContent': [
        {'text': 'süt', 'isChecked': false},
        {'text': 'ek\nmek', 'isChecked': true},
      ],
    })!;
    expect(n.type, NoteType.checklist);
    expect(n.body, '- [ ] süt\n- [x] ek mek');
  });

  test('renk, sabitleme, arşiv ve bağlantılar', () {
    final n = GoogleKeepImporter.noteFromJson({
      'title': 'T',
      'textContent': 'metin\n',
      'createdTimestampUsec': 1,
      'color': 'CERULEAN',
      'isPinned': true,
      'isArchived': true,
      'annotations': [
        {'title': 'Örnek [site]', 'url': 'https://ornek.com'},
        {'title': '', 'url': 'https://iki.com'},
      ],
    })!;
    expect(n.color, 'mavi');
    expect(n.pinned, isTrue);
    expect(n.archived, isTrue);
    expect(n.body,
        'metin\n\n[Örnek \\[site\\]](https://ornek.com)\nhttps://iki.com');
  });

  test('başlığı ve metni olmayan not null döner', () {
    expect(
        GoogleKeepImporter.noteFromJson({
          'title': '',
          'textContent': '',
          'createdTimestampUsec': 1,
          'attachments': [
            {'filePath': 'resim.jpg', 'mimetype': 'image/jpeg'},
          ],
        }),
        isNull);
  });

  test('paket: çöp, boş, ek, kopya ve Keep dışı dosyalar', () {
    final r = GoogleKeepImporter.parseAll([
      json('Takeout/Keep/diziler.json', sample),
      json('Takeout/Keep/kopya/diziler.json', sample),
      json('Takeout/Keep/cop.json',
          {...sample, 'title': 'çöp', 'isTrashed': true}),
      json('Takeout/Keep/bos.json',
          {'title': '', 'textContent': '', 'createdTimestampUsec': 2}),
      json('Takeout/Keep/ekli.json', {
        'title': 'Ekli',
        'textContent': 'x',
        'createdTimestampUsec': 3,
        'attachments': [
          {'filePath': 'a.png'},
        ],
      }),
      json('Takeout/Takvim/ayarlar.json', {'timezone': 'Europe/Istanbul'}),
      KeepSourceFile('Takeout/Keep/bozuk.json',
          Uint8List.fromList(utf8.encode('{bozuk'))),
    ]);

    expect(r.batch.notes.map((n) => n.title).toSet(), {'diziler', 'Ekli'});
    expect(r.batch.folders.single.id, GoogleKeepImporter.folderId);
    expect(r.skippedTrashed, 1);
    expect(r.skippedEmpty, 1);
    expect(r.withAttachments, 1);
    expect(r.duplicates, 1);
    expect(r.unreadable, 1);
  });

  test('hiç Keep notu yoksa klasör de eklenmez', () {
    final r = GoogleKeepImporter.parseAll([
      json('a.json', {'baska': 'hizmet'}),
    ]);
    expect(r.batch.notes, isEmpty);
    expect(r.batch.folders, isEmpty);
  });
}
