/// Google Cloud'da oluşturulan "Desktop app" istemcisinin bilgileri.
///
/// Değerler kaynak kodda durmaz; derleme sırasında proje klasörünün dışındaki
/// %USERPROFILE%\.musvedde\google.json dosyasından verilir:
///
///   flutter run -d windows --dart-define-from-file=%USERPROFILE%\.musvedde\google.json
///
/// Derleme betiği (tools/build_release.ps1) bunu kendiliğinden yapar.
const googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
const googleClientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

/// Yalnızca uygulamanın Drive'daki gizli klasörüne erişim. Kullanıcının
/// diğer dosyalarını göremez.
const googleScopes = ['https://www.googleapis.com/auth/drive.appdata'];

bool get googleConfigured =>
    googleClientId.isNotEmpty && googleClientSecret.isNotEmpty;
