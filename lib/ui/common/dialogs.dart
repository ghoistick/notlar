import 'package:flutter/material.dart';

import 'note_colors.dart';

/// Tek satırlık metin isteyen diyalog. İptal edilirse null döner.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String? label,
}) {
  final controller = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);

  void submit(BuildContext ctx) {
    final value = controller.text.trim();
    if (value.isNotEmpty) Navigator.of(ctx).pop(value);
  }

  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (_) => submit(ctx),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(onPressed: () => submit(ctx), child: Text(confirmLabel)),
      ],
    ),
  ).whenComplete(controller.dispose);
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 360, child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Renk seçimi sonucu. [key] null ise "renksiz" seçilmiştir.
class ColorChoice {
  final String? key;
  const ColorChoice(this.key);
}

/// İptal edilirse null, seçim yapılırsa [ColorChoice] döner.
Future<ColorChoice?> showColorPicker(
  BuildContext context, {
  required String title,
  String? current,
}) {
  return showDialog<ColorChoice>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;

      Widget swatch({
        required String tooltip,
        required String? key,
        required Color fill,
        Widget? child,
      }) {
        final selected = key == current;
        return Tooltip(
          message: tooltip,
          child: InkResponse(
            onTap: () => Navigator.of(ctx).pop(ColorChoice(key)),
            radius: 22,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.onSurface : scheme.outline,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: child,
            ),
          ),
        );
      }

      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              swatch(
                tooltip: 'Renksiz',
                key: null,
                fill: scheme.surface,
                child: Icon(Icons.block, size: 18, color: scheme.onSurfaceVariant),
              ),
              for (final c in noteColors)
                swatch(tooltip: c.label, key: c.key, fill: c.swatch),
            ],
          ),
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
}
