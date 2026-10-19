import '../../core/text/search_text.dart';

const _months = [
  'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
  'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
];

String _two(int v) => v.toString().padLeft(2, '0');

/// Listede kısa tarih: bugün "14:32", bu yıl "15 Eki", daha eski "15.10.2025".
String formatShortDate(int millis, {DateTime? now}) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final n = now ?? DateTime.now();
  if (d.year == n.year && d.month == n.month && d.day == n.day) {
    return '${_two(d.hour)}:${_two(d.minute)}';
  }
  if (d.year == n.year) return '${d.day} ${_months[d.month - 1]}';
  return '${_two(d.day)}.${_two(d.month)}.${d.year}';
}

/// Editörde tam tarih: "15 Eki 2026, 14:32".
String formatLongDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.day} ${_months[d.month - 1]} ${d.year}, '
      '${_two(d.hour)}:${_two(d.minute)}';
}

final _listMarker = RegExp(r'^\s*([-*+]|\d+[.)])\s+');
final _checkbox = RegExp(r'^\[[ xX]\]\s*');
final _emphasis = RegExp(r'[*_`~]+');

/// Markdown gövdeden düz metin önizleme. Başlıklar ve kod blokları atlanır;
/// başlıklar listede ayrıca "içindekiler" olarak gösterilir.
String notePreview(String body, {int maxLength = 160}) {
  final out = StringBuffer();
  var inFence = false;
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('```') || line.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence || line.isEmpty || line.startsWith('#')) continue;

    final clean = stripInlineMarkup(line)
        .replaceFirst(_listMarker, '')
        .replaceFirst(_checkbox, '')
        .replaceAll(_emphasis, '')
        .trim();
    if (clean.isEmpty) continue;

    if (out.isNotEmpty) out.write(' ');
    out.write(clean);
    if (out.length >= maxLength) break;
  }
  final s = out.toString();
  return s.length > maxLength ? '${s.substring(0, maxLength).trimRight()}…' : s;
}
