import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_settings.dart';

/// Masaüstü düzen türü. Telefon düzeninde [PaneHost] hiç yoktur.
enum PaneMode {
  /// Sol menü | liste | editör
  wide,

  /// Liste | editör; sol menü çekmecede
  medium,
}

/// Editörün masaüstü panel düzeni içinde olduğunu bildirir. Telefonda
/// (EditorPage) bulunmadığı için düzen denetimleri orada görünmez.
class PaneHost extends InheritedWidget {
  final PaneMode mode;
  const PaneHost({super.key, required this.mode, required super.child});

  static PaneHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneHost>();

  @override
  bool updateShouldNotify(PaneHost old) => old.mode != mode;
}

/// Düzen kısayolları:
///  - Ctrl+Shift+M: sol menü (yalnızca geniş düzende)
///  - Ctrl+Shift+L: not listesi
///  - F11: odak modu
class LayoutShortcuts extends ConsumerWidget {
  final PaneMode mode;
  final Widget child;
  const LayoutShortcuts({super.key, required this.mode, required this.child});

  static const sidebarKey = SingleActivator(LogicalKeyboardKey.keyM,
      control: true, shift: true);
  static const listKey = SingleActivator(LogicalKeyboardKey.keyL,
      control: true, shift: true);
  static const focusKey = SingleActivator(LogicalKeyboardKey.f11);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(layoutProvider.notifier);
    return CallbackShortcuts(
      bindings: {
        if (mode == PaneMode.wide) sidebarKey: n.toggleSidebar,
        listKey: n.toggleList,
        focusKey: n.toggleFocus,
      },
      child: child,
    );
  }
}

/// Panel genişliklerini pencereye sığdırır. Editöre en az [editorMin]
/// kalması için önce liste, sonra sol menü en küçük genişliğine kadar
/// daraltılır. Kayıtlı değerler değişmez; yalnızca ekrandaki genişlik.
({double sidebar, double list}) fitPaneWidths({
  required double total,
  double? sidebar,
  double? list,
  double editorMin = 360,
}) {
  var s = sidebar ?? 0.0;
  var l = list ?? 0.0;
  final dividers = (sidebar != null ? 1 : 0) + (list != null ? 1 : 0);
  var over = s + l + dividers + editorMin - total;
  if (over > 0 && list != null) {
    final cut = max<double>(0, min<double>(over, l - LayoutPrefs.listMin));
    l -= cut;
    over -= cut;
  }
  if (over > 0 && sidebar != null) {
    final cut = max<double>(0, min<double>(over, s - LayoutPrefs.sidebarMin));
    s -= cut;
  }
  return (sidebar: s, list: l);
}

/// Paneller arasındaki sürüklenebilir ayırıcı. Görünen çizgi 1 px olan
/// [VerticalDivider]'dır; bu tutamaç onun üstüne bindirilen 7 px'lik
/// görünmez alandır. Üzerine gelince ya da sürüklerken vurgulanır, çift
/// tıklayınca varsayılan genişliğe döner.
class PaneResizeHandle extends StatefulWidget {
  /// Sürükleme başladığındaki panel genişliği.
  final double width;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;
  final VoidCallback onReset;

  const PaneResizeHandle({
    super.key,
    required this.width,
    required this.onChanged,
    required this.onEnd,
    required this.onReset,
  });

  @override
  State<PaneResizeHandle> createState() => _PaneResizeHandleState();
}

class _PaneResizeHandleState extends State<PaneResizeHandle> {
  bool _hover = false;
  bool _dragging = false;
  double _start = 0;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart: (_) => setState(() {
          _dragging = true;
          _start = widget.width;
          _dx = 0;
        }),
        onHorizontalDragUpdate: (d) {
          // Toplam kayma başlangıç genişliğine eklenir; sınıra dayanıp
          // geri dönünce imleç ile ayırıcı birbirinden kopmaz.
          _dx += d.delta.dx;
          widget.onChanged(_start + _dx);
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onEnd();
        },
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: active ? 3 : 0,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Editör çubuğundaki düzen denetimleri: gerekirse menü (çekmece) düğmesi,
/// odak modu ve "Görünüm" menüsü. Telefonda hiçbir şey göstermez.
class LayoutControls extends ConsumerWidget {
  const LayoutControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = PaneHost.maybeOf(context);
    if (host == null) return const SizedBox.shrink();

    final l = ref.watch(layoutProvider);
    final n = ref.read(layoutProvider.notifier);
    final sidebarShown = host.mode == PaneMode.wide && l.showSidebar;

    return Row(mainAxisSize: MainAxisSize.min, children: [
      // Ne sol menü ne liste görünüyorsa çekmeceyi açacak başka düğme yok.
      if (!sidebarShown && !l.showList)
        IconButton(
          tooltip: 'Menüyü aç',
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      IconButton(
        tooltip: l.focusMode ? 'Odak modundan çık (F11)' : 'Odak modu (F11)',
        isSelected: l.focusMode,
        icon: const Icon(Icons.fullscreen),
        selectedIcon: const Icon(Icons.fullscreen_exit),
        onPressed: n.toggleFocus,
      ),
      _LayoutMenu(mode: host.mode, prefs: l),
    ]);
  }
}

class _LayoutMenu extends ConsumerWidget {
  final PaneMode mode;
  final LayoutPrefs prefs;
  const _LayoutMenu({required this.mode, required this.prefs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(layoutProvider.notifier);
    final l = prefs;

    List<Widget> widthItems(TextWidth current, ValueChanged<TextWidth> set) => [
          for (final w in TextWidth.values)
            MenuItemButton(
              leadingIcon: Icon(
                w == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
              onPressed: () => set(w),
              child: Text(w.label),
            ),
        ];

    return MenuAnchor(
      menuChildren: [
        if (mode == PaneMode.wide)
          CheckboxMenuButton(
            value: l.showSidebar,
            onChanged: (_) => n.toggleSidebar(),
            shortcut: LayoutShortcuts.sidebarKey,
            child: const Text('Sol menü'),
          ),
        CheckboxMenuButton(
          value: l.showList,
          onChanged: (_) => n.toggleList(),
          shortcut: LayoutShortcuts.listKey,
          child: const Text('Not listesi'),
        ),
        CheckboxMenuButton(
          value: l.focusMode,
          onChanged: (_) => n.toggleFocus(),
          shortcut: LayoutShortcuts.focusKey,
          child: const Text('Odak modu (yalnızca editör)'),
        ),
        const Divider(height: 8),
        SubmenuButton(
          menuChildren: widthItems(l.textWidth, n.setTextWidth),
          child: const Text('Metin genişliği'),
        ),
        SubmenuButton(
          menuChildren: widthItems(l.focusTextWidth, n.setFocusTextWidth),
          child: const Text('Odak modunda metin genişliği'),
        ),
        const Divider(height: 8),
        MenuItemButton(
          onPressed: n.resetWidths,
          child: const Text('Panel genişliklerini sıfırla'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Görünüm',
        icon: const Icon(Icons.view_quilt_outlined),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
