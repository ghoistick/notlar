import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';
import '../common/format.dart';
import '../common/note_colors.dart';
import '../editor/format_toolbar.dart';
import '../editor/markdown_controller.dart';
import 'home_state.dart';
import 'note_actions.dart';

/// Not editörü.
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

  /// Bu genişliğin üzerinde içindekiler paneli yan tarafta açılır.
  static const _sideTocMinWidth = 900.0;

  final _title = TextEditingController();
  final _body = MarkdownEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  final _find = TextEditingController();
  final _findFocus = FocusNode();

  late final NotesRepository _repo;
  Timer? _saveTimer;
  bool _loaded = false;
  bool _dirty = false;
  String _savedTitle = '';
  String _savedBody = '';

  bool _tocOpen = true;
  bool _sideTocAvailable = true;

  bool _findOpen = false;
  List<TextRange> _matches = const [];
  int _current = -1;
  String? _lastFindText;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(repositoryProvider);
    pendingEditorSaves.add(_flush);
    _bodyFocus.addListener(_onBodyFocus);
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

    if (note.title.isEmpty && note.body.isEmpty && note.deletedAt == null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _titleFocus.requestFocus());
    }
  }

  void _onBodyFocus() => _body.setFocused(_bodyFocus.hasFocus);

  void _onChanged() {
    // Metin değiştiyse not içi arama sonuçlarını güncelle.
    if (_findOpen && _body.text != _lastFindText) _runFind(reveal: false);

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
      _dirty = true; // veritabanı kapanmışsa (kilitleme sırasında)
    }
  }

  @override
  void dispose() {
    pendingEditorSaves.remove(_flush);
    _bodyFocus.removeListener(_onBodyFocus);
    _flush();
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _find.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ Yardımcılar

  /// Metindeki bir konumu görünür alana kaydırır (editör odakta olmasa da).
  void _bringIntoView(int offset) {
    final ctx = _bodyFocus.context;
    final editable = ctx?.findAncestorStateOfType<EditableTextState>();
    editable?.bringIntoView(TextPosition(offset: offset));
  }

  void _onBodyTap() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sel = _body.selection;
      if (sel.isValid && sel.isCollapsed) _body.toggleCheckboxAt(sel.baseOffset);
    });
  }

  Map<ShortcutActivator, VoidCallback> get _formatShortcuts => {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _body.wrapSelection('**'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _body.wrapSelection('*'),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _body.toggleCheckboxOnCurrentLine,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            _body.toggleHeading(1),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            _body.toggleHeading(2),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
            _body.toggleHeading(3),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            _body.toggleHeading(0),
      };

  Map<ShortcutActivator, VoidCallback> get _editorShortcuts => {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openFind,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_findOpen) _closeFind();
        },
        const SingleActivator(LogicalKeyboardKey.period, control: true):
            _body.toggleFoldAtCaret,
      };

  // ------------------------------------------------------- İçindekiler

  void _toggleToc() {
    if (_sideTocAvailable) {
      setState(() => _tocOpen = !_tocOpen);
    } else {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SizedBox(
          height: 420,
          child: _tocPanel(afterJump: () => Navigator.of(ctx).pop()),
        ),
      );
    }
  }

  void _jumpTo(HeadingRef h) {
    _body.selection = TextSelection.collapsed(offset: h.lineEnd);
    _bodyFocus.requestFocus();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _bringIntoView(h.lineStart));
  }

  Widget _tocPanel({VoidCallback? afterJump}) {
    return ListenableBuilder(
      listenable: _body,
      builder: (context, _) {
        final refs = _body.headingRefs();
        final line = _body.caretLine;
        String? activeKey;
        if (line != null) {
          for (final r in refs) {
            if (r.lineIndex <= line) activeKey = r.key;
          }
        }
        return _TocPanel(
          headings: refs,
          isFolded: _body.isFolded,
          activeKey: activeKey,
          onJump: (h) {
            afterJump?.call();
            _jumpTo(h);
          },
          onToggleFold: _body.toggleFold,
          onFoldAll: _body.foldAll,
          onUnfoldAll: _body.unfoldAll,
        );
      },
    );
  }

  // -------------------------------------------------------- Not içi arama

  void _openFind() {
    final sel = _body.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final s = _body.text.substring(sel.start, sel.end);
      if (!s.contains('\n') && s.length <= 80) _find.text = s;
    }
    setState(() => _findOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocus.requestFocus();
      _find.selection =
          TextSelection(baseOffset: 0, extentOffset: _find.text.length);
      _runFind();
    });
  }

  void _closeFind() {
    setState(() {
      _findOpen = false;
      _matches = const [];
      _current = -1;
    });
    _body.setSearchMatches(const [], -1);
    _bodyFocus.requestFocus();
  }

  void _runFind({bool reveal = true}) {
    _lastFindText = _body.text;
    final matches = MarkdownEditingController.findAll(_body.text, _find.text);

    var current = -1;
    if (matches.isNotEmpty) {
      if (!reveal && _current >= 0) {
        current = min(_current, matches.length - 1);
      } else {
        final from = _body.selection.isValid ? _body.selection.start : 0;
        current = matches.indexWhere((m) => m.start >= from);
        if (current < 0) current = 0;
      }
    }
    setState(() {
      _matches = matches;
      _current = current;
    });
    _body.setSearchMatches(matches, current);
    if (reveal && current >= 0) _reveal(current);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    final next = (_current + delta) % _matches.length;
    setState(() => _current = next);
    _body.setSearchMatches(_matches, next);
    _reveal(next);
  }

  void _reveal(int i) {
    final m = _matches[i];
    // Seçim katlanmış bir bölümdeyse denetleyici o bölümü açar.
    _body.selection = TextSelection(baseOffset: m.start, extentOffset: m.end);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bringIntoView(m.start));
  }

  Widget _findBar(ThemeData theme) {
    final status = _matches.isEmpty
        ? (_find.text.isEmpty ? '' : 'Sonuç yok')
        : '${_current + 1}/${_matches.length}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
                  _step(-1),
              const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
            },
            child: TextField(
              controller: _find,
              focusNode: _findFocus,
              onChanged: (_) => _runFind(),
              onSubmitted: (_) => _step(1),
              onEditingComplete: () {}, // Enter odağı kaybettirmesin
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Notta ara',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 64,
          child: Text(status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        IconButton(
          tooltip: 'Önceki (Shift+Enter)',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: _matches.isEmpty ? null : () => _step(-1),
        ),
        IconButton(
          tooltip: 'Sonraki (Enter)',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: _matches.isEmpty ? null : () => _step(1),
        ),
        IconButton(
          tooltip: 'Kapat (Esc)',
          icon: const Icon(Icons.close, size: 20),
          onPressed: _closeFind,
        ),
      ]),
    );
  }

  // ----------------------------------------------------------------- Görünüm

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
    _body.theme = MarkdownTheme.of(context);

    return Material(
      color: tint ?? theme.colorScheme.surface,
      child: CallbackShortcuts(
        bindings: _editorShortcuts,
        child: Column(children: [
          if (readOnly)
            _TrashBanner(note: note)
          else
            _Toolbar(
              note: note,
              tocOpen: _tocOpen && _sideTocAvailable,
              onToggleToc: _toggleToc,
              onFind: _openFind,
            ),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              _sideTocAvailable = c.maxWidth >= _sideTocMinWidth;
              final showSide = _sideTocAvailable && _tocOpen;
              return Row(children: [
                Expanded(child: _content(theme, note, readOnly)),
                if (showSide) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(width: 240, child: _tocPanel()),
                ],
              ]);
            }),
          ),
          _Footer(note: note),
        ]),
      ),
    );
  }

  Widget _content(ThemeData theme, Note note, bool readOnly) {
    return Align(
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
            if (!readOnly) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: FormatToolbar(
                  controller: _body,
                  onDone: _bodyFocus.requestFocus,
                ),
              ),
            ],
            if (_findOpen) _findBar(theme),
            const SizedBox(height: 6),
            const Divider(),
            const SizedBox(height: 10),
            Expanded(
              child: CallbackShortcuts(
                bindings: readOnly ? const {} : _formatShortcuts,
                child: TextField(
                  controller: _body,
                  focusNode: _bodyFocus,
                  readOnly: readOnly,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  inputFormatters: [ListContinuationFormatter()],
                  onTap: readOnly ? null : _onBodyTap,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
                  decoration: const InputDecoration.collapsed(
                      hintText: 'Yazmaya başla…'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// --------------------------------------------------------- İçindekiler paneli

class _TocPanel extends StatelessWidget {
  final List<HeadingRef> headings;
  final bool Function(String key) isFolded;
  final String? activeKey;
  final ValueChanged<HeadingRef> onJump;
  final ValueChanged<String> onToggleFold;
  final VoidCallback onFoldAll;
  final VoidCallback onUnfoldAll;

  const _TocPanel({
    required this.headings,
    required this.isFolded,
    required this.activeKey,
    required this.onJump,
    required this.onToggleFold,
    required this.onFoldAll,
    required this.onUnfoldAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 4),
        child: Row(children: [
          Expanded(
            child: Text('İçindekiler',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Tümünü daralt',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: headings.isEmpty ? null : onFoldAll,
            icon: const Icon(Icons.unfold_less),
          ),
          IconButton(
            tooltip: 'Tümünü genişlet',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: headings.isEmpty ? null : onUnfoldAll,
            icon: const Icon(Icons.unfold_more),
          ),
        ]),
      ),
      Expanded(
        child: headings.isEmpty
            ? Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  'Bu notta başlık yok. # ile başlayan satırlar burada '
                  'listelenir.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final h in headings)
                    _TocItem(
                      heading: h,
                      folded: isFolded(h.key),
                      active: h.key == activeKey,
                      onJump: () => onJump(h),
                      onToggle: () => onToggleFold(h.key),
                    ),
                ],
              ),
      ),
    ]);
  }
}

class _TocItem extends StatelessWidget {
  final HeadingRef heading;
  final bool folded;
  final bool active;
  final VoidCallback onJump;
  final VoidCallback onToggle;

  const _TocItem({
    required this.heading,
    required this.folded,
    required this.active,
    required this.onJump,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = heading.title.isEmpty ? 'Başlıksız bölüm' : heading.title;

    return InkWell(
      onTap: onJump,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4 + (heading.level - 1) * 14.0, 3, 12, 3),
        child: Row(children: [
          SizedBox(
            width: 28,
            child: heading.foldable
                ? IconButton(
                    tooltip: folded ? 'Bölümü aç' : 'Bölümü daralt (Ctrl+.)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    onPressed: onToggle,
                    icon: Icon(folded ? Icons.chevron_right : Icons.expand_more),
                  )
                : null,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: active ? scheme.primary : null,
                fontWeight: active || heading.level == 1
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------- Araç çubuğu

class _Toolbar extends ConsumerWidget {
  final Note note;
  final bool tocOpen;
  final VoidCallback onToggleToc;
  final VoidCallback onFind;

  const _Toolbar({
    required this.note,
    required this.tocOpen,
    required this.onToggleToc,
    required this.onFind,
  });

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
          tooltip: 'Notta ara (Ctrl+F)',
          icon: const Icon(Icons.find_in_page_outlined),
          onPressed: onFind,
        ),
        IconButton(
          tooltip: 'İçindekiler',
          isSelected: tocOpen,
          icon: const Icon(Icons.toc),
          onPressed: onToggleToc,
        ),
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
          tooltip: 'Not rengi',
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
