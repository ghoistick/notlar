import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_settings.dart';
import '../../backup/backup_service.dart';
import '../../sync/google_account.dart';
import '../../sync/sync_service.dart';
import '../../update/update_service.dart';
import '../../data/db/tables.dart';
import 'auto_lock.dart';
import 'editor_pane.dart';
import 'home_state.dart';
import 'note_actions.dart';
import 'note_list_pane.dart';
import 'pane_layout.dart';
import 'sidebar.dart';

/// Ana ekran. Genişliğe göre üç düzen:
///  - geniş (≥ 1000): sol panel | liste | editör
///  - orta (700-1000): liste | editör, sol panel çekmecede
///  - dar (< 700, telefon): liste, sol panel çekmecede, editör ayrı sayfada
///
/// Geniş ve orta düzende paneller gizlenebilir, genişlikleri sürüklenerek
/// değiştirilebilir ve odak modunda yalnızca editör kalır (bkz.
/// [layoutProvider], pane_layout.dart). Dar düzen bu ayarlardan etkilenmez.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  /// Ctrl+F: not listesi gizliyse önce açılır, sonra arama kutusuna geçilir.
  void _focusSearch(WidgetRef ref) {
    final revealed = ref.read(layoutProvider.notifier).revealList();
    final focus = ref.read(searchFocusProvider);
    if (revealed) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => focus.requestFocus());
    } else {
      focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Kasa açık kaldığı sürece otomatik yedekleme çalışır.
    ref.watch(backupServiceProvider);
    // Google oturumu kasa açık kaldığı sürece hazır tutulur.
    ref.watch(googleAccountProvider);
    // Eşitleme, kasa açık kaldığı sürece arka planda çalışır.
    ref.watch(syncServiceProvider);
    // Günde en fazla bir kez, sessizce güncelleme denetimi.
    ref.watch(startupUpdateCheckProvider);

    return AutoLockScope(
      child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            createNoteInView(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyN,
                control: true, shift: true): () =>
            createNoteInView(context, ref, kind: NoteKind.snippet),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _focusSearch(ref),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
            lockApp(ref),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 1000) return const _WideLayout();
          if (c.maxWidth >= 700) return const _MediumLayout();
          return const _NarrowLayout();
        }),
      ),
      ),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(layoutProvider);
    final n = ref.read(layoutProvider.notifier);
    final showSidebar = l.showSidebar;
    final showList = l.showList;

    return PaneHost(
      mode: PaneMode.wide,
      child: LayoutShortcuts(
        mode: PaneMode.wide,
        child: Scaffold(
          // Sol menü gizliyken listedeki ya da editördeki menü düğmesi
          // onu çekmece olarak açar.
          drawer: showSidebar
              ? null
              : const Drawer(child: Sidebar(inDrawer: true)),
          body: LayoutBuilder(builder: (context, c) {
            final w = fitPaneWidths(
              total: c.maxWidth,
              sidebar: showSidebar ? l.sidebarWidth : null,
              list: showList ? l.listWidth : null,
            );
            final listLeft = showSidebar ? w.sidebar + 1 : 0.0;

            return Stack(children: [
              // Anahtarlar, bir panel gizlenince diğerlerinin durumunun
              // (arama metni, kaydırma, editör) kaybolmaması içindir.
              Row(children: [
                if (showSidebar) ...[
                  SizedBox(
                      key: const ValueKey('sidebar'),
                      width: w.sidebar,
                      child: const Sidebar()),
                  const VerticalDivider(key: ValueKey('sidebar-div'), width: 1),
                ],
                if (showList) ...[
                  SizedBox(
                      key: const ValueKey('list'),
                      width: w.list,
                      child: NoteListPane(showMenuButton: !showSidebar)),
                  const VerticalDivider(key: ValueKey('list-div'), width: 1),
                ],
                const Expanded(key: ValueKey('editor'), child: _EditorSlot()),
              ]),
              if (showSidebar)
                Positioned(
                  left: w.sidebar - 3,
                  top: 0,
                  bottom: 0,
                  width: 7,
                  child: PaneResizeHandle(
                    width: w.sidebar,
                    onChanged: n.setSidebarWidth,
                    onEnd: n.saveNow,
                    onReset: n.resetSidebarWidth,
                  ),
                ),
              if (showList)
                Positioned(
                  left: listLeft + w.list - 3,
                  top: 0,
                  bottom: 0,
                  width: 7,
                  child: PaneResizeHandle(
                    width: w.list,
                    onChanged: n.setListWidth,
                    onEnd: n.saveNow,
                    onReset: n.resetListWidth,
                  ),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

class _MediumLayout extends ConsumerWidget {
  const _MediumLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(layoutProvider);
    final n = ref.read(layoutProvider.notifier);
    final showList = l.showList;

    return PaneHost(
      mode: PaneMode.medium,
      child: LayoutShortcuts(
        mode: PaneMode.medium,
        child: Scaffold(
          drawer: const Drawer(child: Sidebar(inDrawer: true)),
          body: LayoutBuilder(builder: (context, c) {
            final w = fitPaneWidths(
              total: c.maxWidth,
              list: showList ? l.listWidth : null,
            );
            return Stack(children: [
              Row(children: [
                if (showList) ...[
                  SizedBox(
                      key: const ValueKey('list'),
                      width: w.list,
                      child: const NoteListPane(showMenuButton: true)),
                  const VerticalDivider(key: ValueKey('list-div'), width: 1),
                ],
                const Expanded(key: ValueKey('editor'), child: _EditorSlot()),
              ]),
              if (showList)
                Positioned(
                  left: w.list - 3,
                  top: 0,
                  bottom: 0,
                  width: 7,
                  child: PaneResizeHandle(
                    width: w.list,
                    onChanged: n.setListWidth,
                    onEnd: n.saveNow,
                    onReset: n.resetListWidth,
                  ),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      drawer: Drawer(child: Sidebar(inDrawer: true)),
      body: SafeArea(child: NoteListPane(showMenuButton: true)),
    );
  }
}

/// Seçili notun editörü. Not değişince editör yeniden kurulur; eski notun
/// bekleyen kaydı o sırada yazılır.
class _EditorSlot extends ConsumerWidget {
  const _EditorSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(homeProvider.select((s) => s.selectedNoteId));
    if (id == null) return const EmptyEditor();
    return EditorPane(key: ValueKey(id), noteId: id);
  }
}
