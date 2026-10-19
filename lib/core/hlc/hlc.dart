import 'dart:math';

/// Hybrid Logical Clock damgası.
///
/// Fiziksel saat (ms), mantıksal sayaç ve cihaz kimliğinden oluşur. Cihaz
/// saatleri birbirinden sapsa bile değişikliklerin tutarlı sıralanmasını sağlar.
///
/// Metin hali sabit genişliklidir; metin olarak sıralamak, damga olarak
/// sıralamakla aynı sonucu verir. Veritabanında `ORDER BY hlc` güvenle çalışır.
///
///   000001760000000000:0003:k7m2x9qa4b
///   └── milisaniye ──┘ └sayaç┘ └ cihaz ┘
class Hlc implements Comparable<Hlc> {
  static const int _millisWidth = 15;
  static const int _counterWidth = 4;
  static const int maxCounter = 1679615; // 36^4 - 1

  final int millis;
  final int counter;
  final String nodeId;

  const Hlc(this.millis, this.counter, this.nodeId);

  factory Hlc.zero(String nodeId) => Hlc(0, 0, nodeId);

  factory Hlc.parse(String packed) {
    final parts = packed.split(':');
    if (parts.length != 3) {
      throw FormatException('Geçersiz HLC: $packed');
    }
    return Hlc(
      int.parse(parts[0]),
      int.parse(parts[1], radix: 36),
      parts[2],
    );
  }

  String pack() => '${millis.toString().padLeft(_millisWidth, '0')}:'
      '${counter.toRadixString(36).padLeft(_counterWidth, '0')}:$nodeId';

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() => pack();
}

/// Bir cihazın HLC saati.
///
/// [tick] yerel bir değişiklik için yeni damga üretir. [receive] başka bir
/// cihazdan gelen damgayı görünce saati ileri alır; böylece bu cihazda sonradan
/// yapılan değişiklik, gelen değişiklikten her zaman daha yeni sayılır.
class HlcClock {
  final String nodeId;
  final int Function() _physicalNow;
  Hlc _last;

  HlcClock(this.nodeId, {int Function()? now, Hlc? last})
      : _physicalNow = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _last = last ?? Hlc.zero(nodeId);

  Hlc get last => _last;

  Hlc tick() {
    final physical = _physicalNow();
    final next = physical > _last.millis
        ? Hlc(physical, 0, nodeId)
        : Hlc(_last.millis, _last.counter + 1, nodeId);
    return _last = _checked(next);
  }

  Hlc receive(Hlc remote) {
    final physical = _physicalNow();
    final millis = max(physical, max(_last.millis, remote.millis));

    final int counter;
    if (millis == _last.millis && millis == remote.millis) {
      counter = max(_last.counter, remote.counter) + 1;
    } else if (millis == _last.millis) {
      counter = _last.counter + 1;
    } else if (millis == remote.millis) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    return _last = _checked(Hlc(millis, counter, nodeId));
  }

  Hlc _checked(Hlc h) {
    if (h.counter > Hlc.maxCounter) {
      throw StateError('HLC sayacı taştı.');
    }
    return h;
  }
}

/// Cihaz için kalıcı, rastgele kimlik (10 karakter). Kurulumda bir kez üretilir.
String generateNodeId({Random? random}) {
  const alphabet = '0123456789abcdefghjkmnpqrstvwxyz';
  final r = random ?? Random.secure();
  return List.generate(10, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}
