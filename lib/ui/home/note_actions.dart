import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import '../../backup/backup_service.dart';
import '../../sync/sync_service.dart';
import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';
import '../common/dialogs.dart';
import 'editor_pane.dart';
import 'folder_tree.dart';
import 'home_state.dart';

/// Açık editörlerin bekleyen kayıtları. Kilitlemeden önce hepsi yazılır.
final pendingEditorSaves = <Future<void> Function()>{};

Future<void> lockApp(WidgetRef ref) async {
  for (final flush in [...pendingEditorSaves]) {
    await flush();
  }
  try {
    await ref.read(syncServiceProvider).syncBeforeLock();
  } catch (_) {
    // Eşitlenemese de kilitleme engellenmez; değişiklikler bir sonrakinde gider.
  }
  try {
    await ref.read(backupServiceProvider).backupBeforeLock();
  } catch (_) {
    // Yedek alınamasa da kilitleme engellenmez; hata yedekleme penceresinde görünür.
  }
  await ref.read(sessionProvider.notifier).lock();
}

/// Bulunulan görünüme uygun yeni not: klasördeyse o klasöre, etiketteyse o
/// etiketle, kısa notlar görünümündeyse kısa not olarak.
Future<void> createNoteInView(
  BuildContext context,
  WidgetRef ref, {
  NoteKind? kind,
}) async {
  final repo = ref.read(repositoryProvider);
  final controller = ref.read(homeProvider.notifier);
  var view = ref.read(homeProvider).view;

  if (view.kind == NoteViewKind.archive || view.kind == NoteViewKind.trash) {
    controller.selectView(NoteView.all);
    view = NoteView.all;
  }

  final effectiveKind = kind ??
      (view.kind == NoteViewKind.snippets ? NoteKind.snippet : NoteKind.note);

  final id = await repo.createNote(
    kind: effectiveKind,
    folderId: view.kind == NoteViewKind.folder ? view.id : null,
  );
  if (view.kind == NoteViewKind.tag && view.id != null) {
    await repo.setNoteTags(id, {view.id!});
  }
  if (context.mounted) openNote(context, ref, id);
}

/// Notu seçer; dar ekranda editörü ayrı sayfa olarak açar.
void openNote(BuildContext context, WidgetRef ref, String id) {
  ref.read(homeProvider.notifier).select(id);
  if (isNarrow(context)) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EditorPage(noteId: id),
    ));
  }
}

enum _NoteAction { pin, convert, move, tags, color, archive, trash, restore }

/// Notun sağ tık / uzun basma menüsü.
Future<void> showNoteMenu(
  BuildContext context,
  WidgetRef ref,
  Note note,
  Offset position,
) async {
  final inTrash = note.deletedAt != null;
  final isSnippet = note.kind == NoteKind.snippet;

  PopupMenuItem<_NoteAction> item(_NoteAction a, IconData icon, String label) =>
      PopupMenuItem(
        value: a,
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Text(label),
        ]),
      );

  final action = await showMenu<_NoteAction>(
    context: context,
    position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx, position.dy),
    items: inTrash
        ? [item(_NoteAction.restore, Icons.restore, 'Geri yükle')]
        : [
            item(_NoteAction.pin, Icons.push_pin_outlined,
                note.pinned ? 'Sabitlemeyi kaldır' : 'Sabitle'),
            item(
                _NoteAction.convert,
                isSnippet ? Icons.article_outlined : Icons.sticky_note_2_outlined,
                isSnippet ? 'Tam nota çevir' : 'Kısa nota çevir'),
            item(_NoteAction.move, Icons.drive_file_move_outlined,
                'Klasöre taşı…'),
            item(_NoteAction.tags, Icons.label_outline, 'Etiketler…'),
            item(_NoteAction.color, Icons.palette_outlined, 'Renk…'),
            item(_NoteAction.archive, Icons.inventory_2_outlined,
                note.archived ? 'Arşivden çıkar' : 'Arşivle'),
            item(_NoteAction.trash, Icons.delete_outline, 'Çöpe at'),
          ],
  );
  if (action == null || !context.mounted) return;
  await runNoteAction(context, ref, note, action);
}

Future<void> runNoteAction(
  BuildContext context,
  WidgetRef ref,
  Note note,
  _NoteAction action,
) async {
  final repo = ref.read(repositoryProvider);
  switch (action) {
    case _NoteAction.pin:
      await repo.updateNote(note.id, NoteChanges(pinned: Value(!note.pinned)));
    case _NoteAction.convert:
      await repo.updateNote(
          note.id,
          NoteChanges(
              kind: Value(note.kind == NoteKind.snippet
                  ? NoteKind.note
                  : NoteKind.snippet)));
    case _NoteAction.move:
      await moveNoteDialog(context, ref, note);
    case _NoteAction.tags:
      await editNoteTagsDialog(context, ref, note.id);
    case _NoteAction.color:
      final choice = await showColorPicker(context,
          title: 'Not rengi', current: note.color);
      if (choice != null) {
        await repo.updateNote(note.id, NoteChanges(color: Value(choice.key)));
      }
    case _NoteAction.archive:
      await repo.updateNote(
          note.id, NoteChanges(archived: Value(!note.archived)));
      _deselectIfOpen(ref, note.id);
    case _NoteAction.trash:
      await trashNoteWithUndo(context, ref, note.id);
    case _NoteAction.restore:
      await repo.restoreNote(note.id);
  }
}

// Editör araç çubuğu da aynı işlemleri kullanır.
Future<void> togglePin(WidgetRef ref, Note note) =>
    ref.read(repositoryProvider)
        .updateNote(note.id, NoteChanges(pinned: Value(!note.pinned)));

Future<void> pickNoteColor(BuildContext context, WidgetRef ref, Note note) =>
    runNoteAction(context, ref, note, _NoteAction.color);

Future<void> showNoteMoreMenu(
        BuildContext context, WidgetRef ref, Note note, Offset position) =>
    showNoteMenu(context, ref, note, position);

Future<void> trashNoteWithUndo(
    BuildContext context, WidgetRef ref, String noteId) async {
  final repo = ref.read(repositoryProvider);
  await repo.trashNote(noteId);
  _deselectIfOpen(ref, noteId);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: const Text('Not çöp kutusuna taşındı.'),
    action: SnackBarAction(
      label: 'Geri al',
      onPressed: () => repo.restoreNote(noteId),
    ),
  ));
}

void _deselectIfOpen(WidgetRef ref, String noteId) {
  final home = ref.read(homeProvider);
  if (home.selectedNoteId == noteId) {
    ref.read(homeProvider.notifier).select(null);
  }
}

// ------------------------------------------------------------------ Taşıma

Future<void> moveNoteDialog(
    BuildContext context, WidgetRef ref, Note note) async {
  final repo = ref.read(repositoryProvider);
  final folders = await repo.listFolders();
  if (!context.mounted) return;

  final nodes = flattenTree(buildFolderTree(folders), expandAll: true);

  final picked = await showDialog<_FolderPick>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      Widget option(String? id, String label, int depth, IconData icon) {
        final current = note.folderId == id;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 18, right: 16),
          leading: Icon(icon, size: 20),
          title: Text(label),
          trailing:
              current ? Icon(Icons.check, size: 18, color: scheme.primary) : null,
          onTap: () => Navigator.of(ctx).pop(_FolderPick(id)),
        );
      }

      return AlertDialog(
        title: const Text('Klasöre taşı'),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: 360,
          height: 360,
          child: ListView(children: [
            option(null, 'Klasörsüz', 0, Icons.inbox_outlined),
            for (final n in nodes)
              option(n.folder.id, n.folder.name, n.depth, Icons.folder_outlined),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('İptal'),
          ),
        ],
      );
    },
  );
  if (picked == null) return;
  await repo.updateNote(note.id, NoteChanges(folderId: Value(picked.id)));
}

class _FolderPick {
  final String? id;
  const _FolderPick(this.id);
}

// --------------------------------------------------------------- Etiketler

Future<void> editNoteTagsDialog(
    BuildContext context, WidgetRef ref, String noteId) async {
  final repo = ref.read(repositoryProvider);
  final all = await repo.listTags();
  final selected = (await repo.tagsOfNote(noteId)).map((t) => t.id).toSet();
  if (!context.mounted) return;

  final result = await showDialog<Set<String>>(
    context: context,
    builder: (ctx) => _TagPickerDialog(
      repo: repo,
      initialTags: all,
      initialSelected: selected,
    ),
  );
  if (result != null) await repo.setNoteTags(noteId, result);
}

class _TagPickerDialog extends StatefulWidget {
  final NotesRepository repo;
  final List<Tag> initialTags;
  final Set<String> initialSelected;

  const _TagPickerDialog({
    required this.repo,
    required this.initialTags,
    required this.initialSelected,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  late List<Tag> _tags = [...widget.initialTags];
  late final Set<String> _selected = {...widget.initialSelected};
  final _newTag = TextEditingController();

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _newTag.text.trim();
    if (name.isEmpty) return;
    final existing = _tags.where(
        (t) => t.name.toLowerCase() == name.toLowerCase());
    if (existing.isNotEmpty) {
      setState(() => _selected.add(existing.first.id));
    } else {
      final id = await widget.repo.createTag(name: name);
      _tags = await widget.repo.listTags();
      setState(() => _selected.add(id));
    }
    _newTag.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Etiketler'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _newTag,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Yeni etiket',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Etiket ekle',
                onPressed: _create,
                icon: const Icon(Icons.add),
              ),
            ]),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _tags.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Henüz etiket yok. Yukarıdan ekleyebilirsin.'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in _tags)
                          CheckboxListTile(
                            dense: true,
                            value: _selected.contains(t.id),
                            title: Text(t.name),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setState(() => v == true
                                ? _selected.add(t.id)
                                : _selected.remove(t.id)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Kaydet'),
        ),
      ],
    );
  }
}
