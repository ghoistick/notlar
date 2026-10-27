import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_settings.dart';
import '../../app/session.dart';
import 'note_actions.dart';

/// Uygulama arka plana geçince açık notları hemen kaydeder; ayarlanan süre
/// dolduktan sonra ön plana dönülürse kasayı kilitler.
///
/// Telefonda başka bir uygulamaya geçmek, bilgisayarda pencereyi simge
/// durumuna küçültmek "arka plan" sayılır. Pencereler arasında geçmek
/// sayılmaz.
class AutoLockScope extends ConsumerStatefulWidget {
  final Widget child;
  const AutoLockScope({super.key, required this.child});

  @override
  ConsumerState<AutoLockScope> createState() => _AutoLockScopeState();
}

class _AutoLockScopeState extends ConsumerState<AutoLockScope> {
  late final AppLifecycleListener _listener;
  DateTime? _hiddenAt;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onHide: _onHidden,
      onPause: _onHidden,
      onShow: _onVisible,
      onResume: _onVisible,
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  void _onHidden() {
    _hiddenAt ??= DateTime.now();
    // Android uygulamayı arka planda kapatabilir: yazılanlar hemen kaydedilir.
    for (final flush in [...pendingEditorSaves]) {
      flush();
    }
  }

  Future<void> _onVisible() async {
    final since = _hiddenAt;
    _hiddenAt = null;
    if (since == null) return;

    final minutes = ref.read(autoLockProvider);
    if (minutes < 0) return;
    if (DateTime.now().difference(since) < Duration(minutes: minutes)) return;
    if (ref.read(sessionProvider) is! SessionUnlocked) return;

    // Hızlı kilitleme: eşitleme ve yedek beklenmez; bekleyen değişiklikler
    // bir sonraki açılışta gönderilir.
    for (final flush in [...pendingEditorSaves]) {
      await flush();
    }
    await ref.read(sessionProvider.notifier).lock();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
