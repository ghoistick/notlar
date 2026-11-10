import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/ui/editor/markdown_controller.dart';

/// Metin alanının yaptığını taklit eder: seçimin yerine [s] yazar.
void type(MarkdownEditingController c, String s) {
  final sel = c.selection;
  c.value = TextEditingValue(
    text: c.text.replaceRange(sel.start, sel.end, s),
    selection: TextSelection.collapsed(offset: sel.start + s.length),
  );
}

/// Backspace: seçim varsa onu, yoksa imleçten önceki karakteri siler.
void backspace(MarkdownEditingController c) {
  final sel = c.selection;
  final start = sel.isCollapsed ? sel.start - 1 : sel.start;
  c.value = TextEditingValue(
    text: c.text.replaceRange(start, sel.end, ''),
    selection: TextSelection.collapsed(offset: start),
  );
}

/// Delete: imleçten sonraki karakteri siler.
void deleteForward(MarkdownEditingController c) {
  final p = c.selection.start;
  c.value = TextEditingValue(
    text: c.text.replaceRange(p, p + 1, ''),
    selection: TextSelection.collapsed(offset: p),
  );
}

MarkdownEditingController at(String text, int caret) =>
    MarkdownEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: caret);

void main() {
  test('Alt+Shift+aşağı ile yazılan her satıra eklenir', () {
    final c = at('abc\ndef\nghi', 1);
    c.extendColumn(1, 0);
    c.extendColumn(1, 0);
    expect(c.hasColumnSelection, isTrue);
    expect(c.columnCaretOffsets(), [1, 5, 9]);

    type(c, 'X');
    expect(c.text, 'aXbc\ndXef\ngXhi');
    expect(c.hasColumnSelection, isTrue);
    expect(c.columnCaretOffsets(), [2, 7, 12]);
    expect(c.selection, const TextSelection.collapsed(offset: 12));

    type(c, 'Y');
    expect(c.text, 'aXYbc\ndXYef\ngXYhi');
  });

  test('Backspace ve Delete tüm satırlara uygulanır', () {
    final c = at('abc\ndef\nghi', 2);
    c.extendColumn(2, 0);
    backspace(c);
    expect(c.text, 'ac\ndf\ngi');
    deleteForward(c);
    expect(c.text, 'a\nd\ng');
    expect(c.hasColumnSelection, isTrue);
  });

  test('satır başında Backspace satırları birleştirmez', () {
    final c = at('ab\ncd\nef', 0);
    c.extendColumn(2, 0);
    backspace(c);
    expect(c.text, 'ab\ncd\nef');
    expect(c.hasColumnSelection, isTrue);
  });

  test('satır sonunda Delete satırları birleştirmez', () {
    final c = at('ab\ncd\nxy', 2);
    c.extendColumn(1, 0);
    deleteForward(c);
    expect(c.text, 'ab\ncd\nxy');
  });

  test('genişliği olan seçimde yazılan her satırdaki parçanın yerine geçer', () {
    final c = at('abcd\nefgh\nijkl', 1);
    c.extendColumn(2, 0);
    c.extendColumn(0, 2);
    expect(c.columnRanges(), const [
      TextRange(start: 1, end: 3),
      TextRange(start: 6, end: 8),
    ]); // etkin satırı metin alanının kendi seçimi gösterir
    type(c, '-');
    expect(c.text, 'a-d\ne-h\ni-l');
  });

  test('genişliği olan seçimde Backspace parçaları siler', () {
    final c = at('abcd\nefgh', 1);
    c.extendColumn(1, 2);
    backspace(c);
    expect(c.text, 'ad\neh');
    expect(c.hasColumnSelection, isTrue);
  });

  test('kısa satırlarda imleç satır sonuna kısılır', () {
    final c = at('abcd\na\nabcd', 3);
    c.extendColumn(2, 0);
    expect(c.columnCaretOffsets(), [3, 6, 10]);
    type(c, '-');
    expect(c.text, 'abc-d\na-\nabc-d');
  });

  test('yukarı doğru seçim de çalışır', () {
    final c = at('abc\ndef\nghi', 9);
    c.extendColumn(-2, 0);
    type(c, '>');
    expect(c.text, 'a>bc\nd>ef\ng>hi');
  });

  test('sütun genişliği en uzun satırla sınırlı', () {
    final c = at('ab\ncd', 0);
    c.extendColumn(1, 10);
    expect(c.columnRanges(), const [TextRange(start: 0, end: 2)]);
    c.extendColumn(0, -10);
    expect(c.columnRanges(), isEmpty);
  });

  test('Esc imleci etkin uçta bırakarak çıkar', () {
    final c = at('abc\ndef', 1);
    c.extendColumn(1, 0);
    c.exitColumnSelection();
    expect(c.hasColumnSelection, isFalse);
    expect(c.selection, const TextSelection.collapsed(offset: 5));
  });

  test('ok tuşu ya da tıklama (seçim değişikliği) çıkar', () {
    final c = at('abc\ndef', 1);
    c.extendColumn(1, 0);
    c.selection = const TextSelection.collapsed(offset: 0);
    expect(c.hasColumnSelection, isFalse);
  });

  test('Enter yalnızca etkin satıra uygulanır ve çıkar', () {
    final c = at('ab\ncd', 1);
    c.extendColumn(1, 0);
    type(c, '\n');
    expect(c.hasColumnSelection, isFalse);
    expect(c.text, 'ab\nc\nd');
  });

  test('odak kaybı sütun seçimini bitirir', () {
    final c = at('ab\ncd', 1);
    c.setFocused(true);
    c.extendColumn(1, 0);
    c.setFocused(false);
    expect(c.hasColumnSelection, isFalse);
  });

  test('tüm satırlar tek düzenlemede değişir', () {
    final c = at('ab\ncd\nef', 0);
    c.extendColumn(2, 0);
    var notifications = 0;
    c.addListener(() => notifications++);
    type(c, '- ');
    expect(c.text, '- ab\n- cd\n- ef');
    // Değer tek seferde yazılır (ara durum yok).
    expect(notifications, lessThanOrEqualTo(2));
  });
}
