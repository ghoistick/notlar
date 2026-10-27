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

  Future<void> update(String key, Object? value) async {
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
