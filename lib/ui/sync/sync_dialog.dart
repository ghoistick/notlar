import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/google_account.dart';
import '../../sync/sync_service.dart';
import '../common/dialogs.dart';
import '../common/format.dart';

Future<void> showSyncDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, __) => _SyncDialog(
        account: ref.watch(googleAccountProvider),
        sync: ref.watch(syncServiceProvider),
      ),
    ),
  );
}

class _SyncDialog extends StatelessWidget {
  final GoogleAccount account;
  final SyncService sync;
  const _SyncDialog({required this.account, required this.sync});

  String _reportText(SyncService s) {
    final r = s.lastReport;
    if (r == null) return '';
    final parts = <String>[
      if (r.pushedOps > 0) '${r.pushedOps} değişiklik gönderildi',
      if (r.applied.applied > 0) '${r.applied.applied} değişiklik alındı',
      if (r.applied.conflicts > 0) '${r.applied.conflicts} çakışan kopya oluşturuldu',
    ];
    return parts.isEmpty ? 'Her şey güncel.' : '${parts.join(', ')}.';
  }

  Future<void> _disconnect(BuildContext context) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Bağlantı kaldırılsın mı?',
      message: 'Müsvedde\'nin Google hesabına erişim izni geri alınır. Drive\'daki '
          'şifreli senkronizasyon dosyaları silinmez; tekrar bağlandığında '
          'kaldığın yerden devam edilir.',
      confirmLabel: 'Bağlantıyı kaldır',
    );
    if (ok) await account.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return ListenableBuilder(
      listenable: Listenable.merge([account, sync]),
      builder: (context, _) {
        final a = account;
        final s = sync;
        return AlertDialog(
          title: const Text('Senkronizasyon'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notların cihazlar arasında Google Drive üzerinden eşitlenir. '
                    'Drive\'a gönderilen her şey bu cihazda önceden şifrelenir; '
                    'Google içeriği okuyamaz. Uygulama, Drive\'ında yalnızca '
                    'kendine ait gizli bir klasörü görür.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(children: [
                      Icon(
                        a.connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                        color: a.connected ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          !a.loaded
                              ? 'Yükleniyor…'
                              : a.connected
                                  ? 'Bağlı${a.email != null ? ': ${a.email}' : ''}'
                                  : 'Google hesabı bağlı değil.',
                        ),
                      ),
                    ]),
                  ),
                  if (a.busy && a.pendingAuthUrl != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Tarayıcıda Google giriş sayfası açıldı. Girişi orada tamamla. '
                      'Sayfa açılmadıysa bağlantıyı kopyalayıp tarayıcına yapıştır.',
                      style: muted,
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: a.pendingAuthUrl!)),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Giriş bağlantısını kopyala'),
                    ),
                  ],
                  if (a.connected) ...[
                    const SizedBox(height: 20),
                    Text('Eşitleme',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      s.running
                          ? 'Eşitleniyor…'
                          : s.lastSyncAt == null
                              ? 'Henüz eşitlenmedi.'
                              : 'Son eşitleme: ${formatLongDate(s.lastSyncAt!.millisecondsSinceEpoch)}. ${_reportText(s)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (s.lastError != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(s.lastError!, style: TextStyle(color: scheme.error)),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: s.enabled,
                      onChanged: s.setEnabled,
                      title: const Text('Otomatik eşitle'),
                      subtitle: Text(
                        'Uygulama açılırken, dakikada bir ve kilitlerken.',
                        style: muted,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: s.running || !s.enabled ? null : s.syncNow,
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Şimdi eşitle'),
                      ),
                    ),
                  ],
                  if (a.testResult != null) ...[
                    const SizedBox(height: 12),
                    Text(a.testResult!, style: TextStyle(color: scheme.primary)),
                  ],
                  if (a.error != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(a.error!, style: TextStyle(color: scheme.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (a.connected)
              TextButton(
                onPressed: a.busy ? null : () => _disconnect(context),
                child: const Text('Bağlantıyı kaldır'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Kapat'),
            ),
            if (a.connected)
              FilledButton(
                onPressed: a.busy ? null : a.test,
                child: a.busy
                    ? const SizedBox.square(
                        dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Bağlantıyı test et'),
              )
            else
              FilledButton(
                onPressed: a.busy || !a.loaded ? null : a.connect,
                child: a.busy
                    ? const SizedBox.square(
                        dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Google hesabını bağla'),
              ),
          ],
        );
      },
    );
  }
}
