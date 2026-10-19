import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_settings.dart';
import 'app/session.dart';
import 'app/theme.dart';
import 'ui/home/home_screen.dart';
import 'ui/lock/setup_screen.dart';
import 'ui/lock/unlock_screen.dart';

void main() {
  runApp(const ProviderScope(child: NotlarApp()));
}

class NotlarApp extends ConsumerWidget {
  const NotlarApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Müsvedde',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('tr'),
      supportedLocales: const [Locale('tr')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const SessionGate(),
    );
  }
}

/// Oturum durumuna göre doğru ekranı gösterir.
class SessionGate extends ConsumerWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final Widget screen = switch (session) {
      SessionLoading() =>
        const Scaffold(body: Center(child: CircularProgressIndicator())),
      SessionNeedsSetup() => const SetupScreen(),
      SessionLocked() => const UnlockScreen(),
      SessionUnlocked() => const HomeScreen(),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(key: ValueKey(session.runtimeType), child: screen),
    );
  }
}
