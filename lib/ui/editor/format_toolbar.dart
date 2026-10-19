import 'package:flutter/material.dart';

import '../common/dialogs.dart';
import 'markdown_controller.dart';

/// Editörün biçim araç çubuğu.
///
/// Düğmeler odak almaz; tıklandığında imleç ve seçim metinde kalır.
class FormatToolbar extends StatelessWidget {
  final MarkdownEditingController controller;

  /// Her işlemden sonra metne geri odaklanmak için.
  final VoidCallback onDone;

  const FormatToolbar({
    super.key,
    required this.controller,
    required this.onDone,
  });

  void _run(VoidCallback action) {
    action();
    onDone();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget btn(IconData icon, String tooltip, VoidCallback action) => IconButton(
          tooltip: tooltip,
          icon: Icon(icon, size: 20),
          visualDensity: VisualDensity.compact,
          onPressed: () => _run(action),
        );

    Widget gap() => Container(
          width: 1,
          height: 20,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          color: scheme.outlineVariant,
        );

    Future<void> pickColor({required bool highlight}) async {
      final choice = await showColorPicker(
        context,
        title: highlight ? 'Vurgu rengi' : 'Yazı rengi',
      );
      final key = choice?.key;
      if (key == null) {
        onDone();
        return;
      }
      _run(() => controller.applyColor(key, highlight: highlight));
    }

    return ExcludeFocus(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          PopupMenuButton<int>(
            tooltip: 'Başlık',
            icon: const Icon(Icons.title, size: 20),
            onSelected: (level) => _run(() => controller.toggleHeading(level)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 1, child: Text('Başlık 1   (Ctrl+1)')),
              PopupMenuItem(value: 2, child: Text('Başlık 2   (Ctrl+2)')),
              PopupMenuItem(value: 3, child: Text('Başlık 3   (Ctrl+3)')),
              PopupMenuItem(value: 0, child: Text('Normal metin   (Ctrl+0)')),
            ],
          ),
          btn(Icons.format_bold, 'Kalın (Ctrl+B)',
              () => controller.wrapSelection('**')),
          btn(Icons.format_italic, 'İtalik (Ctrl+I)',
              () => controller.wrapSelection('*')),
          btn(Icons.format_strikethrough, 'Üstü çizili',
              () => controller.wrapSelection('~~')),
          btn(Icons.code, 'Kod', () => controller.wrapSelection('`')),
          gap(),
          btn(Icons.format_list_bulleted, 'Madde listesi',
              () => controller.toggleList(ListKind.bullet)),
          btn(Icons.checklist, 'Yapılacaklar (Ctrl+Enter)',
              () => controller.toggleList(ListKind.task)),
          btn(Icons.format_list_numbered, 'Numaralı liste',
              () => controller.toggleList(ListKind.ordered)),
          gap(),
          IconButton(
            tooltip: 'Yazı rengi',
            icon: const Icon(Icons.format_color_text, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => pickColor(highlight: false),
          ),
          IconButton(
            tooltip: 'Vurgu rengi',
            icon: const Icon(Icons.border_color_outlined, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => pickColor(highlight: true),
          ),
        ]),
      ),
    );
  }
}
