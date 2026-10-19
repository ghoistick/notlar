import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';
import '../common/dialogs.dart';
import '../common/note_colors.dart';
import 'folder_tree.dart';
import 'home_state.dart';
import 'note_actions.dart';

/// Sol panel: görünümler, klasör ağacı, etiketler, arşiv ve çöp kutusu.
class Sidebar extends ConsumerStatefulWidget {
  /// Çekmece içinde açıldıysa, seçimden sonra çekmece kapanır.
  final bool inDrawer;
  const Sidebar({super.key, this.inDrawer = false});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final _expanded = <String>{};

  void _select(NoteView view) {
    ref.read(homeProvider.notifier).selectView(view);
    if (widget.inDrawer) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = ref.watch(homeProvider.select((s) => s.view));
    final folders = ref.watch(foldersProvider).when(
        data: (d) => d, loading: () => <Folder>[], error: (_, __) => <Folder>[]);
    final tags = ref.watch(tagsProvider).when(
        data: (d) => d, loading: () => <Tag>[], error: (_, __) => <Tag>[]);

    final rows = flattenTree(buildFolderTree(folders), expanded: _expanded);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
              child: Row(children: [
                Expanded(
                  child: Text('Notlar',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Kilitle (Ctrl+L)',
                  icon: const Icon(Icons.lock_outline, size: 20),
                  onPressed: () => lockApp(ref),
                ),
              ]),
            ),
            _NavRow(
              icon: Icons.notes_outlined,
              label: 'Tüm notlar',
              selected: view == NoteView.all,
              onTap: () => _select(NoteView.all),
            ),
            _NavRow(
              icon: Icons.sticky_note_2_outlined,
              label: 'Kısa notlar',
              selected: view == NoteView.snippets,
              onTap: () => _select(NoteView.snippets),
            ),
            _SectionHeader(
              label: 'Klasörler',
              addTooltip: 'Yeni klasör',
              onAdd: () => _newFolder(null),
            ),
            if (rows.isEmpty)
              const _EmptyHint('Notlarını projelere ayırmak için klasör oluştur.'),
            for (final r in rows) _folderRow(r, view),
            _SectionHeader(
              label: 'Etiketler',
              addTooltip: 'Yeni etiket',
              onAdd: _newTag,
            ),
            if (tags.isEmpty)
              const _EmptyHint('Etiketler klasörden bağımsız olarak notları gruplar.'),
            for (final t in tags) _tagRow(t, view),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(),
            ),
            _NavRow(
              icon: Icons.inventory_2_outlined,
              label: 'Arşiv',
              selected: view == NoteView.archive,
              onTap: () => _select(NoteView.archive),
            ),
            _NavRow(
              icon: Icons.delete_outline,
              label: 'Çöp kutusu',
              selected: view == NoteView.trash,
              onTap: () => _select(NoteView.trash),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- Klasör

  Widget _folderRow(FolderRow r, NoteView view) {
    final f = r.folder;
    final expanded = _expanded.contains(f.id);
    final swatch = noteColorFor(f.color)?.swatch;

    return DragTarget<String>(
      onAcceptWithDetails: (d) => ref
          .read(repositoryProvider)
          .updateNote(d.data, NoteChanges(folderId: Value(f.id))),
      builder: (context, candidates, _) => _NavRow(
        indent: r.depth * 16.0,
        highlighted: candidates.isNotEmpty,
        leading: SizedBox(
          width: 20,
          child: r.hasChildren
              ? InkResponse(
                  radius: 14,
                  onTap: () => setState(() =>
                      expanded ? _expanded.remove(f.id) : _expanded.add(f.id)),
                  child: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                  ),
                )
              : null,
        ),
        icon: expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
        iconColor: swatch,
        label: f.name,
        selected: view == NoteView.folder(f.id),
        onTap: () => _select(NoteView.folder(f.id)),
        menu: _menu([
          ('Alt klasör ekle', () => _newFolder(f.id)),
          ('Yeniden adlandır', () => _renameFolder(f)),
          ('Renk', () => _folderColor(f)),
          ('Köke taşı', f.parentId == null ? null : () => _moveFolderToRoot(f)),
          ('Sil', () => _deleteFolder(f)),
        ]),
      ),
    );
  }

  Future<void> _newFolder(String? parentId) async {
    final name = await showTextInputDialog(context,
        title: parentId == null ? 'Yeni klasör' : 'Yeni alt klasör',
        label: 'Klasör adı',
        confirmLabel: 'Oluştur');
    if (name == null) return;
    final id = await ref
        .read(repositoryProvider)
        .createFolder(name: name, parentId: parentId);
    if (parentId != null) setState(() => _expanded.add(parentId));
    _select(NoteView.folder(id));
  }

  Future<void> _renameFolder(Folder f) async {
    final name = await showTextInputDialog(context,
        title: 'Klasörü yeniden adlandır',
        initial: f.name,
        confirmLabel: 'Kaydet');
    if (name == null) return;
    await ref.read(repositoryProvider).updateFolder(f.id, name: Value(name));
  }

  Future<void> _folderColor(Folder f) async {
    final c = await showColorPicker(context,
        title: 'Klasör rengi', current: f.color);
    if (c == null) return;
    await ref.read(repositoryProvider).updateFolder(f.id, color: Value(c.key));
  }

  Future<void> _moveFolderToRoot(Folder f) =>
      ref.read(repositoryProvider).moveFolder(f.id, null);

  Future<void> _deleteFolder(Folder f) async {
    final ok = await showConfirmDialog(context,
        title: 'Klasör silinsin mi?',
        message: '“${f.name}”, alt klasörleri ve içindeki notlar çöp '
            'kutusuna taşınacak. Çöp kutusundan geri yükleyebilirsin.',
        confirmLabel: 'Çöpe taşı');
    if (!ok) return;
    await ref.read(repositoryProvider).trashFolder(f.id);
    final view = ref.read(homeProvider).view;
    if (view.kind == NoteViewKind.folder) _select(NoteView.all);
  }

  // --------------------------------------------------------------- Etiket

  Widget _tagRow(Tag t, NoteView view) {
    final swatch = noteColorFor(t.color)?.swatch;
    return _NavRow(
      icon: Icons.label_outline,
      iconColor: swatch,
      label: t.name,
      selected: view == NoteView.tag(t.id),
      onTap: () => _select(NoteView.tag(t.id)),
      menu: _menu([
        ('Yeniden adlandır', () => _renameTag(t)),
        ('Renk', () => _tagColor(t)),
        ('Sil', () => _deleteTag(t)),
      ]),
    );
  }

  Future<void> _newTag() async {
    final name = await showTextInputDialog(context,
        title: 'Yeni etiket', label: 'Etiket adı', confirmLabel: 'Oluştur');
    if (name == null) return;
    await ref.read(repositoryProvider).createTag(name: name);
  }

  Future<void> _renameTag(Tag t) async {
    final name = await showTextInputDialog(context,
        title: 'Etiketi yeniden adlandır', initial: t.name, confirmLabel: 'Kaydet');
    if (name == null) return;
    await ref.read(repositoryProvider).updateTag(t.id, name: Value(name));
  }

  Future<void> _tagColor(Tag t) async {
    final c =
        await showColorPicker(context, title: 'Etiket rengi', current: t.color);
    if (c == null) return;
    await ref.read(repositoryProvider).updateTag(t.id, color: Value(c.key));
  }

  Future<void> _deleteTag(Tag t) async {
    final ok = await showConfirmDialog(context,
        title: 'Etiket silinsin mi?',
        message: '“${t.name}” etiketi tüm notlardan kaldırılacak. '
            'Notların kendisi silinmez.',
        confirmLabel: 'Etiketi sil');
    if (!ok) return;
    await ref.read(repositoryProvider).trashTag(t.id);
    if (ref.read(homeProvider).view == NoteView.tag(t.id)) _select(NoteView.all);
  }

  Widget _menu(List<(String, VoidCallback?)> entries) {
    return PopupMenuButton<int>(
      tooltip: 'Diğer işlemler',
      iconSize: 18,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz),
      itemBuilder: (_) => [
        for (var i = 0; i < entries.length; i++)
          if (entries[i].$2 != null)
            PopupMenuItem(value: i, child: Text(entries[i].$1)),
      ],
      onSelected: (i) => entries[i].$2?.call(),
    );
  }
}

/// Sol paneldeki tek satır: görünüm, klasör ya da etiket.
class _NavRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final bool selected;
  final bool highlighted;
  final double indent;
  final Widget? leading;
  final Widget? menu;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconColor,
    this.highlighted = false,
    this.indent = 0,
    this.leading,
    this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = selected || highlighted ? scheme.primaryContainer : null;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: bg ?? Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Row(children: [
              SizedBox(width: 8 + indent),
              if (leading != null) leading!,
              if (leading != null) const SizedBox(width: 2),
              Icon(icon, size: 20, color: iconColor ?? fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (menu != null) menu! else const SizedBox(width: 8),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final String addTooltip;
  final VoidCallback onAdd;

  const _SectionHeader({
    required this.label,
    required this.addTooltip,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 0, 4),
      child: Row(children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          tooltip: addTooltip,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: onAdd,
          icon: const Icon(Icons.add),
        ),
      ]),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
