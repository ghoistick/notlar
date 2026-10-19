import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';
import '../common/format.dart';
import '../common/note_colors.dart';
import 'home_state.dart';
import 'note_actions.dart';

/// Not editörü (şimdilik sade metin; canlı biçimlenen editör sonraki adımda).
///
/// Yazılanlar 600 ms durakladıktan sonra otomatik kaydedilir. Not
/// değiştirildiğinde, editör kapandığında ve uygulama kilitlenmeden önce
/// bekleyen kayıt hemen yazılır.
class EditorPane extends ConsumerStatefulWidget {
  final String noteId;
  const EditorPane({super.key, required this.noteId});

  @override
  ConsumerState<EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends ConsumerState<EditorPane> {
  static const _saveDelay = Duration(milliseconds: 600);

  final _title = TextEditingController();
  final _body = TextEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();

  late final NotesRepository _repo;
  Timer? _saveTimer;
  bool _loaded = false;
  bool _dirty = false;
  String _savedTitle = '';
  String _savedBody = '';

  @override
  void initState() {
    super.initState();
    _repo = ref.read(repositoryProvider);
    pendingEditorSaves.add(_flush);
    _load();
  }

  Future<void> _load() async {
    final note = await _repo.getNote(widget.noteId);
    if (!mounted || note == null) return;
    _savedTitle = note.title;
    _savedBody = note.body;
    _title.text = note.title;
    _body.text = note.body;
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
    setState(() => _loaded = true);

    // Yeni, boş not açıldıysa doğrudan başlığa odaklan.
    if (note.title.isEmpty && note.body.isEmpty && note.deletedAt == null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _titleFocus.requestFocus());
    }
  }

  void _onChanged() {
    if (_title.text == _savedTitle && _body.text == _savedBody) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _flush);
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    final title = _title.text;
    final body = _body.text;
    try {
      await _repo.updateNote(
          widget.noteId, NoteChanges(title: Value(title), body: Value(body)));
      _savedTitle = title;
      _savedBody = body;
    } catch (_) {
      // Veritabanı kapanmışsa (kilitleme sırasında) sessizce geç.
      _dirty = true;
    }
  }

  @override
  void dispose() {
    pendingEditorSaves.remove(_flush);
    _flush();
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = ref.watch(noteProvider(widget.noteId)).when(
        data: (n) => n, loading: () => null, error: (_, __) => null);

    if (!_loaded || note == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final readOnly = note.deletedAt != null;
    final tint = tintFor(context, note.color);

    return Material(
      color: tint ?? theme.colorScheme.surface,
      child: Column(children: [
        if (readOnly) _TrashBanner(note: note) else _Toolbar(note: note),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                child: Column(children: [
                  TextField(
                    controller: _title,
                    focusNode: _titleFocus,
                    readOnly: readOnly,
                    style: theme.textTheme.headlineSmall,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _bodyFocus.requestFocus(),
                    decoration: InputDecoration.collapsed(
                      hintText: note.kind == NoteKind.snippet
                          ? 'Başlık (isteğe bağlı)'
                          : 'Başlık',
                    ),
                  ),
                  const SizedBox(height: 4),
                  _TagLine(noteId: note.id),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TextField(
                      controller: _body,
                      focusNode: _bodyFocus,
                      readOnly: readOnly,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
                      decoration: const InputDecoration.collapsed(
                          hintText: 'Yazmaya başla…'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        _Footer(note: note),
      ]),
    );
  }
}

class _Toolbar extends ConsumerWidget {
  final Note note;
  const _Toolbar({required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final folderName = note.folderId == null
        ? null
        : ref.watch(foldersProvider).when(
            data: (fs) =>
                fs.where((f) => f.id == note.folderId).firstOrNull?.name,
            loading: () => null,
            error: (_, __) => null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
      child: Row(children: [
        if (folderName != null) ...[
          Icon(Icons.folder_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(folderName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
        const Spacer(),
        IconButton(
          tooltip: note.pinned ? 'Sabitlemeyi kaldır' : 'Sabitle',
          isSelected: note.pinned,
          icon: const Icon(Icons.push_pin_outlined),
          selectedIcon: const Icon(Icons.push_pin),
          onPressed: () => togglePin(ref, note),
        ),
        IconButton(
          tooltip: 'Etiketler',
          icon: const Icon(Icons.label_outline),
          onPressed: () => editNoteTagsDialog(context, ref, note.id),
        ),
        IconButton(
          tooltip: 'Renk',
          icon: Icon(Icons.palette_outlined,
              color: noteColorFor(note.color)?.swatch),
          onPressed: () => pickNoteColor(context, ref, note),
        ),
        Builder(
          builder: (btnContext) => IconButton(
            tooltip: 'Diğer işlemler',
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              final box = btnContext.findRenderObject() as RenderBox;
              final pos = box.localToGlobal(box.size.bottomLeft(Offset.zero));
              showNoteMoreMenu(context, ref, note, pos);
            },
          ),
        ),
      ]),
    );
  }
}

class _TagLine extends ConsumerWidget {
  final String noteId;
  const _TagLine({required this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(noteTagsProvider(noteId)).when(
        data: (t) => t, loading: () => <Tag>[], error: (_, __) => <Tag>[]);
    if (tags.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final t in tags)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => editNoteTagsDialog(context, ref, noteId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.label_outline,
                      size: 13,
                      color: noteColorFor(t.color)?.swatch ??
                          scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(t.name, style: Theme.of(context).textTheme.labelMedium),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrashBanner extends ConsumerWidget {
  final Note note;
  const _TrashBanner({required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Row(children: [
        Expanded(
          child: Text('Bu not çöp kutusunda. Düzenlemek için geri yükle.',
              style: TextStyle(color: scheme.onPrimaryContainer)),
        ),
        TextButton(
          onPressed: () => ref.read(repositoryProvider).restoreNote(note.id),
          child: const Text('Geri yükle'),
        ),
      ]),
    );
  }
}

class _Footer extends StatelessWidget {
  final Note note;
  const _Footer({required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      child: Row(children: [
        const Spacer(),
        Text(
          'Son düzenleme ${formatLongDate(note.updatedAt)}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// Hiç not seçili değilken sağ panel.
class EmptyEditor extends ConsumerWidget {
  const EmptyEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.edit_note, size: 44, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('Bir not seç ya da yeni bir not oluştur.',
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => createNoteInView(context, ref),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Yeni not'),
          ),
        ]),
      ),
    );
  }
}

/// Telefonda editör ayrı sayfa olarak açılır.
class EditorPage extends ConsumerWidget {
  final String noteId;
  const EditorPage({super.key, required this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Not çöpe atılır ya da arşivlenirse sayfa kapanır.
    ref.listen(homeProvider.select((s) => s.selectedNoteId), (_, id) {
      if (id != noteId && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && ref.read(homeProvider).selectedNoteId == noteId) {
          ref.read(homeProvider.notifier).select(null);
        }
      },
      child: Scaffold(
        appBar: AppBar(toolbarHeight: 44),
        body: SafeArea(top: false, child: EditorPane(noteId: noteId)),
      ),
    );
  }
}
