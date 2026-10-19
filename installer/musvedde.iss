; Müsvedde — Windows kurulum betiği (Inno Setup 6)
;
; Elle derlemek yerine tools\build_release.ps1 kullan; sürüm numarasını
; pubspec.yaml'dan okuyup buraya /DAppVersion ile verir.
;
; AppId ilk sürümde belirlendi ve ASLA değiştirilmemeli: Windows, güncellemenin
; aynı uygulamaya ait olduğunu bu kimlikten anlar.

#define AppName "Müsvedde"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExe "musvedde.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{F60F1D8D-5C21-4061-BD89-D7784E1758CB}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Sahip
VersionInfoVersion={#AppVersion}

; Yönetici izni gerekmez: kullanıcının kendi klasörüne kurulur.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Musvedde
DisableDirPage=yes
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes

OutputDir=..\dist
OutputBaseFilename=MusveddeKurulum-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Güncellerken açık uygulamayı kapatır.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Visual C++ çalışma zamanı: Visual Studio kurulu olmayan bilgisayarlarda da açılsın diye.
Source: "C:\Windows\System32\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Windows\System32\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Windows\System32\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Notlar, ayarlar ve yedekler (%APPDATA%\Sahip\Musvedde ve Belgeler\Notlar_Yedekleri)
; kaldırma sırasında SİLİNMEZ.
