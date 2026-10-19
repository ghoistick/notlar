import 'dart:convert';

import 'search_text.dart';

/// Not içinden çıkarılan bir başlık. İçindekiler paneli ve listedeki
/// not özeti bunları kullanır.
class Heading {
  /// Notun içindeki sırası (0'dan başlar).
  final int position;

  /// 1-6 arası (# = 1, ## = 2 ...).
  final int level;

  /// Renk işaretleri temizlenmiş başlık metni.
  final String content;

  /// Başlığın bulunduğu satır; içindekilerden tıklayınca oraya gidilir.
  final int line;

  const Heading({
    required this.position,
    required this.level,
    required this.content,
    required this.line,
  });

  @override
  String toString() => '${'#' * level} $content (satır $line)';
}

final _headingRe = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _fenceRe = RegExp(r'^\s*(```|~~~)');

/// Markdown başlıklarını çıkarır. Kod blokları içindeki # satırları atlanır.
List<Heading> extractHeadings(String markdown) {
  final result = <Heading>[];
  var inFence = false;
  var lineNo = 0;

  for (final line in const LineSplitter().convert(markdown)) {
    final current = lineNo++;
    if (_fenceRe.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    final m = _headingRe.firstMatch(line);
    if (m == null) continue;

    final content = stripInlineMarkup(m.group(2)!).trim();
    if (content.isEmpty) continue;

    result.add(Heading(
      position: result.length,
      level: m.group(1)!.length,
      content: content,
      line: current,
    ));
  }
  return result;
}
