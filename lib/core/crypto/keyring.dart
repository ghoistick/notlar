import 'dart:convert';
import 'dart:typed_data';

/// Argon2id maliyet ayarları.
///
/// Ana parola yalnızca kurulumda, yeni cihazda ve kilit tamamen sıfırlandığında
/// sorulacağı için yüksek maliyet kabul edilebilir. Değerler keyring içinde
/// saklandığı için ileride artırılabilir; eski keyring'ler kendi değerleriyle
/// açılmaya devam eder.
class KdfSettings {
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  const KdfSettings({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// Uygulamada kullanılacak değerler (64 MiB, 3 tur).
  static const production =
      KdfSettings(memoryKiB: 65536, iterations: 3, parallelism: 1);

  /// Yalnızca birim testleri için; gerçek veride asla kullanılmaz.
  static const fastForTests =
      KdfSettings(memoryKiB: 1024, iterations: 1, parallelism: 1);
}

/// Belirli bir keyring'de kullanılan Argon2id değerleri ve tuz.
class KdfParams {
  final KdfSettings settings;
  final Uint8List salt;

  const KdfParams({required this.settings, required this.salt});

  Map<String, dynamic> toJson() => {
        'alg': 'argon2id',
        'm': settings.memoryKiB,
        't': settings.iterations,
        'p': settings.parallelism,
        'salt': base64Encode(salt),
      };

  factory KdfParams.fromJson(Map<String, dynamic> json) {
    if (json['alg'] != 'argon2id') {
      throw FormatException('Desteklenmeyen KDF: ${json['alg']}');
    }
    return KdfParams(
      settings: KdfSettings(
        memoryKiB: json['m'] as int,
        iterations: json['t'] as int,
        parallelism: json['p'] as int,
      ),
      salt: base64Decode(json['salt'] as String),
    );
  }
}

/// Veri anahtarının iki ayrı yolla sarmalanmış hali:
/// ana parola ile ve kurtarma anahtarı ile.
///
/// Bu yapı Drive'da `keyring.bin` olarak durur. İçinde açık anahtar yoktur;
/// yalnızca şifreli bloklar, tuzlar ve maliyet ayarları bulunur.
class Keyring {
  static const int currentVersion = 1;

  final int version;
  final KdfParams passwordKdf;
  final Uint8List passwordWrapped;
  final Uint8List recoverySalt;
  final Uint8List recoveryWrapped;

  const Keyring({
    this.version = currentVersion,
    required this.passwordKdf,
    required this.passwordWrapped,
    required this.recoverySalt,
    required this.recoveryWrapped,
  });

  Keyring copyWith({
    KdfParams? passwordKdf,
    Uint8List? passwordWrapped,
    Uint8List? recoverySalt,
    Uint8List? recoveryWrapped,
  }) =>
      Keyring(
        version: version,
        passwordKdf: passwordKdf ?? this.passwordKdf,
        passwordWrapped: passwordWrapped ?? this.passwordWrapped,
        recoverySalt: recoverySalt ?? this.recoverySalt,
        recoveryWrapped: recoveryWrapped ?? this.recoveryWrapped,
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        'password': {
          'kdf': passwordKdf.toJson(),
          'wrapped': base64Encode(passwordWrapped),
        },
        'recovery': {
          'salt': base64Encode(recoverySalt),
          'wrapped': base64Encode(recoveryWrapped),
        },
      };

  factory Keyring.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int;
    if (version != currentVersion) {
      throw FormatException('Desteklenmeyen keyring sürümü: $version');
    }
    final password = json['password'] as Map<String, dynamic>;
    final recovery = json['recovery'] as Map<String, dynamic>;
    return Keyring(
      version: version,
      passwordKdf:
          KdfParams.fromJson(password['kdf'] as Map<String, dynamic>),
      passwordWrapped: base64Decode(password['wrapped'] as String),
      recoverySalt: base64Decode(recovery['salt'] as String),
      recoveryWrapped: base64Decode(recovery['wrapped'] as String),
    );
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory Keyring.decode(List<int> bytes) =>
      Keyring.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}
