import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';

/// GEÇİCİ ana ekran. Kilit akışının ve şifreli veritabanının uçtan uca
/// çalıştığını doğrulamak için. Bir sonraki adımda üç panelli düzenle
/// değiştirilecek.
class HomePlaceholder extends ConsumerStatefulWidget {
  final NotesRepository repository;
  const HomePlaceholder({super.key, required this.repository});

  @override
  ConsumerState<HomePlaceholder> createState() => _HomePlaceholderState();
}

class _HomePlaceholderState extends ConsumerState<HomePlaceholder> {
  late final Stream<List<Note>> _notes =
      widget.repository.watchNotes(const NoteQuery());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notlar'),
        actions: [
          IconButton(
            tooltip: 'Kilitle',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => ref.read(sessionProvider.notifier).lock(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<Note>>(
        stream: _notes,
        builder: (context, snapshot) {
          final notes = snapshot.data;
          if (notes == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (notes.isEmpty) {
            return Center(
              child: Text(
                'Henüz not yok. İlk notunu oluştur.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            );
          }
          return ListView.separated(
            itemCount: notes.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final n = notes[i];
              return ListTile(
                title: Text(n.title.isEmpty ? 'Başlıksız' : n.title),
                subtitle: Text(_formatDate(n.updatedAt)),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => widget.repository.createNote(title: 'Yeni not'),
        icon: const Icon(Icons.add),
        label: const Text('Yeni not'),
      ),
    );
  }
}

String _formatDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}
