import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import '../../backup/backup_service.dart';
import '../../core/net/http_client.dart';
import '../../sync/sync_service.dart';
import '../../core/version.dart';
import '../../update/update_service.dart';
import '../home/note_actions.dart';

Future<void> showAboutUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, __) => _AboutDialog(
        service: ref.watch(updateServiceProvider),
        onInstall: () => _installUpdate(ctx, ref),
      ),
    ),
  );
}

/// İndir → doğrula → kayıtları yaz, yedek al, kilitle → kurulumu başlat → kapat.
Future<void> _installUpdate(BuildContext context, WidgetRef ref) async {
  final updates = ref.read(updateServiceProvider);
  final file = updates.downloaded ?? await updates.download();
  if (file == null || !context.mounted) return;

  for (final flush in [...pendingEditorSaves]) {
    await flush();
  }
  try {
    await ref.read(syncServiceProvider).syncBeforeLock();
  } catch (_) {}
  try {
    await ref.read(backupServiceProvider).backupBeforeLock();
  } catch (_) {}
  await ref.read(sessionProvider.notifier).lock();

  await updates.launchInstaller(file);
  exit(0);
}

/// Kurum ağında Windows proxy ayarı otomatik bulunamazsa elle girilir.
Future<void> _editProxy(BuildContext context, UpdateService service) async {
  final controller = TextEditingController(text: await service.manualProxy() ?? '');
  if (!context.mounted) return;
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Proxy ayarı'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Uygulama Windows\'un proxy ayarını otomatik bulamıyorsa adresi buraya '
            'yaz. Boş bırakırsan otomatik algılanır.',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Proxy sunucusu',
              hintText: 'proxy.kurum.gov.tr:8080',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Kaydet ve denetle'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (value == null) return;
  await service.setManualProxy(value);
  await service.check();
}

class _AboutDialog extends StatelessWidget {
  final UpdateService service;
  final VoidCallback onInstall;
  const _AboutDialog({required this.service, required this.onInstall});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final s = service;
        final available = s.available;

        Widget status;
        if (!UpdateService.supported) {
          status = const Text('Güncelleme denetimi şimdilik yalnızca Windows sürümünde var.');
        } else if (s.checking) {
          status = const Row(children: [
            SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Denetleniyor…'),
          ]);
        } else if (s.downloading) {
          status = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('İndiriliyor… %${((s.progress ?? 0) * 100).round()}'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: s.progress),
          ]);
        } else if (s.error != null) {
          status = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(s.error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 8),
            FutureBuilder<String>(
              future: proxySummary(),
              builder: (context, snap) => SelectableText(
                snap.data ?? '',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ]);
        } else if (available != null) {
          status = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Yeni sürüm: ${available.version}',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w600)),
            if (available.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(available.notes),
            ],
            const SizedBox(height: 8),
            Text(
              'Kurulum başlamadan önce notların kaydedilir, yedek alınır ve '
              'uygulama kilitlenir. Kurulum bitince Müsvedde yeniden açılır.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ]);
        } else if (s.upToDate) {
          status = const Text('En güncel sürümü kullanıyorsun.');
        } else {
          status = const SizedBox.shrink();
        }

        return AlertDialog(
          title: const Text('Müsvedde'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isDevBuild ? 'Geliştirme sürümü' : 'Sürüm $appVersion',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(
                  'Şifreli, kişisel not uygulaması. Notların yalnızca senin '
                  'cihazlarında ve senin anahtarınla açılır.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                status,
              ],
            ),
          ),
          actions: [
            if (UpdateService.supported)
              TextButton(
                onPressed: s.downloading || s.checking
                    ? null
                    : () => _editProxy(context, s),
                child: const Text('Proxy ayarı…'),
              ),
            TextButton(
              onPressed: s.downloading ? null : () => Navigator.of(context).pop(),
              child: const Text('Kapat'),
            ),
            if (UpdateService.supported && available == null)
              OutlinedButton(
                onPressed: s.checking ? null : () => s.check(),
                child: const Text('Güncellemeleri denetle'),
              ),
            if (available != null)
              FilledButton(
                onPressed: s.downloading ? null : onInstall,
                child: const Text('İndir ve kur'),
              ),
          ],
        );
      },
    );
  }
}
