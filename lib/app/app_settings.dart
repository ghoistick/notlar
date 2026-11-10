import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'paths.dart';

/// Kilit açılmadan önce de gereken, gizli olmayan cihaz ayarları.
///
/// Şifreli veritabanının dışında, uygulamanın destek klasöründe
/// settings.json dosyasında durur. Buraya not içeriği ya da kişisel bilgi
/// konmaz.
class AppSettingsStore {
  Future<File> _file() async {
    final dir = await appDataDirectory();
    return File(p.join(dir.path, 'settings.json'));
  }

  Future<Map<String, dynamic>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {}; // bozuk ya da okunamayan ayar dosyası varsayılanlara döner
    }
  }

  /// Yazmalar sıraya alınır: art arda gelen iki güncelleme aynı anda
  /// dosyayı okuyup birbirinin değişikliğini ezmesin. Sıra, tüm
  /// örnekler arasında ortaktır.
  static Future<void> _queue = Future.value();

  Future<void> update(String key, Object? value) {
    return _queue = _queue.then((_) => _write(key, value));
  }

  Future<void> _write(String key, Object? value) async {
    try {
      final data = await load();
      data[key] = value;
      await (await _file()).writeAsString(jsonEncode(data), flush: true);
    } catch (_) {
      // Ayar kaydedilemezse uygulama çalışmaya devam eder.
    }
  }
}

final settingsStoreProvider = Provider((ref) => AppSettingsStore());

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final data = await ref.read(settingsStoreProvider).load();
    state = switch (data['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  void set(ThemeMode mode) {
    state = mode;
    ref.read(settingsStoreProvider).update('theme', mode.name);
  }
}


/// Uygulama arka plana geçtikten kaç dakika sonra kilitlensin.
/// 0: hemen, -1: hiçbir zaman. Varsayılan 5 dakika.
final autoLockProvider =
    NotifierProvider<AutoLockNotifier, int>(AutoLockNotifier.new);

class AutoLockNotifier extends Notifier<int> {
  static const options = [0, 1, 5, 15, 60, -1];

  @override
  int build() {
    _load();
    return 5;
  }

  Future<void> _load() async {
    final v = (await ref.read(settingsStoreProvider).load())['autoLockMinutes'];
    if (v is int && options.contains(v)) state = v;
  }

  void set(int minutes) {
    state = minutes;
    ref.read(settingsStoreProvider).update('autoLockMinutes', minutes);
  }
}


// ------------------------------------------------------------------ Düzen

/// Editördeki metin sütununun en büyük genişliği.
enum TextWidth {
  readable('Okunaklı (760 px)', 760),
  wide('Geniş (1000 px)', 1000),
  full('Tam genişlik', double.infinity);

  final String label;
  final double maxWidth;
  const TextWidth(this.label, this.maxWidth);
}

/// Masaüstü panel düzeni ve sol menü bölümlerinin katlanma durumu.
///
/// settings.json içinde tek bir `layout` anahtarında durur. Odak modu
/// dosyaya yazılmaz: uygulama her açılışta normal düzende başlar
/// (kilitleyip açınca ise bellekte kaldığı için korunur).
class LayoutPrefs {
  static const sidebarMin = 180.0, sidebarMax = 400.0, sidebarDefault = 250.0;
  static const listMin = 240.0, listMax = 560.0, listDefault = 340.0;

  final double sidebarWidth;
  final double listWidth;
  final bool sidebarVisible;
  final bool listVisible;
  final bool focusMode;
  final bool foldersCollapsed;
  final bool tagsCollapsed;
  final TextWidth textWidth;
  final TextWidth focusTextWidth;

  const LayoutPrefs({
    this.sidebarWidth = sidebarDefault,
    this.listWidth = listDefault,
    this.sidebarVisible = true,
    this.listVisible = true,
    this.focusMode = false,
    this.foldersCollapsed = false,
    this.tagsCollapsed = false,
    this.textWidth = TextWidth.readable,
    this.focusTextWidth = TextWidth.readable,
  });

  /// Odak modu dikkate alınarak panellerin gerçekten görünüp görünmediği.
  bool get showSidebar => sidebarVisible && !focusMode;
  bool get showList => listVisible && !focusMode;

  LayoutPrefs copyWith({
    double? sidebarWidth,
    double? listWidth,
    bool? sidebarVisible,
    bool? listVisible,
    bool? focusMode,
    bool? foldersCollapsed,
    bool? tagsCollapsed,
    TextWidth? textWidth,
    TextWidth? focusTextWidth,
  }) =>
      LayoutPrefs(
        sidebarWidth: sidebarWidth ?? this.sidebarWidth,
        listWidth: listWidth ?? this.listWidth,
        sidebarVisible: sidebarVisible ?? this.sidebarVisible,
        listVisible: listVisible ?? this.listVisible,
        focusMode: focusMode ?? this.focusMode,
        foldersCollapsed: foldersCollapsed ?? this.foldersCollapsed,
        tagsCollapsed: tagsCollapsed ?? this.tagsCollapsed,
        textWidth: textWidth ?? this.textWidth,
        focusTextWidth: focusTextWidth ?? this.focusTextWidth,
      );

  Map<String, Object?> toJson() => {
        'sidebarWidth': sidebarWidth,
        'listWidth': listWidth,
        'sidebarVisible': sidebarVisible,
        'listVisible': listVisible,
        'foldersCollapsed': foldersCollapsed,
        'tagsCollapsed': tagsCollapsed,
        'textWidth': textWidth.name,
        'focusTextWidth': focusTextWidth.name,
      };

  /// Eksik ya da bozuk değerler varsayılana döner.
  factory LayoutPrefs.fromJson(Map<String, dynamic> j) {
    double width(Object? v, double def, double lo, double hi) =>
        v is num ? v.toDouble().clamp(lo, hi) : def;
    final widths = TextWidth.values.asNameMap();
    return LayoutPrefs(
      sidebarWidth:
          width(j['sidebarWidth'], sidebarDefault, sidebarMin, sidebarMax),
      listWidth: width(j['listWidth'], listDefault, listMin, listMax),
      sidebarVisible: j['sidebarVisible'] != false,
      listVisible: j['listVisible'] != false,
      foldersCollapsed: j['foldersCollapsed'] == true,
      tagsCollapsed: j['tagsCollapsed'] == true,
      textWidth: widths[j['textWidth']] ?? TextWidth.readable,
      focusTextWidth: widths[j['focusTextWidth']] ?? TextWidth.readable,
    );
  }
}

final layoutProvider =
    NotifierProvider<LayoutNotifier, LayoutPrefs>(LayoutNotifier.new);

class LayoutNotifier extends Notifier<LayoutPrefs> {
  /// Dosya okunmadan önce kullanıcı bir şey değiştirdiyse, geç gelen
  /// dosya içeriği o değişikliği ezmesin.
  bool _touched = false;

  @override
  LayoutPrefs build() {
    _load();
    return const LayoutPrefs();
  }

  Future<void> _load() async {
    final raw = (await ref.read(settingsStoreProvider).load())['layout'];
    if (_touched || raw is! Map) return;
    state = LayoutPrefs.fromJson(raw.cast<String, dynamic>());
  }

  void _set(LayoutPrefs p, {bool save = true}) {
    _touched = true;
    state = p;
    if (save) saveNow();
  }

  /// Geçerli düzeni dosyaya yazar (sürükleme bitince çağrılır).
  void saveNow() =>
      ref.read(settingsStoreProvider).update('layout', state.toJson());

  /// Sol menüyü göster/gizle. Odak modundayken çıkar ve menüyü gösterir.
  void toggleSidebar() => _set(state.focusMode
      ? state.copyWith(focusMode: false, sidebarVisible: true)
      : state.copyWith(sidebarVisible: !state.sidebarVisible));

  /// Not listesini göster/gizle. Odak modundayken çıkar ve listeyi gösterir.
  void toggleList() => _set(state.focusMode
      ? state.copyWith(focusMode: false, listVisible: true)
      : state.copyWith(listVisible: !state.listVisible));

  /// Odak modu yalnızca bellekte tutulur; diğer ayarlara dokunmaz.
  void toggleFocus() {
    _touched = true;
    state = state.copyWith(focusMode: !state.focusMode);
  }

  /// Not listesi gizliyse görünür yapar. Değişiklik olduysa true döner.
  bool revealList() {
    if (state.showList) return false;
    _set(state.copyWith(focusMode: false, listVisible: true));
    return true;
  }

  /// Sürükleme sırasında her karede çağrılır; dosyaya yazmaz.
  void setSidebarWidth(double w) => _set(
      state.copyWith(
          sidebarWidth:
              w.clamp(LayoutPrefs.sidebarMin, LayoutPrefs.sidebarMax)),
      save: false);

  void setListWidth(double w) => _set(
      state.copyWith(
          listWidth: w.clamp(LayoutPrefs.listMin, LayoutPrefs.listMax)),
      save: false);

  void resetSidebarWidth() =>
      _set(state.copyWith(sidebarWidth: LayoutPrefs.sidebarDefault));

  void resetListWidth() =>
      _set(state.copyWith(listWidth: LayoutPrefs.listDefault));

  void resetWidths() => _set(state.copyWith(
      sidebarWidth: LayoutPrefs.sidebarDefault,
      listWidth: LayoutPrefs.listDefault));

  void toggleFolders() =>
      _set(state.copyWith(foldersCollapsed: !state.foldersCollapsed));

  void toggleTags() =>
      _set(state.copyWith(tagsCollapsed: !state.tagsCollapsed));

  void setTextWidth(TextWidth w) => _set(state.copyWith(textWidth: w));

  void setFocusTextWidth(TextWidth w) =>
      _set(state.copyWith(focusTextWidth: w));
}
