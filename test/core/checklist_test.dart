import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/text/checklist.dart';

void main() {
  test('kutucuklu satırlar okunur', () {
    expect(Checklist.parse('- [ ] süt\n- [x] ekmek\n* [X] yumurta\n  - [ ]'), [
      const ChecklistEntry('süt'),
      const ChecklistEntry('ekmek', checked: true),
      const ChecklistEntry('yumurta', checked: true),
      const ChecklistEntry(''),
    ]);
  });

  test('düz satırlar işaretsiz madde olur, boş satırlar atlanır', () {
    expect(Checklist.parse('Alışveriş\n\n- elma\n2. armut\r\n  ayva  '), [
      const ChecklistEntry('Alışveriş'),
      const ChecklistEntry('elma'),
      const ChecklistEntry('armut'),
      const ChecklistEntry('ayva'),
    ]);
  });

  test('yazma ve geri okuma', () {
    const items = [
      ChecklistEntry('süt'),
      ChecklistEntry('ekmek', checked: true),
      ChecklistEntry(''),
    ];
    final body = Checklist.format(items);
    expect(body, '- [ ] süt\n- [x] ekmek\n- [ ]');
    expect(Checklist.parse(body), items);
  });

  test('metinden listeye', () {
    expect(Checklist.fromText('bir\n\n- [x] iki\nüç\n'),
        '- [ ] bir\n- [x] iki\n- [ ] üç');
    expect(Checklist.fromText(''), '');
  });

  test('ilerleme', () {
    final p = Checklist.progress('- [x] a\n- [ ] b\n- [x] c');
    expect(p.done, 2);
    expect(p.total, 3);
  });

  test('isItemLine', () {
    expect(Checklist.isItemLine('- [ ] a'), isTrue);
    expect(Checklist.isItemLine('- [ ]'), isTrue);
    expect(Checklist.isItemLine('- a'), isFalse);
    expect(Checklist.isItemLine('- [ ]a'), isFalse);
  });
}
