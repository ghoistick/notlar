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

  /// Sütun seçiminin vurgu rengi (metin seçimiyle aynı).
  final Color selection;

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
    this.selection = const Color(0x553D7BFD),
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
      selection: theme.textSelectionTheme.selectionColor ??
          scheme.primary.withValues(alpha: 0.4),
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

/// Sütun (dikdörtgen) seçimi: çapa ve etkin uç, satır/sütun cinsinden.
/// Sütun, satır içindeki karakter sırasıdır; kısa satırlarda satır sonuna
/// kısılır.
class _ColumnState {
  final int anchorLine;
  final int anchorCol;
  final int activeLine;
  final int activeCol;

  const _ColumnState(
      this.anchorLine, this.anchorCol, this.activeLine, this.activeCol);

  int get firstLine => min(anchorLine, activeLine);
  int get lastLine => max(anchorLine, activeLine);
  int get minCol => min(anchorCol, activeCol);
  int get maxCol => max(anchorCol, activeCol);
}

enum _ColumnOp { replace, deleteBefore, deleteAfter }

/// Not içi arama seçenekleri (Aa, ab, .*).
class FindOptions {
  /// Büyük/küçük harf ve Türkçe karakter duyarlı.
  final bool matchCase;

  /// Yalnızca tam kelimeler.
  final bool wholeWord;

  /// Düzenli ifade.
  final bool regex;

  const FindOptions({
    this.matchCase = false,
    this.wholeWord = false,
    this.regex = false,
  });
}

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

  _ColumnState? _column;

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
    if (!focused) _column = null; // odak giderse sütun seçimi biter
    notifyListeners();
  }

  /// Seçim katlanmış bir bölüme girerse (ok tuşu, arama, geri alma...)
  /// o bölüm otomatik açılır; görünmeyen metin düzenlenmez.
  ///
  /// Sütun seçimi açıkken etkin satırdaki yazma, Backspace ve Delete tüm
  /// satırlara uygulanır; başka her değişiklik (ok tuşu, tıklama, Enter,
  /// geri alma...) sütun seçimini bitirir ve olduğu gibi uygulanır.
  @override
  set value(TextEditingValue newValue) {
    if (_column != null) {
      if (_applyColumnEdit(newValue)) return;
      if (newValue.text != text || newValue.selection != selection) {
        _column = null;
      }
    }
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

    // Sütun seçimi açıkken arama vurguları yerine seçili parçalar gösterilir.
    final column = _column;
    final marks = column != null ? columnRanges() : _matches;

    final children = <InlineSpan>[];
    var mi = 0;

    // Arama eşleşmelerini parçalara bölerek vurgular.
    void emit(String s, int absStart, TextStyle st, {required bool plain}) {
      if (plain || marks.isEmpty) {
        children.add(TextSpan(text: s, style: st));
        return;
      }
      final absEnd = absStart + s.length;
      while (mi < marks.length && marks[mi].end <= absStart) {
        mi++;
      }
      var pos = 0;
      for (var k = mi; k < marks.length && marks[k].start < absEnd; k++) {
        final m = marks[k];
        final a = max(m.start, absStart) - absStart;
        final b = min(m.end, absEnd) - absStart;
        if (a > pos) children.add(TextSpan(text: s.substring(pos, a), style: st));
        children.add(TextSpan(
          text: s.substring(a, b),
          style: st.copyWith(
              backgroundColor: column != null
                  ? t.selection
                  : (k == _currentMatch ? t.currentMatch : t.match)),
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
    // Sütun seçiminde tüm satırlar etkindir: işaretler görünür, böylece
    // sütunlar gerçek karakter konumlarıyla örtüşür.
    final c = _column;
    if (c != null) return (c.firstLine, c.lastLine);
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
    final lines = parsedLines;
    _revealLines(
        _lineIndexOf(lines, selection.start), _lineIndexOf(lines, selection.end));
  }

  /// [a]..[b] satırlarını gizleyen katlamaları açar.
  void _revealLines(int a, int b) {
    if (_folded.isEmpty) return;
    final owners = _hiddenOwners(headingRefs());
    if (owners.isEmpty) return;
    var changed = false;
    for (var l = a; l <= b; l++) {
      for (final key in owners[l] ?? const <String>[]) {
        changed |= _folded.remove(key);
      }
    }
    if (changed) notifyListeners();
  }

  // ----------------------------------------------------------- Sütun seçimi

  bool get hasColumnSelection => _column != null;

  /// Alt+Shift+ok: sütun seçimini başlatır ya da etkin ucunu taşır.
  /// [lines] satır, [cols] sütun kadar ilerler (negatif: yukarı/sola).
  void extendColumn(int lines, int cols) {
    final sel = selection;
    if (!sel.isValid) return;
    final parsed = parsedLines;
    var c = _column;
    if (c == null) {
      final bl = _lineIndexOf(parsed, sel.baseOffset);
      final el = _lineIndexOf(parsed, sel.extentOffset);
      c = _ColumnState(bl, sel.baseOffset - parsed[bl].offset, el,
          sel.extentOffset - parsed[el].offset);
    }

    final line = (c.activeLine + lines).clamp(0, parsed.length - 1);
    var col = c.activeCol;
    if (cols != 0) {
      var widest = 0;
      for (var l = min(c.anchorLine, line); l <= max(c.anchorLine, line); l++) {
        widest = max(widest, parsed[l].text.length);
      }
      col = (col + cols).clamp(0, widest);
    }

    _column = _ColumnState(c.anchorLine, c.anchorCol, line, col);
    _revealLines(min(c.anchorLine, line), max(c.anchorLine, line));
    _syncColumnSelection();
  }

  /// Sütun seçimini bitirir. [collapse] ise imleç etkin uçta kalır.
  void exitColumnSelection({bool collapse = true}) {
    if (_column == null) return;
    _column = null;
    if (collapse && selection.isValid) {
      super.value = value.copyWith(
        selection: TextSelection.collapsed(offset: selection.extentOffset),
        composing: TextRange.empty,
      );
    }
    notifyListeners();
  }

  /// Etkin satır dışındaki seçili parçalar (etkin satırı metin alanının
  /// kendi seçimi gösterir). Boş parçalar dahil edilmez.
  List<TextRange> columnRanges() {
    final c = _column;
    if (c == null) return const [];
    final lines = parsedLines;
    return [
      for (var l = c.firstLine; l <= c.lastLine; l++)
        if (l != c.activeLine)
          if (_columnSegment(lines[l], c) case final r when !r.isCollapsed) r,
    ];
  }

  /// Her satırdaki imleç konumu (etkin sütun, satır sonuna kısılmış).
  List<int> columnCaretOffsets() {
    final c = _column;
    if (c == null) return const [];
    final lines = parsedLines;
    return [
      for (var l = c.firstLine; l <= c.lastLine; l++)
        lines[l].offset + min(c.activeCol, lines[l].text.length),
    ];
  }

  static TextRange _columnSegment(ParsedLine pl, _ColumnState c) {
    final len = pl.text.length;
    return TextRange(
        start: pl.offset + min(c.minCol, len),
        end: pl.offset + min(c.maxCol, len));
  }

  /// Metin alanının seçimini etkin satırdaki parçaya eşitler.
  void _syncColumnSelection() {
    final c = _column!;
    final pl = parsedLines[c.activeLine];
    final len = pl.text.length;
    super.value = value.copyWith(
      selection: TextSelection(
        baseOffset: pl.offset + min(c.anchorCol, len),
        extentOffset: pl.offset + min(c.activeCol, len),
      ),
      composing: TextRange.empty,
    );
    notifyListeners();
  }

  /// Metin alanından gelen değişiklik etkin satırdaki seçimde yapılmış bir
  /// yazma / silme ise tüm satırlara uygular ve true döner.
  bool _applyColumnEdit(TextEditingValue nv) {
    final c = _column!;
    final old = text;
    final nt = nv.text;
    final sel = selection;
    final ns = nv.selection;
    if (nt == old || !sel.isValid || !ns.isValid || !ns.isCollapsed) {
      return false;
    }
    final ps = sel.start;
    final pe = sel.end;
    final caret = ns.baseOffset;

    _ColumnOp? op;
    var insert = '';
    var count = 0;
    final xlen = nt.length - old.length + (pe - ps);
    if (xlen >= 0 &&
        (xlen > 0 || pe > ps) &&
        caret == ps + xlen &&
        nt.startsWith(old.substring(0, ps)) &&
        nt.substring(ps + xlen) == old.substring(pe)) {
      insert = nt.substring(ps, ps + xlen);
      // Enter ya da çok satırlı yapıştırma: sütun seçimi biter.
      if (insert.contains('\n') || insert.contains('\r')) return false;
      op = _ColumnOp.replace;
    } else if (ps == pe && nt.length < old.length) {
      count = old.length - nt.length;
      if (caret == ps - count &&
          nt == old.substring(0, ps - count) + old.substring(ps)) {
        op = _ColumnOp.deleteBefore;
      } else if (caret == ps &&
          ps + count <= old.length &&
          nt == old.substring(0, ps) + old.substring(ps + count)) {
        op = _ColumnOp.deleteAfter;
      }
    }
    if (op == null) return false;

    // Etkin satır kısa olduğu için genişliği görünmeyen bir seçimde
    // Backspace/Delete, her satırdaki seçili parçayı siler.
    if (op != _ColumnOp.replace && c.minCol != c.maxCol) {
      op = _ColumnOp.replace;
      insert = '';
    }

    final lines = parsedLines;
    final ranges = <TextRange>[];
    for (var l = c.firstLine; l <= c.lastLine; l++) {
      final pl = lines[l];
      final ls = pl.offset;
      final le = ls + pl.text.length;
       final cc = ls + min<int>(c.activeCol, pl.text.length);
      ranges.add(switch (op) {
        _ColumnOp.replace => _columnSegment(pl, c),
        // Satır başında/sonunda durur: satırlar birleşmez.
        _ColumnOp.deleteBefore => TextRange(start: max(ls, cc - count), end: cc),
        _ColumnOp.deleteAfter => TextRange(start: cc, end: min(le, cc + count)),
      });
    }

    final newCol = switch (op) {
      _ColumnOp.replace => c.minCol + insert.length,
      _ColumnOp.deleteBefore => max(0, c.activeCol - count),
      _ColumnOp.deleteAfter => c.activeCol,
    };

    final b = StringBuffer();
    var last = 0;
    var shift = 0;
    var newCaret = 0;
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      b
        ..write(old.substring(last, r.start))
        ..write(insert);
      last = r.end;
      final delta = insert.length - (r.end - r.start);
      final l = c.firstLine + i;
      if (l == c.activeLine) {
        final pl = lines[l];
        newCaret = pl.offset + shift + min(newCol, pl.text.length + delta);
      }
      shift += delta;
    }
    b.write(old.substring(last));

    _column = _ColumnState(c.anchorLine, newCol, c.activeLine, newCol);
    super.value = TextEditingValue(
      text: b.toString(),
      selection: TextSelection.collapsed(offset: newCaret),
    );
    // Değer değişmemiş olsa da (ör. satır başında Backspace) metin alanı
    // platformdaki durumu yeniden eşitlesin.
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------------ Not içi arama

  void setSearchMatches(List<TextRange> matches, int current) {
    _matches = matches;
    _currentMatch = current;
    notifyListeners();
  }

  /// Tüm eşleşmeler. Seçenek verilmezse Türkçe karakter ve büyük/küçük harf
  /// farkı gözetilmez. Düzenli ifade geçersizse [FormatException] fırlatır.
  static List<TextRange> findAll(String text, String query,
      [FindOptions options = const FindOptions()]) {
    if (query.isEmpty) return const [];
    final out = <TextRange>[];

    if (options.regex) {
      for (final m in _regExpFor(query, options).allMatches(text)) {
        if (m.end == m.start) continue; // boş eşleşmeler (ör. ^ ya da a*) atlanır
        if (options.wholeWord && !_isWholeWord(text, m.start, m.end)) continue;
        out.add(TextRange(start: m.start, end: m.end));
      }
      return out;
    }

    // foldSameLength uzunluğu korur; konumlar özgün metinle aynıdır.
    final haystack = options.matchCase ? text : foldSameLength(text);
    final needle = options.matchCase ? query : foldSameLength(query);
    var i = haystack.indexOf(needle);
    while (i >= 0) {
      final e = i + needle.length;
      if (!options.wholeWord || _isWholeWord(text, i, e)) {
        out.add(TextRange(start: i, end: e));
        i = haystack.indexOf(needle, e);
      } else {
        i = haystack.indexOf(needle, i + 1);
      }
    }
    return out;
  }

  /// Her eşleşmenin yerine yazılacak metin. Düzenli ifadede `$1`, `$2`…
  /// gruplar, `$&` eşleşmenin tamamı, `$$` tek bir `$` olur.
  static List<String> replacementsFor(String text, List<TextRange> ranges,
      String query, String replacement, FindOptions options) {
    if (!options.regex) return [for (final _ in ranges) replacement];
    final re = _regExpFor(query, options);
    return [
      for (final r in ranges)
        switch (re.matchAsPrefix(text, r.start)) {
          final m? => expandReplacement(m, replacement),
          null => replacement,
        },
    ];
  }

  static String expandReplacement(Match m, String template) {
    final b = StringBuffer();
    for (var i = 0; i < template.length; i++) {
      final c = template[i];
      if (c != r'$' || i + 1 >= template.length) {
        b.write(c);
        continue;
      }
      final n = template[i + 1];
      if (n == r'$') {
        b.write(r'$');
        i++;
        continue;
      }
      if (n == '&') {
        b.write(m[0]);
        i++;
        continue;
      }
      final d1 = _digit(n);
      if (d1 != null) {
        var group = d1;
        var used = 1;
        if (i + 2 < template.length) {
          final d2 = _digit(template[i + 2]);
          if (d2 != null && group * 10 + d2 <= m.groupCount) {
            group = group * 10 + d2;
            used = 2;
          }
        }
        if (group <= m.groupCount) {
          b.write(m[group] ?? '');
          i += used;
          continue;
        }
      }
      b.write(c);
    }
    return b.toString();
  }

  static RegExp _regExpFor(String query, FindOptions o) =>
      RegExp(query, caseSensitive: o.matchCase, multiLine: true);

  static final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

  static bool _isWordAt(String t, int i) =>
      i >= 0 && i < t.length && _wordChar.hasMatch(t[i]);

  static bool _isWholeWord(String t, int start, int end) =>
      !_isWordAt(t, start - 1) && !_isWordAt(t, end);

  static int? _digit(String c) {
    final d = c.codeUnitAt(0) - 48;
    return d >= 0 && d <= 9 ? d : null;
  }

  /// Aralıkları (artan sırada, çakışmasız) tek bir düzenlemede değiştirir;
  /// böylece Ctrl+Z hepsini tek adımda geri alır. İmleç son değişikliğin
  /// sonuna gelir.
  void replaceRanges(List<TextRange> ranges, List<String> replacements) {
    if (ranges.isEmpty) return;
    final t = text;
    final b = StringBuffer();
    var last = 0;
    for (var i = 0; i < ranges.length; i++) {
      b
        ..write(t.substring(last, ranges[i].start))
        ..write(replacements[i]);
      last = ranges[i].end;
    }
    final caret = b.length;
    b.write(t.substring(last));
    value = TextEditingValue(
      text: b.toString(),
      selection: TextSelection.collapsed(offset: caret),
    );
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
