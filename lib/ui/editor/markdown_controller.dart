import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/text/search_text.dart';
import '../common/note_colors.dart';
import 'markdown_parser.dart';

/// Editörün renkleri ve yazı tipleri; temadan türetilir.
class MarkdownTheme {
  final Brightness brightness;
  final Color accent;
  final Color muted;
  final Color codeBackground;
  final Color match;
  final Color currentMatch;

  static const monoFamily = 'IBM Plex Mono';
  static const monoFallback = [
    'Consolas',
    'Cascadia Mono',
    'Roboto Mono',
    'monospace',
  ];

  const MarkdownTheme({
    required this.brightness,
    required this.accent,
    required this.muted,
    required this.codeBackground,
    required this.match,
    required this.currentMatch,
  });

  factory MarkdownTheme.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final orange = noteColorFor('turuncu')!.swatch;
    return MarkdownTheme(
      brightness: theme.brightness,
      accent: scheme.primary,
      muted: scheme.onSurfaceVariant,
      codeBackground: scheme.onSurface.withValues(alpha: 0.06),
      match: orange.withValues(alpha: dark ? 0.28 : 0.22),
      currentMatch: orange.withValues(alpha: dark ? 0.70 : 0.55),
    );
  }

  static const _headingScale = [1.55, 1.3, 1.15, 1.05, 1.0, 1.0];

  /// Satırın genel biçimi (başlık boyutu, alıntı, kod bloğu...).
  TextStyle lineStyle(TextStyle base, BlockInfo block) {
    final size = base.fontSize ?? 16;
    switch (block.type) {
      case BlockType.heading:
        return base.copyWith(
          fontSize: size * _headingScale[block.level - 1],
          fontWeight: block.level <= 2 ? FontWeight.w700 : FontWeight.w600,
          height: 1.35,
        );
      case BlockType.quote:
        return base.copyWith(color: muted, fontStyle: FontStyle.italic);
      case BlockType.code:
      case BlockType.fence:
        return base.copyWith(
          fontFamily: monoFamily,
          fontFamilyFallback: monoFallback,
          fontSize: size * 0.92,
          backgroundColor: codeBackground,
          color: block.type == BlockType.fence ? muted : null,
        );
      case BlockType.rule:
        return base.copyWith(color: muted);
      case BlockType.task when block.checked:
        return base.copyWith(
            color: muted, decoration: TextDecoration.lineThrough);
      default:
        return base;
    }
  }

  /// Görünmez ve neredeyse yer kaplamayan metin: gizli işaretler ve
  /// katlanmış bölümler için.
  TextStyle hidden(TextStyle line) => line.copyWith(
        fontSize: 0.01,
        height: 1,
        color: Colors.transparent,
        backgroundColor: Colors.transparent,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      );

  TextStyle segmentStyle(TextStyle line, InlineStyle s, BlockInfo block) {
    var st = line;
    final listMarker =
        block.type == BlockType.bullet || block.type == BlockType.ordered;

    if (s.marker && !s.code) {
      st = st.copyWith(
        color: listMarker ? accent : muted,
        fontWeight: listMarker ? FontWeight.w600 : null,
        decoration: TextDecoration.none,
      );
    }
    if (s.checkbox) {
      st = st.copyWith(
        color: accent,
        fontWeight: FontWeight.w700,
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        decoration: TextDecoration.none,
      );
    }
    if (s.bold) st = st.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) st = st.copyWith(fontStyle: FontStyle.italic);
    if (s.strike) {
      st = st.copyWith(
        decoration: TextDecoration.combine([
          if (st.decoration != null) st.decoration!,
          TextDecoration.lineThrough,
        ]),
      );
    }
    if (s.code &&
        block.type != BlockType.code &&
        block.type != BlockType.fence) {
      st = st.copyWith(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: (st.fontSize ?? 16) * 0.92,
        backgroundColor: codeBackground,
      );
    }
    if (s.link) {
      st = st.copyWith(color: accent, decoration: TextDecoration.underline);
    }
    final color = noteColorFor(s.color);
    if (color != null) st = st.copyWith(color: color.swatch);
    final mark = noteColorFor(s.highlight);
    if (mark != null) {
      st = st.copyWith(
        backgroundColor: mark.swatch.withValues(
            alpha: brightness == Brightness.dark ? 0.38 : 0.28),
      );
    }
    return st;
  }
}

/// Not içindeki bir başlık: içindekiler paneli ve katlama için.
class HeadingRef {
  /// Metin düzenlendikçe satır numarası değişir; katlama durumu bu anahtarla
  /// tutulur: "seviye|başlık|kaçıncı tekrar".
  final String key;
  final int level;
  final String title;
  final int lineIndex;
  final int lineStart;
  final int lineEnd;

  /// Bölümün bittiği satır (dahil değil): aynı ya da üst seviyedeki
  /// sonraki başlık ya da belge sonu.
  final int sectionEnd;

  const HeadingRef({
    required this.key,
    required this.level,
    required this.title,
    required this.lineIndex,
    required this.lineStart,
    required this.lineEnd,
    required this.sectionEnd,
  });

  /// Altında en az bir satır varsa katlanabilir.
  bool get foldable => sectionEnd > lineIndex + 1;
}

enum ListKind { bullet, task, ordered }

/// Yazarken biçimlenen Markdown editörünün denetleyicisi.
///
/// Metin her zaman düz Markdown olarak kalır; biçim yalnızca görüntüdür.
/// İmlecin bulunduğu satır(lar)da işaretler soluk görünür, diğer satırlarda
/// gizlenir. Editör odakta değilse tüm işaretler gizlenir.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  MarkdownTheme? theme;
  bool _focused = false;

  final Set<String> _folded = {};
  List<TextRange> _matches = const [];
  int _currentMatch = -1;

  String? _cacheText;
  List<ParsedLine> _cacheLines = const [];

  /// Ayrıştırılmış satırlar; metin değişmedikçe yeniden hesaplanmaz.
  List<ParsedLine> get parsedLines {
    if (_cacheText != text) {
      _cacheLines = parseDocument(text);
      _cacheText = text;
    }
    return _cacheLines;
  }

  Set<String> get foldedKeys => Set.unmodifiable(_folded);

  void setFocused(bool focused) {
    if (_focused == focused) return;
    _focused = focused;
    notifyListeners();
  }

  /// Seçim katlanmış bir bölüme girerse (ok tuşu, arama, geri alma...)
  /// o bölüm otomatik açılır; görünmeyen metin düzenlenmez.
  @override
  set value(TextEditingValue newValue) {
    super.value = newValue;
    _revealSelection();
  }

  // ------------------------------------------------------------- Görüntü

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final t = theme ?? MarkdownTheme.of(context);
    final base = style ?? const TextStyle();
    final lines = parsedLines;
    final refs = _folded.isEmpty ? const <HeadingRef>[] : headingRefs();
    final hiddenLines = _hiddenOwners(refs);
    final foldedHeadings = {
      for (final r in refs)
        if (r.foldable && _folded.contains(r.key)) r.lineIndex,
    };
    final active = _focused ? _activeLines(lines) : null;

    final children = <InlineSpan>[];
    var mi = 0;

    // Arama eşleşmelerini parçalara bölerek vurgular.
    void emit(String s, int absStart, TextStyle st, {required bool plain}) {
      if (plain || _matches.isEmpty) {
        children.add(TextSpan(text: s, style: st));
        return;
      }
      final absEnd = absStart + s.length;
      while (mi < _matches.length && _matches[mi].end <= absStart) {
        mi++;
      }
      var pos = 0;
      for (var k = mi; k < _matches.length && _matches[k].start < absEnd; k++) {
        final m = _matches[k];
        final a = max(m.start, absStart) - absStart;
        final b = min(m.end, absEnd) - absStart;
        if (a > pos) children.add(TextSpan(text: s.substring(pos, a), style: st));
        children.add(TextSpan(
          text: s.substring(a, b),
          style: st.copyWith(
              backgroundColor: k == _currentMatch ? t.currentMatch : t.match),
        ));
        pos = b;
        if (m.end > absEnd) break;
      }
      if (pos < s.length) children.add(TextSpan(text: s.substring(pos), style: st));
    }

    for (var i = 0; i < lines.length; i++) {
      final pl = lines[i];
      final lineHidden = hiddenLines.containsKey(i);
      final isActive = active != null && i >= active.$1 && i <= active.$2;
      var lineStyle = t.lineStyle(base, pl.block);
      if (foldedHeadings.contains(i)) {
        lineStyle = lineStyle.copyWith(
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: t.muted,
        );
      }

      for (final seg in pl.segments) {
        final hide = lineHidden || (!isActive && seg.style.hideable);
        emit(
          pl.text.substring(seg.start, seg.end),
          pl.offset + seg.start,
          hide ? t.hidden(lineStyle) : t.segmentStyle(lineStyle, seg.style, pl.block),
          plain: hide,
        );
      }
      if (i < lines.length - 1) {
        children.add(TextSpan(
            text: '\n', style: lineHidden ? t.hidden(lineStyle) : lineStyle));
      }
    }
    return TextSpan(style: base, children: children);
  }

  (int, int)? _activeLines(List<ParsedLine> lines) {
    final sel = selection;
    if (!sel.isValid) return null;
    return (_lineIndexOf(lines, sel.start), _lineIndexOf(lines, sel.end));
  }

  static int _lineIndexOf(List<ParsedLine> lines, int offset) {
    var lo = 0;
    var hi = lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lines[mid].offset <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// İmlecin bulunduğu satır.
  int? get caretLine =>
      selection.isValid ? _lineIndexOf(parsedLines, selection.extentOffset) : null;

  // -------------------------------------------------- Başlıklar ve katlama

  List<HeadingRef> headingRefs() {
    final lines = parsedLines;
    final idx = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].block.type == BlockType.heading) i,
    ];
    final counts = <String, int>{};
    final out = <HeadingRef>[];

    for (var k = 0; k < idx.length; k++) {
      final i = idx[k];
      final pl = lines[i];
      final level = pl.block.level;
      final markerEnd = pl.segments.isEmpty ? 0 : pl.segments.first.end;
      final title = stripInlineMarkup(pl.text.substring(markerEnd)).trim();
      final base = '$level|$title';
      final n = counts[base] = (counts[base] ?? 0) + 1;

      var end = lines.length;
      for (var j = k + 1; j < idx.length; j++) {
        if (lines[idx[j]].block.level <= level) {
          end = idx[j];
          break;
        }
      }

      out.add(HeadingRef(
        key: '$base|$n',
        level: level,
        title: title,
        lineIndex: i,
        lineStart: pl.offset,
        lineEnd: pl.offset + pl.text.length,
        sectionEnd: end,
      ));
    }
    return out;
  }

  /// Katlanmış bölümlerin satırları ve onları gizleyen başlıklar
  /// (dıştan içe sıralı).
  Map<int, List<String>> _hiddenOwners(List<HeadingRef> refs) {
    final owners = <int, List<String>>{};
    for (final r in refs) {
      if (!r.foldable || !_folded.contains(r.key)) continue;
      for (var l = r.lineIndex + 1; l < r.sectionEnd; l++) {
        owners.putIfAbsent(l, () => []).add(r.key);
      }
    }
    return owners;
  }

  /// Test ve hata ayıklama için: şu an gizli olan satırlar.
  Set<int> hiddenLineIndices() => _hiddenOwners(headingRefs()).keys.toSet();

  bool isFolded(String key) => _folded.contains(key);

  void toggleFold(String key) {
    if (_folded.remove(key)) {
      notifyListeners();
      return;
    }
    final ref = headingRefs().where((r) => r.key == key).firstOrNull;
    if (ref == null || !ref.foldable) return;
    _moveCaretOutOf([ref]);
    _folded.add(key);
    notifyListeners();
  }

  /// Ctrl+.: imlecin içinde bulunduğu en içteki bölümü katlar/açar.
  void toggleFoldAtCaret() {
    final line = caretLine;
    if (line == null) return;
    HeadingRef? inner;
    for (final r in headingRefs()) {
      if (r.lineIndex <= line && line < r.sectionEnd) inner = r;
    }
    if (inner != null) toggleFold(inner.key);
  }

  void foldAll() {
    final refs = headingRefs().where((r) => r.foldable).toList();
    if (refs.isEmpty) return;
    _moveCaretOutOf(refs);
    _folded.addAll(refs.map((r) => r.key));
    notifyListeners();
  }

  void unfoldAll() {
    if (_folded.isEmpty) return;
    _folded.clear();
    notifyListeners();
  }

  /// Katlanacak bölümdeyse imleci o bölümün başlık satırının sonuna taşır.
  void _moveCaretOutOf(List<HeadingRef> refs) {
    final line = caretLine;
    if (line == null) return;
    for (final r in refs) {
      if (line > r.lineIndex && line < r.sectionEnd) {
        super.value = value.copyWith(
          selection: TextSelection.collapsed(offset: r.lineEnd),
          composing: TextRange.empty,
        );
        return;
      }
    }
  }

  void _revealSelection() {
    if (_folded.isEmpty || !selection.isValid) return;
    final owners = _hiddenOwners(headingRefs());
    if (owners.isEmpty) return;
    final lines = parsedLines;
    final a = _lineIndexOf(lines, selection.start);
    final b = _lineIndexOf(lines, selection.end);
    var changed = false;
    for (var l = a; l <= b; l++) {
      for (final key in owners[l] ?? const <String>[]) {
        changed |= _folded.remove(key);
      }
    }
    if (changed) notifyListeners();
  }

  // ------------------------------------------------------------ Not içi arama

  void setSearchMatches(List<TextRange> matches, int current) {
    _matches = matches;
    _currentMatch = current;
    notifyListeners();
  }

  /// Türkçe karakter ve büyük/küçük harf farkı gözetmeden tüm eşleşmeler.
  static List<TextRange> findAll(String text, String query) {
    if (query.isEmpty) return const [];
    final haystack = foldSameLength(text);
    final needle = foldSameLength(query);
    final out = <TextRange>[];
    var i = haystack.indexOf(needle);
    while (i >= 0) {
      out.add(TextRange(start: i, end: i + needle.length));
      i = haystack.indexOf(needle, i + needle.length);
    }
    return out;
  }

  // ------------------------------------------------------------- Düzenleme

  /// Seçimi işaretlerle sarar; zaten sarılıysa işaretleri kaldırır.
  void wrapSelection(String left, [String? right]) {
    final r = right ?? left;
    final sel = selection;
    if (!sel.isValid) return;
    final t = text;
    final s = sel.start;
    final e = sel.end;

    final before = s - left.length;
    final after = e + r.length;
    if (before >= 0 &&
        after <= t.length &&
        t.substring(before, s) == left &&
        t.substring(e, after) == r) {
      value = TextEditingValue(
        text: t.replaceRange(e, after, '').replaceRange(before, s, ''),
        selection: TextSelection(
            baseOffset: before, extentOffset: e - left.length),
      );
      return;
    }

    value = TextEditingValue(
      text: t.replaceRange(s, e, '$left${t.substring(s, e)}$r'),
      selection: sel.isCollapsed
          ? TextSelection.collapsed(offset: s + left.length)
          : TextSelection(
              baseOffset: s + left.length, extentOffset: e + left.length),
    );
  }

  /// Seçili metne yazı rengi ya da vurgu rengi uygular.
  void applyColor(String key, {bool highlight = false}) {
    final name = colorSyntaxName(key);
    wrapSelection('{${highlight ? '!' : ''}$name}', '{/}');
  }

  static final _anyHeading = RegExp(r'^#{1,6}\s+');

  /// Seçili satırları verilen seviyede başlık yapar; aynı seviyedeyse ya da
  /// [level] 0 ise düz metne çevirir.
  void toggleHeading(int level) {
    _editLines((line, multi) {
      final m = _anyHeading.firstMatch(line);
      final current = m == null ? 0 : m.group(0)!.trim().length;
      final body = m == null ? line : line.substring(m.end);
      if (level == 0 || current == level) return body;
      return '${'#' * level} $body';
    });
  }

  static final _listPrefix =
      RegExp(r'^(\s*)(?:[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)');

  /// Seçili satırları liste yapar; zaten o türdeyse listeden çıkarır.
  void toggleList(ListKind kind) {
    var n = 0;
    _editLines((line, multi) {
      if (multi && line.trim().isEmpty) return line;
      final m = _listPrefix.firstMatch(line);
      final indent = m?.group(1) ?? RegExp(r'^\s*').firstMatch(line)!.group(0)!;
      final body =
          m == null ? line.substring(indent.length) : line.substring(m.end);

      ListKind? current;
      if (m != null) {
        final p = m.group(0)!;
        current = p.contains('[')
            ? ListKind.task
            : RegExp(r'\d').hasMatch(p)
                ? ListKind.ordered
                : ListKind.bullet;
      }
      if (current == kind) return '$indent$body';

      n++;
      return switch (kind) {
        ListKind.bullet => '$indent- $body',
        ListKind.task => '$indent- [ ] $body',
        ListKind.ordered => '$indent$n. $body',
      };
    });
  }

  /// [offset] bir yapılacak kutucuğunun üzerindeyse işaretini değiştirir.
  bool toggleCheckboxAt(int offset) {
    final t = text;
    final (ls, le) = _lineBounds(t, offset);
    final m = taskLinePattern.firstMatch(t.substring(ls, le));
    if (m == null) return false;

    final boxStart = ls + m.group(1)!.length;
    if (offset < boxStart || offset > boxStart + 3) return false;

    _flipBox(t, boxStart, caret: le);
    return true;
  }

  /// Ctrl+Enter: satır yapılacak maddesiyse işaretini değiştirir, değilse
  /// satırı yapılacak maddesine çevirir.
  void toggleCheckboxOnCurrentLine() {
    final sel = selection;
    if (!sel.isValid) return;
    final t = text;
    final (ls, le) = _lineBounds(t, sel.start);
    final m = taskLinePattern.firstMatch(t.substring(ls, le));
    if (m == null) {
      toggleList(ListKind.task);
      return;
    }
    _flipBox(t, ls + m.group(1)!.length, caret: sel.baseOffset);
  }

  void _flipBox(String t, int boxStart, {required int caret}) {
    final checked = t[boxStart + 1].toLowerCase() == 'x';
    value = TextEditingValue(
      text: t.replaceRange(boxStart + 1, boxStart + 2, checked ? ' ' : 'x'),
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  void _editLines(String Function(String line, bool multi) transform) {
    final sel = selection;
    if (!sel.isValid) return;
    final t = text;
    final first = sel.start == 0 ? 0 : t.lastIndexOf('\n', sel.start - 1) + 1;
    var last = t.indexOf('\n', sel.end);
    if (last < 0) last = t.length;

    final lines = t.substring(first, last).split('\n');
    final multi = lines.length > 1;
    final newBlock = lines.map((l) => transform(l, multi)).join('\n');

    final TextSelection newSel;
    if (!multi && sel.isCollapsed) {
      final fromEnd = last - sel.start;
      final caret = (first + newBlock.length - fromEnd)
          .clamp(first, first + newBlock.length);
      newSel = TextSelection.collapsed(offset: caret);
    } else {
      newSel = TextSelection(
          baseOffset: first, extentOffset: first + newBlock.length);
    }
    value = TextEditingValue(
      text: t.replaceRange(first, last, newBlock),
      selection: newSel,
    );
  }

  static (int, int) _lineBounds(String t, int offset) {
    final start = offset <= 0 ? 0 : t.lastIndexOf('\n', offset - 1) + 1;
    var end = t.indexOf('\n', offset.clamp(0, t.length));
    if (end < 0) end = t.length;
    return (start, end);
  }
}

/// Enter'a basınca listeyi sürdürür: "- ", "- [ ] ", "2. " otomatik eklenir.
/// Boş bir maddede Enter'a basılırsa liste sona erer.
class ListContinuationFormatter extends TextInputFormatter {
  static final _item =
      RegExp(r'^(\s*)(?:([-*+])(\s+)\[[ xX]\]\s+|([-*+])\s+|(\d+)([.)])\s+)');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final sel = newValue.selection;
    if (!sel.isValid || !sel.isCollapsed) return newValue;
    if (newValue.text.length != oldValue.text.length + 1) return newValue;

    final caret = sel.baseOffset;
    if (caret <= 0 || newValue.text[caret - 1] != '\n') return newValue;
    final t = newValue.text;
    if (oldValue.text != t.substring(0, caret - 1) + t.substring(caret)) {
      return newValue;
    }

    final prevStart = caret - 1 == 0 ? 0 : t.lastIndexOf('\n', caret - 2) + 1;
    final prevLine = t.substring(prevStart, caret - 1);
    final m = _item.firstMatch(prevLine);
    if (m == null) return newValue;

    if (prevLine.substring(m.end).trim().isEmpty) {
      return TextEditingValue(
        text: t.substring(0, prevStart) + t.substring(caret),
        selection: TextSelection.collapsed(offset: prevStart),
      );
    }

    final indent = m.group(1)!;
    final String marker;
    if (m.group(2) != null) {
      marker = '$indent${m.group(2)} [ ] ';
    } else if (m.group(4) != null) {
      marker = '$indent${m.group(4)} ';
    } else {
      marker = '$indent${int.parse(m.group(5)!) + 1}${m.group(6)} ';
    }

    return TextEditingValue(
      text: t.substring(0, caret) + marker + t.substring(caret),
      selection: TextSelection.collapsed(offset: caret + marker.length),
    );
  }
}
