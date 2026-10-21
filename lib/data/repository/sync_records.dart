import '../db/database.dart';

/// Başka bir cihazdan gelen tek bir alan değişikliği (change_log satırı).
class RemoteOp {
  final String opId;
  final String entity;
  final String entityId;
  final String field;

  /// JSON olarak kodlanmış değer.
  final String? value;
  final String hlc;

  const RemoteOp({
    required this.opId,
    required this.entity,
    required this.entityId,
    required this.field,
    required this.value,
    required this.hlc,
  });

  factory RemoteOp.fromChange(ChangeLogData c) => RemoteOp(
        opId: c.opId,
        entity: c.entity,
        entityId: c.entityId,
        field: c.field,
        value: c.value,
        hlc: c.hlc,
      );

  Map<String, Object?> toJson() =>
      {'o': opId, 'e': entity, 'i': entityId, 'f': field, 'v': value, 'h': hlc};

  factory RemoteOp.fromJson(Map<String, dynamic> j) => RemoteOp(
        opId: j['o'] as String,
        entity: j['e'] as String,
        entityId: j['i'] as String,
        field: j['f'] as String,
        value: j['v'] as String?,
        hlc: j['h'] as String,
      );
}

class ApplyResult {
  /// Uygulanan değişiklikler.
  int applied = 0;

  /// Daha yeni bir yerel değişiklik olduğu için uygulanmayanlar.
  int ignored = 0;

  /// Daha önce alınmış (tekrar gelen) değişiklikler.
  int duplicates = 0;

  /// Oluşturulan çakışan kopya sayısı.
  int conflicts = 0;

  void add(ApplyResult o) {
    applied += o.applied;
    ignored += o.ignored;
    duplicates += o.duplicates;
    conflicts += o.conflicts;
  }
}
