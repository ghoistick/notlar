import '../../core/text/turkish_collation.dart';
import '../../data/db/database.dart';

/// Düz klasör listesinden ağaç düğümü.
class FolderNode {
  final Folder folder;
  final List<FolderNode> children = [];
  FolderNode(this.folder);
}

/// Satır olarak gösterilecek düğüm (girinti derinliğiyle).
class FolderRow {
  final Folder folder;
  final int depth;
  final bool hasChildren;
  const FolderRow(this.folder, this.depth, this.hasChildren);
}

/// Ebeveyni olmayan ya da ebeveyni listede bulunmayan klasörler köke konur;
/// böylece senkronizasyonda sırası karışan veriler de görünür kalır.
List<FolderNode> buildFolderTree(List<Folder> folders) {
  final byId = {for (final f in folders) f.id: FolderNode(f)};
  final roots = <FolderNode>[];
  for (final node in byId.values) {
    final parent = node.folder.parentId == null
        ? null
        : byId[node.folder.parentId];
    if (parent == null) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }

  int compare(FolderNode a, FolderNode b) {
    final p = a.folder.position.compareTo(b.folder.position);
    return p != 0 ? p : compareTurkish(a.folder.name, b.folder.name);
  }

  void sortRec(List<FolderNode> list) {
    list.sort(compare);
    for (final n in list) {
      sortRec(n.children);
    }
  }

  sortRec(roots);
  return roots;
}

/// Ağacı, yalnızca açık klasörlerin çocuklarını içerecek şekilde düzleştirir.
List<FolderRow> flattenTree(
  List<FolderNode> roots, {
  Set<String> expanded = const {},
  bool expandAll = false,
}) {
  final out = <FolderRow>[];
  void walk(List<FolderNode> nodes, int depth) {
    for (final n in nodes) {
      out.add(FolderRow(n.folder, depth, n.children.isNotEmpty));
      if (expandAll || expanded.contains(n.folder.id)) {
        walk(n.children, depth + 1);
      }
    }
  }

  walk(roots, 0);
  return out;
}
