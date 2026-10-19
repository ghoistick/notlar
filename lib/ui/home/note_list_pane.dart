import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';
import '../common/format.dart';
import '../common/note_colors.dart';
import 'home_state.dart';
import 'note_actions.dart';

/// Orta panel: başlık, arama, sıralama ve notlar.
class NoteListPane extends ConsumerStatefulWidget {
  /// Dar/orta ekranda sol paneli açan menü düğmesi gösterilir.
  final bool showMenuButton;
  const NoteListPane({super.key, this.showMenuButton = false});

  @override
  ConsumerState<NoteListPane> createState() => _NoteListPaneState();
}

class _NoteListPaneState extends ConsumerState<NoteListPane> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    setState(() {}); // temizle düğmesi için
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180),
        () => ref.read(homeProvider.notifier).setSearch(text));
  }

  void _clearSearch() {
    _search.clear();
    _debounce?.cancel();
    ref.read(homeProvider.notifier).setSearch('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = ref.watch(homeProvider);

    // Görünüm değişince arama kutusu da temizlenir.
    ref.listen(homeProvider.select((s) => s.view), (_, __) {
      if (_search.text.isNotEmpty) {
        _search.clear();
        setState(() {});
      }
    });

    final inTrash = home.view.kind == NoteViewKind.trash;

    return Material(
      color: theme.colorScheme.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(children: [
            if (widget.showMenuButton)
              IconButton(
                tooltip: 'Klasörler ve etiketler',
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            else
              const SizedBox(width: 8),
            Expanded(
              child: Text(
                _viewTitle(home.view),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            _SortButton(home: home),
            if (!inTrash) ...[
              IconButton(
                tooltip: 'Yeni kısa not (Ctrl+Shift+N)',
                icon: const Icon(Icons.sticky_note_2_outlined),
                onPressed: () =>
                    createNoteInView(context, ref, kind: NoteKind.snippet),
              ),
              IconButton(
                tooltip: 'Yeni not (Ctrl+N)',
                icon: const Icon(Icons.edit_note),
                onPressed: () => createNoteInView(context, ref),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _search,
            focusNode: ref.watch(searchFocusProvider),
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Ara',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Aramayı temizle',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ),
        const Divider(),
        Expanded(
          child: ref.watch(notesProvider).when(
                data: (notes) => _NoteList(notes: notes, home: home),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Notlar yüklenemedi: $e'),
                  ),
                ),
              ),
        ),
      ]),
    );
  }

  String _viewTitle(NoteView view) {
    switch (view.kind) {
      case NoteViewKind.all:
        return 'Tüm notlar';
      case NoteViewKind.snippets:
        return 'Kısa notlar';
      case NoteViewKind.archive:
        return 'Arşiv';
      case NoteViewKind.trash:
        return 'Çöp kutusu';
      case NoteViewKind.folder:
        final folders = ref.watch(foldersProvider).when(
            data: (d) => d, loading: () => <Folder>[], error: (_, __) => <Folder>[]);
        return folders.where((f) => f.id == view.id).firstOrNull?.name ??
            'Klasör';
      case NoteViewKind.tag:
        final tags = ref.watch(tagsProvider).when(
            data: (d) => d, loading: () => <Tag>[], error: (_, __) => <Tag>[]);
        return tags.where((t) => t.id == view.id).firstOrNull?.name ??
            'Etiket';
    }
  }
}

// ------------------------------------------------------------------ Sıralama

class _SortButton extends ConsumerWidget {
  final HomeState home;
  const _SortButton({required this.home});

  static const _labels = {
    NoteSort.updatedAt: 'Değiştirme tarihi',
    NoteSort.createdAt: 'Oluşturma tarihi',
    NoteSort.title: 'Başlık',
    NoteSort.size: 'Boyut',
    NoteSort.color: 'Renk',
    NoteSort.tag: 'Etiket',
    NoteSort.relevance: 'En iyi eşleşme',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = [
      if (home.searching) NoteSort.relevance,
      NoteSort.updatedAt,
      NoteSort.createdAt,
      NoteSort.title,
      NoteSort.size,
      NoteSort.color,
      NoteSort.tag,
    ];
    final hasDirection = home.sort != NoteSort.relevance;

    return PopupMenuButton<Object>(
      tooltip: 'Sırala: ${_labels[home.sort]}',
      icon: const Icon(Icons.sort),
      itemBuilder: (_) => [
        for (final s in options)
          CheckedPopupMenuItem<Object>(
            value: s,
            checked: home.sort == s,
            child: Text(_labels[s]!),
          ),
        if (hasDirection) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(
            value: false,
            checked: !home.descending,
            child: Text(_directionLabel(home.sort, false)),
          ),
          CheckedPopupMenuItem<Object>(
            value: true,
            checked: home.descending,
            child: Text(_directionLabel(home.sort, true)),
          ),
        ],
      ],
      onSelected: (v) {
        final c = ref.read(homeProvider.notifier);
        if (v is NoteSort) {
          // Başlık ve etiket için doğal yön A→Z, diğerleri için en yeni/büyük önce.
          final natural = !(v == NoteSort.title || v == NoteSort.tag ||
              v == NoteSort.color || v == NoteSort.relevance);
          c.setSort(v, v == home.sort ? home.descending : natural);
        } else if (v is bool) {
          c.setSort(home.sort, v);
        }
      },
    );
  }

  static String _directionLabel(NoteSort sort, bool descending) {
    switch (sort) {
      case NoteSort.updatedAt:
      case NoteSort.createdAt:
        return descending ? 'En yeni önce' : 'En eski önce';
      case NoteSort.size:
        return descending ? 'En büyük önce' : 'En küçük önce';
      default:
        return descending ? 'Z → A' : 'A → Z';
    }
  }
}

// --------------------------------------------------------------------- Liste

class _NoteList extends ConsumerWidget {
  final List<Note> notes;
  final HomeState home;
  const _NoteList({required this.notes, required this.home});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (notes.isEmpty) return _EmptyList(home: home);

    final headings = ref.watch(headingSummariesProvider).when(
        data: (d) => d,
        loading: () => const <String, List<String>>{},
        error: (_, __) => const <String, List<String>>{});

    // Kısa notlar görünümü: kart ızgarası.
    if (home.view.kind == NoteViewKind.snippets) {
      return GridView.extent(
        padding: const EdgeInsets.all(12),
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.15,
        children: [
          for (final n in notes)
            _SnippetCard(note: n, selected: n.id == home.selectedNoteId),
        ],
      );
    }

    // Klasör görünümü: üstte kısa not kartları, altında notlar.
    if (home.view.kind == NoteViewKind.folder) {
      final snippets = notes.where((n) => n.kind == NoteKind.snippet).toList();
      final regular = notes.where((n) => n.kind != NoteKind.snippet).toList();
      return ListView(
        children: [
          if (snippets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: LayoutBuilder(builder: (context, c) {
                final cardWidth = c.maxWidth >= 300
                    ? (c.maxWidth - 8) / 2
                    : c.maxWidth;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final n in snippets)
                      SizedBox(
                        width: cardWidth,
                        height: 110,
                        child: _SnippetCard(
                            note: n, selected: n.id == home.selectedNoteId),
                      ),
                  ],
                );
              }),
            ),
          for (final n in regular)
            _NoteTile(
              note: n,
              headings: headings[n.id] ?? const [],
              selected: n.id == home.selectedNoteId,
            ),
        ],
      );
    }

    return ListView.builder(
      itemCount: notes.length,
      itemBuilder: (context, i) {
        final n = notes[i];
        return _NoteTile(
          note: n,
          headings: headings[n.id] ?? const [],
          selected: n.id == home.selectedNoteId,
        );
      },
    );
  }
}

/// Masaüstünde sürüklenebilir (klasöre bırakmak için), sağ tık ve uzun
/// basmada menü açan sarmalayıcı.
class _NoteInteraction extends ConsumerWidget {
  final Note note;
  final Widget child;
  final Widget dragFeedback;

  const _NoteInteraction({
    required this.note,
    required this.child,
    required this.dragFeedback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactive = GestureDetector(
      onSecondaryTapDown: (d) =>
          showNoteMenu(context, ref, note, d.globalPosition),
      onLongPressStart: (d) =>
          showNoteMenu(context, ref, note, d.globalPosition),
      child: child,
    );
    if (isNarrow(context) || note.deletedAt != null) return interactive;

    return Draggable<String>(
      data: note.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: dragFeedback,
      child: interactive,
    );
  }
}

class _NoteTile extends ConsumerWidget {
  final Note note;
  final List<String> headings;
  final bool selected;

  const _NoteTile({
    required this.note,
    required this.headings,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = noteColorFor(note.color);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant, height: 1.35);
    final title = note.title.trim().isEmpty ? 'Başlıksız' : note.title;
    final preview = notePreview(note.body);

    final tile = Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      child: InkWell(
        onTap: () => openNote(context, ref, note.id),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                  color: color?.swatch ?? Colors.transparent, width: 3),
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(13, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                if (note.kind == NoteKind.snippet) ...[
                  Icon(Icons.sticky_note_2_outlined,
                      size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: note.title.trim().isEmpty
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
                if (note.pinned)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.push_pin,
                        size: 14, color: scheme.primary),
                  ),
                const SizedBox(width: 8),
                Text(formatShortDate(note.updatedAt), style: muted),
              ]),
              if (headings.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1, right: 6),
                      child: Icon(Icons.toc,
                          size: 15, color: scheme.onSurfaceVariant),
                    ),
                    Expanded(
                      child: Text(
                        headings.join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ] else if (preview.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(preview,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
              ],
            ],
          ),
        ),
      ),
    );

    return _NoteInteraction(
      note: note,
      dragFeedback: _DragChip(label: title),
      child: tile,
    );
  }
}

class _SnippetCard extends ConsumerWidget {
  final Note note;
  final bool selected;
  const _SnippetCard({required this.note, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = tintFor(context, note.color);
    final title = note.title.trim();
    final body = notePreview(note.body, maxLength: 220);

    final card = Material(
      color: tint ?? scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openNote(context, ref, note.id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty)
                Row(children: [
                  Expanded(
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (note.pinned)
                    Icon(Icons.push_pin, size: 14, color: scheme.primary),
                ]),
              if (title.isNotEmpty && body.isNotEmpty) const SizedBox(height: 4),
              if (body.isNotEmpty)
                Expanded(
                  child: Text(
                    body,
                    overflow: TextOverflow.fade,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              if (title.isEmpty && body.isEmpty)
                Text('Boş kısa not',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );

    return _NoteInteraction(
      note: note,
      dragFeedback: _DragChip(label: title.isEmpty ? 'Kısa not' : title),
      child: card,
    );
  }
}

class _DragChip extends StatelessWidget {
  final String label;
  const _DragChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.description_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(label, overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  final HomeState home;
  const _EmptyList({required this.home});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String text;
    if (home.searching) {
      text = '“${home.search.trim()}” için sonuç yok.';
    } else {
      text = switch (home.view.kind) {
        NoteViewKind.all => 'Henüz not yok. Ctrl+N ile ilk notunu oluştur.',
        NoteViewKind.snippets =>
          'Kısa not yok. Hap bilgileri burada kart olarak tutabilirsin.',
        NoteViewKind.folder => 'Bu klasörde not yok.',
        NoteViewKind.tag => 'Bu etikete sahip not yok.',
        NoteViewKind.archive => 'Arşiv boş.',
        NoteViewKind.trash => 'Çöp kutusu boş.',
      };
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
