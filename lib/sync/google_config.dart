import 'dart:io';

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

/// Android'de giriş altyapısının istediği "Web application" istemci kimliği.
/// Telefonda masaüstü istemcisi kullanılmaz; uygulama, Google Cloud'daki
/// Android istemcisiyle paket adı ve imza parmak izinden tanınır.
const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

/// Yalnızca uygulamanın Drive'daki gizli klasörüne erişim. Kullanıcının
/// diğer dosyalarını göremez.
const googleScopes = ['https://www.googleapis.com/auth/drive.appdata'];

bool get googleConfigured => isMobilePlatform
    ? googleServerClientId.isNotEmpty
    : googleClientId.isNotEmpty && googleClientSecret.isNotEmpty;

/// Telefonda Google girişi sistemin kendi altyapısıyla yapılır.
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;
