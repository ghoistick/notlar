import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/text/checklist.dart';

/// Liste notlarının (type = checklist) düzenleme görünümü.
///
/// Gövde metni [initialText] ile bir kez okunur; her değişiklikte yeni gövde
/// [onChanged] ile bildirilir (kaydetme editördeki olağan yoldan yapılır).
/// Not açılınca gövdeye dokunulmaz; ilk düzenlemede maddeler
/// "- [ ] / - [x]" satırları olarak yeniden yazılır.
///
///  - Enter imlecin olduğu yerden yeni madde açar; çok satırlı yapıştırma
///    her satırı ayrı madde yapar.
///  - Başında Backspace: boş maddeyi siler, dolu maddeyi öncekiyle birleştirir.
///  - Yukarı/aşağı ok, maddenin başında/sonunda bir önceki/sonraki maddeye geçer.
///  - İşaretsiz maddeler tutamaçtan sürüklenerek sıralanır.
///  - İşaretlenenler altta, katlanır "İşaretlenenler (n)" bölümünde durur.
class ChecklistView extends StatefulWidget {
  final String initialText;
  final bool readOnly;
  final ValueChanged<String> onChanged;

  const ChecklistView({
    super.key,
    required this.initialText,
    required this.onChanged,
    this.readOnly = false,
  });

  @override
  State<ChecklistView> createState() => _ChecklistViewState();
}

class _Row {
  static int _nextId = 0;

  /// Sıralama ve odak için kalıcı kimlik (gövdede saklanmaz).
  final int id = _nextId++;
  final TextEditingController ctrl;
  late final FocusNode focus;
  bool checked;

  _Row(String text, this.checked) : ctrl = TextEditingController(text: text);

  ChecklistEntry get entry => ChecklistEntry(ctrl.text, checked: checked);

  void dispose() {
    ctrl.dispose();
    focus.dispose();
  }
}

class _ChecklistViewState extends State<ChecklistView> {
  final _rows = <_Row>[];
  late String _lastEmitted;
  bool _checkedOpen = true;

  @override
  void initState() {
    super.initState();
    final entries = Checklist.parse(widget.initialText);
    for (final e in entries) {
      _rows.add(_newRow(e.text, e.checked));
    }

    // Boş liste: ilk madde hazır ve odakta gelsin.
    if (_rows.isEmpty && !widget.readOnly) {
      final r = _newRow('', false);
      _rows.add(r);
      _focus(r, 0);
    }

    // Açılıştaki hal "bildirilmiş" sayılır: yalnızca imleç gezdirmek ya da
    // boş maddenin eklenmesi notu değiştirmez, ilk gerçek düzenlemede yazılır.
    _lastEmitted = Checklist.format(_rows.map((r) => r.entry));
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ Satırlar

  _Row _newRow(String text, bool checked) {
    final r = _Row(text, checked);
    r.focus = FocusNode(onKeyEvent: (_, e) => _onKey(r, e));
    r.ctrl.addListener(_emit);
    return r;
  }

  List<_Row> get _unchecked => _rows.where((r) => !r.checked).toList();
  List<_Row> get _checked => _rows.where((r) => r.checked).toList();

  /// Ekranda görünen sıra: işaretsizler, sonra (açıksa) işaretliler.
  List<_Row> get _visible =>
      [..._unchecked, if (_checkedOpen) ..._checked];

  void _emit() {
    final s = Checklist.format(_rows.map((r) => r.entry));
    if (s == _lastEmitted) return;
    _lastEmitted = s;
    widget.onChanged(s);
  }

  /// Satır çizildikten sonra odaklanır ve imleci [offset]e koyar
  /// (null: satır sonu).
  void _focus(_Row r, int? offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_rows.contains(r)) return;
      r.focus.requestFocus();
      final len = r.ctrl.text.length;
      r.ctrl.selection =
          TextSelection.collapsed(offset: min(offset ?? len, len));
    });
  }

  /// Satırı listeden çıkarır; odak düğümü bir kare sonra bırakılır.
  void _drop(_Row r) {
    _rows.remove(r);
    WidgetsBinding.instance.addPostFrameCallback((_) => r.dispose());
  }

  /// Enter ya da çok satırlı yapıştırma: [value] satırlara bölünür; ilk
  /// parça maddede kalır, kalanlar hemen altına yeni madde olarak eklenir.
  void _split(_Row r, TextEditingValue value) {
    if (!_rows.contains(r)) return;
    final parts = value.text.split('\n');
    final lastStart = value.text.lastIndexOf('\n') + 1;
    final caret = max(0, value.selection.baseOffset - lastStart);

    final added = [for (final p in parts.skip(1)) _newRow(p, false)];
    setState(() => _rows.insertAll(_rows.indexOf(r) + 1, added));
    _emit();
    _focus(added.last, caret);
  }

  void _add() {
    final r = _newRow('', false);
    setState(() => _rows.add(r));
    _emit();
    _focus(r, 0);
  }

  void _remove(_Row r) {
    final vis = _visible;
    final i = vis.indexOf(r);
    final next = i > 0
        ? vis[i - 1]
        : (i + 1 < vis.length ? vis[i + 1] : null);
    setState(() => _drop(r));
    _emit();
    if (next != null) _focus(next, null);
  }

  void _toggle(_Row r) {
    setState(() => r.checked = !r.checked);
    _emit();
  }

  /// Başında Backspace: boşsa sil, doluysa bir önceki maddeye ekle.
  bool _mergeIntoPrevious(_Row r) {
    final vis = _visible;
    final i = vis.indexOf(r);
    if (i <= 0) return false;
    final prev = vis[i - 1];
    final joinAt = prev.ctrl.text.length;
    if (r.ctrl.text.isNotEmpty) {
      prev.ctrl.text = prev.ctrl.text + r.ctrl.text;
    }
    setState(() => _drop(r));
    _emit();
    _focus(prev, joinAt);
    return true;
  }

  KeyEventResult _onKey(_Row r, KeyEvent e) {
    if (widget.readOnly) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed || kb.isControlPressed || kb.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final sel = r.ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return KeyEventResult.ignored;
    final atStart = sel.baseOffset == 0;
    final atEnd = sel.baseOffset == r.ctrl.text.length;
    final vis = _visible;
    final i = vis.indexOf(r);

    if (e.logicalKey == LogicalKeyboardKey.backspace && atStart) {
      return _mergeIntoPrevious(r)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp && atStart && i > 0) {
      _focus(vis[i - 1], null);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown &&
        atEnd &&
        i >= 0 &&
        i + 1 < vis.length) {
      _focus(vis[i + 1], 0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// İşaretsizlerin yeni sırası, gövdedeki işaretsiz yuvalara sırayla
  /// yerleştirilir; işaretli maddeler yerinden oynamaz.
  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final u = _unchecked;
    u.insert(newIndex, u.removeAt(oldIndex));
    var k = 0;
    setState(() {
      for (var i = 0; i < _rows.length; i++) {
        if (!_rows[i].checked) _rows[i] = u[k++];
      }
    });
    _emit();
  }

  void _uncheckAll() {
    setState(() {
      for (final r in _rows) {
        r.checked = false;
      }
    });
    _emit();
  }

  Future<void> _deleteChecked() async {
    final n = _checked.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('İşaretlenenleri sil'),
        content: Text('$n işaretli madde silinecek. Gerekirse sürüm '
            'geçmişinden geri alabilirsin.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      for (final r in _checked) {
        _drop(r);
      }
    });
    _emit();
  }

  // ------------------------------------------------------------- Görünüm

  @override
  Widget build(BuildContext context) {
    final unchecked = _unchecked;
    final checked = _checked;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;

    return CustomScrollView(slivers: [
      SliverReorderableList(
        itemCount: unchecked.length,
        onReorder: _reorder,
        proxyDecorator: (child, _, __) => Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(6),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: child,
        ),
        itemBuilder: (context, i) =>
            _ItemRow(key: ValueKey(unchecked[i].id), state: this,
                row: unchecked[i], reorderIndex: i),
      ),
      if (!widget.readOnly)
        SliverToBoxAdapter(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _add,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 8, 8),
              child: Row(children: [
                Icon(Icons.add, size: 20, color: muted),
                const SizedBox(width: 14),
                Text('Liste öğesi', style: TextStyle(color: muted)),
              ]),
            ),
          ),
        ),
      if (checked.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(children: [
              const Divider(height: 1),
              Row(children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() => _checkedOpen = !_checkedOpen),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 10),
                      child: Row(children: [
                        Icon(
                            _checkedOpen
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 20,
                            color: muted),
                        const SizedBox(width: 6),
                        Text('İşaretlenenler (${checked.length})',
                            style: TextStyle(color: muted)),
                      ]),
                    ),
                  ),
                ),
                if (!widget.readOnly)
                  PopupMenuButton<String>(
                    tooltip: 'Liste işlemleri',
                    icon: Icon(Icons.more_horiz, color: muted),
                    onSelected: (v) => switch (v) {
                      'uncheck' => _uncheckAll(),
                      'delete' => _deleteChecked(),
                      _ => null,
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'uncheck',
                          child: Text('Tüm işaretleri kaldır')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('İşaretlenenleri sil')),
                    ],
                  ),
              ]),
            ]),
          ),
        ),
      if (_checkedOpen)
        SliverList.builder(
          itemCount: checked.length,
          itemBuilder: (context, i) => _ItemRow(
              key: ValueKey(checked[i].id), state: this, row: checked[i]),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 80)),
    ]);
  }
}

/// Tek madde: tutamaç, onay kutusu, metin ve (odaktayken) silme düğmesi.
class _ItemRow extends StatelessWidget {
  final _ChecklistViewState state;
  final _Row row;

  /// İşaretsiz listedeki sırası; işaretlilerde null (sürüklenmez).
  final int? reorderIndex;

  const _ItemRow({
    super.key,
    required this.state,
    required this.row,
    this.reorderIndex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final readOnly = state.widget.readOnly;
    final base = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
    final style = row.checked
        ? base?.copyWith(
            color: muted,
            decoration: TextDecoration.lineThrough,
            decorationColor: muted)
        : base;

    final handle = reorderIndex != null && !readOnly
        ? ReorderableDragStartListener(
            index: reorderIndex!,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Icon(Icons.drag_indicator, size: 18, color: muted),
              ),
            ),
          )
        : const SizedBox(width: 18);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        handle,
        Checkbox(
          value: row.checked,
          onChanged: readOnly ? null : (_) => state._toggle(row),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: TextField(
              controller: row.ctrl,
              focusNode: row.focus,
              readOnly: readOnly,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              inputFormatters: [
                _NewlineSplitter((v) => state._split(row, v)),
              ],
              style: style,
              decoration:
                  const InputDecoration.collapsed(hintText: 'Liste öğesi'),
            ),
          ),
        ),
        // Odaktayken silme düğmesi. TextFieldTapRegion: düğmeye tıklamak
        // metin alanının odağını kapatmasın (yoksa düğme tıklanmadan kaybolur).
        ListenableBuilder(
          listenable: row.focus,
          builder: (context, _) => row.focus.hasFocus && !readOnly
              ? TextFieldTapRegion(
                  child: ExcludeFocus(
                    child: IconButton(
                      tooltip: 'Öğeyi sil',
                      icon: Icon(Icons.close, size: 18, color: muted),
                      onPressed: () => state._remove(row),
                    ),
                  ),
                )
              : const SizedBox(width: 40),
        ),
      ]),
    );
  }
}

/// Satır sonlarını maddede tutmaz: ilk satır maddede kalır, tamamı
/// [onSplit] ile bölünmek üzere bildirilir.
class _NewlineSplitter extends TextInputFormatter {
  final void Function(TextEditingValue value) onSplit;
  _NewlineSplitter(this.onSplit);

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final i = newValue.text.indexOf('\n');
    if (i < 0) return newValue;
    // Biçimlendirici bittikten sonra bölünür (denetleyici o sırada güncel).
    scheduleMicrotask(() => onSplit(newValue));
    final first = newValue.text.substring(0, i);
    return TextEditingValue(
      text: first,
      selection: TextSelection.collapsed(offset: first.length),
    );
  }
}
