import '../common/note_colors.dart';

/// Satırın blok türü.
enum BlockType { paragraph, heading, quote, bullet, ordered, task, fence, code, rule }

class BlockInfo {
  final BlockType type;
  final int level; // başlık seviyesi (1-6)
  final bool checked; // yapılacak maddesi işaretli mi

  const BlockInfo(this.type, {this.level = 0, this.checked = false});
}

/// Bir karakter aralığının satır içi biçimi.
class InlineStyle {
  final bool bold;
  final bool italic;
  final bool strike;
  final bool code;
  final bool link;

  /// Markdown işareti (**, #, {kırmızı} gibi).
  final bool marker;

  /// İmleç başka satırdayken gizlenebilen işaret. Liste işaretleri ("- ",
  /// "1. ") görünür kalır; başlık ve vurgu işaretleri gizlenir.
  final bool hideable;

  /// Yapılacak kutucuğu: "[ ]" ya da "[x]".
  final bool checkbox;

  /// Yazı rengi ve vurgu (fosforlu kalem) rengi: not rengi anahtarı.
  final String? color;
  final String? highlight;

  const InlineStyle({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
    this.link = false,
    this.marker = false,
    this.hideable = false,
    this.checkbox = false,
    this.color,
    this.highlight,
  });

  static const plain = InlineStyle();

  InlineStyle copyWith({
    bool? bold,
    bool? italic,
    bool? strike,
    bool? code,
    bool? link,
    bool? marker,
    bool? hideable,
    bool? checkbox,
    String? color,
    String? highlight,
  }) =>
      InlineStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        strike: strike ?? this.strike,
        code: code ?? this.code,
        link: link ?? this.link,
        marker: marker ?? this.marker,
        hideable: hideable ?? this.hideable,
        checkbox: checkbox ?? this.checkbox,
        color: color ?? this.color,
        highlight: highlight ?? this.highlight,
      );

  @override
  bool operator ==(Object other) =>
      other is InlineStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.strike == strike &&
      other.code == code &&
      other.link == link &&
      other.marker == marker &&
      other.hideable == hideable &&
      other.checkbox == checkbox &&
      other.color == color &&
      other.highlight == highlight;

  @override
  int get hashCode => Object.hash(bold, italic, strike, code, link, marker,
      hideable, checkbox, color, highlight);
}

/// Satır içinde [start, end) aralığı.
class Segment {
  final int start;
  final int end;
  final InlineStyle style;
  const Segment(this.start, this.end, this.style);
}

class ParsedLine {
  /// Satırın belgedeki başlangıç konumu.
  final int offset;
  final String text;
  final BlockInfo block;

  /// Satırı baştan sona, boşluksuz kaplayan parçalar.
  final List<Segment> segments;

  const ParsedLine(this.offset, this.text, this.block, this.segments);
}

// ------------------------------------------------------------- Renk adları

final Map<String, String> _colorNames = {
  for (final c in noteColors) ...{
    c.key: c.key,
    c.label.toLowerCase(): c.key,
  },
};

/// "kırmızı", "KIRMIZI", "kirmizi" -> "kirmizi". Bilinmeyen ad için null.
String? resolveColorName(String name) => _colorNames[name.toLowerCase()];

/// Sözdiziminde kullanılacak ad: "kirmizi" -> "kırmızı".
String colorSyntaxName(String key) =>
    noteColorFor(key)?.label.toLowerCase() ?? key;

// ------------------------------------------------------------ Blok kuralları

final _fenceRe = RegExp(r'^\s*(```|~~~)');
final _headingRe = RegExp(r'^(#{1,6})\s+');

/// Yapılacak maddesi: grup 1 = "- " kısmı, grup 2 = "[ ]" / "[x]".
final taskLinePattern = RegExp(r'^(\s*[-*+]\s+)(\[[ xX]\])(\s+|$)');
final _bulletRe = RegExp(r'^\s*[-*+]\s+');
final _orderedRe = RegExp(r'^\s*\d+[.)]\s+');
final _quoteRe = RegExp(r'^>\s?');
final _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');

/// Tüm belgeyi satır satır ayrıştırır. Kod blokları içindeki satırlara
/// satır içi biçim uygulanmaz.
List<ParsedLine> parseDocument(String text) {
  final out = <ParsedLine>[];
  var offset = 0;
  var inFence = false;

  for (final line in text.split('\n')) {
    final ParsedLine parsed;
    if (_fenceRe.hasMatch(line)) {
      inFence = !inFence;
      parsed = ParsedLine(offset, line, const BlockInfo(BlockType.fence), [
        if (line.isNotEmpty)
          Segment(0, line.length, const InlineStyle(code: true, marker: true)),
      ]);
    } else if (inFence) {
      parsed = ParsedLine(offset, line, const BlockInfo(BlockType.code), [
        if (line.isNotEmpty)
          Segment(0, line.length, const InlineStyle(code: true)),
      ]);
    } else {
      parsed = parseLine(line, offset);
    }
    out.add(parsed);
    offset += line.length + 1;
  }
  return out;
}

ParsedLine parseLine(String line, [int offset = 0]) {
  var block = const BlockInfo(BlockType.paragraph);
  final prefix = <Segment>[];
  var start = 0;
  Match? m;

  if ((m = _headingRe.firstMatch(line)) != null) {
    block = BlockInfo(BlockType.heading, level: m!.group(1)!.length);
    prefix.add(Segment(0, m.end, const InlineStyle(marker: true, hideable: true)));
    start = m.end;
  } else if ((m = taskLinePattern.firstMatch(line)) != null) {
    final bulletEnd = m!.group(1)!.length;
    final boxEnd = bulletEnd + 3;
    block = BlockInfo(BlockType.task,
        checked: m.group(2)!.toLowerCase() == '[x]');
    prefix
      ..add(Segment(0, bulletEnd, const InlineStyle(marker: true, hideable: true)))
      ..add(Segment(bulletEnd, boxEnd, const InlineStyle(checkbox: true)));
    if (m.end > boxEnd) prefix.add(Segment(boxEnd, m.end, InlineStyle.plain));
    start = m.end;
  } else if ((m = _bulletRe.firstMatch(line)) != null) {
    block = const BlockInfo(BlockType.bullet);
    prefix.add(Segment(0, m!.end, const InlineStyle(marker: true)));
    start = m.end;
  } else if ((m = _orderedRe.firstMatch(line)) != null) {
    block = const BlockInfo(BlockType.ordered);
    prefix.add(Segment(0, m!.end, const InlineStyle(marker: true)));
    start = m.end;
  } else if ((m = _quoteRe.firstMatch(line)) != null) {
    block = const BlockInfo(BlockType.quote);
    prefix.add(Segment(0, m!.end, const InlineStyle(marker: true, hideable: true)));
    start = m.end;
  } else if (_ruleRe.hasMatch(line)) {
    return ParsedLine(offset, line, const BlockInfo(BlockType.rule),
        [Segment(0, line.length, const InlineStyle(marker: true))]);
  }

  return ParsedLine(offset, line, block, [...prefix, ...parseInline(line, start)]);
}

// --------------------------------------------------------- Satır içi kurallar

final _codeRe = RegExp(r'`([^`]+)`');
final _linkRe = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
final _colorRe = RegExp(r'\{(!?)(\p{L}+)\}(.+?)\{/\}', unicode: true);

typedef _Wrap = (RegExp, int, InlineStyle Function(InlineStyle));

final List<_Wrap> _wrappers = [
  (RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*'), 2, (s) => s.copyWith(bold: true)),
  (RegExp(r'__(?=\S)(.+?)(?<=\S)__'), 2, (s) => s.copyWith(bold: true)),
  (RegExp(r'~~(?=\S)(.+?)(?<=\S)~~'), 2, (s) => s.copyWith(strike: true)),
  (RegExp(r'==(?=\S)(.+?)(?<=\S)=='), 2, (s) => s.copyWith(highlight: 'sari')),
  (
    RegExp(r'(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)'),
    1,
    (s) => s.copyWith(italic: true)
  ),
  // Kelime içindeki alt çizgiler (degisken_adi_x) italik sayılmaz.
  (
    RegExp(r'(?<![_\p{L}\p{N}])_(?=\S)(.+?)(?<=\S)_(?![_\p{L}\p{N}])',
        unicode: true),
    1,
    (s) => s.copyWith(italic: true)
  ),
];

/// [from] konumundan satır sonuna kadar satır içi biçimleri çıkarır.
List<Segment> parseInline(String line, int from) {
  final len = line.length;
  if (from >= len) return const [];

  final st = List<InlineStyle>.filled(len, InlineStyle.plain);
  final protected = List<bool>.filled(len, false);

  bool delimiterFree(int s, int e) {
    for (var i = s; i < e; i++) {
      if (protected[i] || st[i].marker) return false;
    }
    return true;
  }

  void mark(int s, int e) {
    for (var i = s; i < e; i++) {
      st[i] = st[i].copyWith(marker: true, hideable: true);
    }
  }

  void apply(int s, int e, InlineStyle Function(InlineStyle) f) {
    for (var i = s; i < e; i++) {
      if (!st[i].marker) st[i] = f(st[i]);
    }
  }

  // 1. Satır içi kod: içine başka biçim uygulanmaz.
  for (final m in _codeRe.allMatches(line, from)) {
    mark(m.start, m.start + 1);
    mark(m.end - 1, m.end);
    apply(m.start + 1, m.end - 1, (s) => s.copyWith(code: true));
    for (var i = m.start; i < m.end; i++) {
      protected[i] = true;
    }
  }

  // 2. Bağlantı: [metin](adres) — adres kısmı işaret sayılır.
  for (final m in _linkRe.allMatches(line, from)) {
    if (!delimiterFree(m.start, m.start + 1)) continue;
    final textEnd = m.start + 1 + m.group(1)!.length;
    mark(m.start, m.start + 1);
    mark(textEnd, m.end);
    apply(m.start + 1, textEnd, (s) => s.copyWith(link: true));
    for (var i = textEnd; i < m.end; i++) {
      protected[i] = true;
    }
  }

  // 3. Renk: {kırmızı}metin{/} ve vurgu: {!sarı}metin{/}
  for (final m in _colorRe.allMatches(line, from)) {
    final key = resolveColorName(m.group(2)!);
    if (key == null) continue;
    final highlight = m.group(1)!.isNotEmpty;
    final openEnd = m.start + 2 + m.group(1)!.length + m.group(2)!.length;
    if (!delimiterFree(m.start, openEnd) || !delimiterFree(m.end - 3, m.end)) {
      continue;
    }
    mark(m.start, openEnd);
    mark(m.end - 3, m.end);
    apply(openEnd, m.end - 3,
        (s) => highlight ? s.copyWith(highlight: key) : s.copyWith(color: key));
  }

  // 4. Kalın, üstü çizili, vurgu, italik.
  for (final (re, dl, f) in _wrappers) {
    for (final m in re.allMatches(line, from)) {
      if (!delimiterFree(m.start, m.start + dl) ||
          !delimiterFree(m.end - dl, m.end)) {
        continue;
      }
      mark(m.start, m.start + dl);
      mark(m.end - dl, m.end);
      apply(m.start + dl, m.end - dl, f);
    }
  }

  // Aynı biçimdeki ardışık karakterleri tek parçada birleştir.
  final out = <Segment>[];
  var segStart = from;
  for (var i = from + 1; i <= len; i++) {
    if (i == len || st[i] != st[segStart]) {
      out.add(Segment(segStart, i, st[segStart]));
      segStart = i;
    }
  }
  return out;
}
