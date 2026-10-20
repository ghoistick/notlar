/// Sürüm imzalarını doğrulayan açık anahtar (Ed25519, base64).
///
/// `dart run tools/release_tool.dart keygen` komutunun yazdırdığı değer buraya
/// konur. Boşken güncelleme denetimi kapalıdır.
///
/// Bu değer gizli değildir; depoda durması güvenlidir. Gizli olan, yalnızca
/// senin bilgisayarında duran ve parolayla şifrelenmiş olan özel anahtardır.
const releasePublicKeyBase64 = 'CxrGqirH/OHEidM8E1XEoDA57LOateFez8Tt+QFRnhA=';
