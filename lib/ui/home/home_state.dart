import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session.dart';
import '../../data/db/database.dart';
import '../../data/repository/notes_repository.dart';

// ------------------------------------------------------------------ Görünüm

enum NoteViewKind { all, snippets, folder, tag, archive, trash }

/// Sol panelde seçilen görünüm.
class NoteView {
  final NoteViewKind kind;
  final String? id; // klasör ya da etiket kimliği

  const NoteView(this.kind, [this.id]);

  static const all = NoteView(NoteViewKind.all);
  static const snippets = NoteView(NoteViewKind.snippets);
  static const archive = NoteView(NoteViewKind.archive);
  static const trash = NoteView(NoteViewKind.trash);
  factory NoteView.folder(String id) => NoteView(NoteViewKind.folder, id);
  factory NoteView.tag(String id) => NoteView(NoteViewKind.tag, id);

  @override
  bool operator ==(Object other) =>
      other is NoteView && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

// ------------------------------------------------------------------- Durum

class HomeState {
  final NoteView view;
  final String search;
  final NoteSort sort;
  final bool descending;
  final String? selectedNoteId;

  /// Görünüm, arama ve sıralamadan türetilir. Yalnızca bunlar değişince
  /// yeni nesne oluşur; not seçmek listeyi yeniden sorgulatmaz.
  final NoteQuery query;

  const HomeState({
    required this.view,
    required this.search,
    required this.sort,
    required this.descending,
    required this.selectedNoteId,
    required this.query,
  });

  bool get searching => search.trim().isNotEmpty;

  HomeState withSelection(String? id) => HomeState(
        view: view,
        search: search,
        sort: sort,
        descending: descending,
        selectedNoteId: id,
        query: query,
      );
}

final homeProvider =
    NotifierProvider.autoDispose<HomeController, HomeState>(HomeController.new);

class HomeController extends Notifier<HomeState> {
  /// Her görünümün son sıralama tercihi (oturum boyunca hatırlanır).
  final _sorts = <NoteView, (NoteSort, bool)>{};

  /// Arama başlarken sıralama "en iyi eşleşme"ye geçer; arama bitince
  /// önceki sıralamaya dönülür.
  (NoteSort, bool)? _sortBeforeSearch;

  @override
  HomeState build() => _make(
        view: NoteView.all,
        search: '',
        sort: NoteSort.updatedAt,
        descending: true,
        selected: null,
      );

  void selectView(NoteView view) {
    if (!state.searching) _sorts[state.view] = (state.sort, state.descending);
    _sortBeforeSearch = null;
    final (sort, desc) = _sorts[view] ?? (NoteSort.updatedAt, true);
    state = _make(
        view: view, search: '', sort: sort, descending: desc, selected: null);
  }

  void setSearch(String text) {
    final was = state.searching;
    final now = text.trim().isNotEmpty;
    var sort = state.sort;
    var desc = state.descending;

    if (!was && now) {
      _sortBeforeSearch = (sort, desc);
      sort = NoteSort.relevance;
      desc = false;
    } else if (was && !now) {
      (sort, desc) = _sortBeforeSearch ?? (NoteSort.updatedAt, true);
      _sortBeforeSearch = null;
    }
    state = _make(
      view: state.view,
      search: text,
      sort: sort,
      descending: desc,
      selected: state.selectedNoteId,
    );
  }

  void setSort(NoteSort sort, bool descending) {
    state = _make(
      view: state.view,
      search: state.search,
      sort: sort,
      descending: descending,
      selected: state.selectedNoteId,
    );
  }

  void select(String? noteId) => state = state.withSelection(noteId);

  HomeState _make({
    required NoteView view,
    required String search,
    required NoteSort sort,
    required bool descending,
    required String? selected,
  }) {
    final s = search.trim().isEmpty ? null : search;
    final NoteQuery query = switch (view.kind) {
      NoteViewKind.all =>
        NoteQuery(search: s, sort: sort, descending: descending),
      NoteViewKind.snippets => NoteQuery(
          search: s, kind: NoteKind.snippet, sort: sort, descending: descending),
      NoteViewKind.folder => NoteQuery(
          search: s, folderId: view.id, sort: sort, descending: descending),
      NoteViewKind.tag => NoteQuery(
          search: s, tagId: view.id, sort: sort, descending: descending),
      NoteViewKind.archive => NoteQuery(
          search: s,
          scope: NoteScope.archived,
          sort: sort,
          descending: descending),
      NoteViewKind.trash => NoteQuery(
          search: s, scope: NoteScope.trash, sort: sort, descending: descending),
    };
    return HomeState(
      view: view,
      search: search,
      sort: sort,
      descending: descending,
      selectedNoteId: selected,
      query: query,
    );
  }
}

// ---------------------------------------------------------------- Veriler

final repositoryProvider = Provider.autoDispose<NotesRepository>((ref) {
  final session = ref.watch(sessionProvider);
  if (session is SessionUnlocked) return session.repository;
  throw StateError('Kasa kilitli.');
});

final foldersProvider = StreamProvider.autoDispose<List<Folder>>(
    (ref) => ref.watch(repositoryProvider).watchFolders());

final tagsProvider = StreamProvider.autoDispose<List<Tag>>(
    (ref) => ref.watch(repositoryProvider).watchTags());

final headingSummariesProvider =
    StreamProvider.autoDispose<Map<String, List<String>>>(
        (ref) => ref.watch(repositoryProvider).watchHeadingSummaries());

final notesProvider = StreamProvider.autoDispose<List<Note>>((ref) {
  final query = ref.watch(homeProvider.select((s) => s.query));
  return ref.watch(repositoryProvider).watchNotes(query);
});

final noteProvider = StreamProvider.autoDispose.family<Note?, String>(
    (ref, id) => ref.watch(repositoryProvider).watchNote(id));

final noteTagsProvider = StreamProvider.autoDispose.family<List<Tag>, String>(
    (ref, id) => ref.watch(repositoryProvider).watchTagsOfNote(id));

/// Ctrl+F ile arama kutusuna odaklanmak için.
final searchFocusProvider = Provider.autoDispose<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'search');
  ref.onDispose(node.dispose);
  return node;
});

/// Dar ekranda (telefon) sol panel çekmece olur, not ayrı sayfada açılır.
bool isNarrow(BuildContext context) => MediaQuery.sizeOf(context).width < 700;
