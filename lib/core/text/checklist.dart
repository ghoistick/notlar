/// Liste notlarının (type = checklist) gövdesi.
///
/// Gövde düz Markdown olarak kalır: her madde bir satırdır.
///
///   - [ ] süt
///   - [x] ekmek
///
/// Böylece yedekler uygulama olmadan okunur, senkronizasyon ve şema değişmez.
/// İşaretlenen maddeler gövdede yerinde durur; yalnızca liste görünümü
/// onları altta toplar (işaret kaldırılınca eski yerine döner).
class ChecklistEntry {
  final String text;
  final bool checked;
  const ChecklistEntry(this.text, {this.checked = false});

  @override
  bool operator ==(Object other) =>
      other is ChecklistEntry && other.text == text && other.checked == checked;

  @override
  int get hashCode => Object.hash(text, checked);

  @override
  String toString() => '${checked ? '[x]' : '[ ]'} $text';
}

abstract final class Checklist {
  /// "- [ ] metin", "* [x] metin", girintili olabilir. Metin boş olabilir.
  static final _item = RegExp(r'^\s*[-*+]\s+\[( |x|X)\](?:\s(.*))?$');

  /// Madde işareti olmayan satırların başındaki "- ", "* ", "1. " vb.
  static final _bullet = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+');

  static bool isItemLine(String line) => _item.hasMatch(line);

  /// Gövdeyi maddelere ayırır.
  ///
  /// Kutucuklu satırlar olduğu gibi alınır. Kutucuksuz dolu satırlar
  /// (listeye çevrilen bir metin ya da Markdown görünümünde eklenen satırlar)
  /// liste işareti atılarak işaretsiz madde olur. Boş satırlar atlanır.
  /// Girinti (iç içe madde) bu sürümde korunmaz.
  static List<ChecklistEntry> parse(String body) {
    final out = <ChecklistEntry>[];
    for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
      final m = _item.firstMatch(raw);
      if (m != null) {
        out.add(ChecklistEntry((m.group(2) ?? '').trimRight(),
            checked: m.group(1) != ' '));
        continue;
      }
      if (raw.trim().isEmpty) continue;
      out.add(ChecklistEntry(raw.replaceFirst(_bullet, '').trim()));
    }
    return out;
  }

  /// Maddeleri gövdeye yazar.
  static String format(Iterable<ChecklistEntry> items) => items
      .map((e) => '- [${e.checked ? 'x' : ' '}] ${e.text}'.trimRight())
      .join('\n');

  /// Bir metni liste gövdesine çevirir (not → liste dönüşümü).
  static String fromText(String body) => format(parse(body));

  /// Kartlardaki ilerleme: işaretli / toplam.
  static ({int done, int total}) progress(String body) {
    final items = parse(body);
    return (done: items.where((e) => e.checked).length, total: items.length);
  }
}
