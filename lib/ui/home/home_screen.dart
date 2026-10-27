import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'sidebar.dart';

/// Ana ekran. Genişliğe göre üç düzen:
///  - geniş (≥ 1000): sol panel | liste | editör
///  - orta (700-1000): liste | editör, sol panel çekmecede
///  - dar (< 700, telefon): liste, sol panel çekmecede, editör ayrı sayfada
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

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
            ref.read(searchFocusProvider).requestFocus(),
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

class _WideLayout extends StatelessWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Row(children: [
        SizedBox(width: 250, child: Sidebar()),
        VerticalDivider(width: 1),
        SizedBox(width: 340, child: NoteListPane()),
        VerticalDivider(width: 1),
        Expanded(child: _EditorSlot()),
      ]),
    );
  }
}

class _MediumLayout extends StatelessWidget {
  const _MediumLayout();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      drawer: Drawer(child: Sidebar(inDrawer: true)),
      body: Row(children: [
        SizedBox(width: 320, child: NoteListPane(showMenuButton: true)),
        VerticalDivider(width: 1),
        Expanded(child: _EditorSlot()),
      ]),
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
