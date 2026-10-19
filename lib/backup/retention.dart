/// Yedek dosya adı: notlar-yedek-2026-10-15_14-32-05.7z
final backupNamePattern = RegExp(
    r'^notlar-yedek-(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.7z$');

String _two(int v) => v.toString().padLeft(2, '0');

String backupFileName(DateTime t) =>
    'notlar-yedek-${t.year}-${_two(t.month)}-${_two(t.day)}'
    '_${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}.7z';

DateTime? parseBackupTime(String fileName) {
  final m = backupNamePattern.firstMatch(fileName);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// Saklama politikası: son [keepAll] içindeki tüm yedekler, [maxAge]'e kadar
/// her günün en son yedeği tutulur; daha eskiler silinir.
///
/// Yalnızca bu uygulamanın adlandırdığı dosyalara dokunur; klasördeki diğer
/// dosyalar listeye hiç girmez.
List<String> backupsToDelete(
  Iterable<String> fileNames,
  DateTime now, {
  Duration keepAll = const Duration(hours: 24),
  Duration maxAge = const Duration(days: 30),
}) {
  final dated = <(String, DateTime)>[
    for (final n in fileNames)
      if (parseBackupTime(n) case final t?) (n, t),
  ]..sort((a, b) => b.$2.compareTo(a.$2)); // en yeni önce

  final keptDays = <String>{};
  final delete = <String>[];
  for (final (name, t) in dated) {
    final age = now.difference(t);
    if (age > maxAge) {
      delete.add(name);
    } else if (age <= keepAll) {
      continue;
    } else if (!keptDays.add('${t.year}-${t.month}-${t.day}')) {
      delete.add(name);
    }
  }
  return delete;
}
