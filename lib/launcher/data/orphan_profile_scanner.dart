import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/project.dart';

/// Un dossier de données WebView2/WKWebView présent sur le disque mais
/// n'étant plus référencé par aucun [Project] dans `projects.json`.
///
/// Typiquement produit par un bug de conversion Web → Flutter où le profil
/// avait été retiré de la liste sans jamais avoir été correctement transféré
/// (voir historique) : la donnée de session (cookies, localStorage…) reste
/// intacte sur disque, seule la référence dans la liste a disparu.
class OrphanProfile {
  final String id;
  final String path;
  final DateTime? modifiedAt;

  const OrphanProfile({required this.id, required this.path, this.modifiedAt});
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Cherche les dossiers de profils dont l'identifiant (nom de dossier, un
/// UUID) n'apparaît dans aucun des [knownProjects]. Cross-plateforme :
///   • Windows : %APPDATA%\PulseProjects\profiles\<uuid>
///   • macOS   : ~/Library/WebKit/WebsiteDataStores\<uuid>
Future<List<OrphanProfile>> scanOrphanProfiles(List<Project> knownProjects) async {
  final knownIds = knownProjects.map((e) => e.id).toSet();

  final Directory root;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ??
        p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
    root = Directory(p.join(appData, 'PulseProjects', 'profiles'));
  } else if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '.';
    root = Directory(p.join(home, 'Library', 'WebKit', 'WebsiteDataStores'));
  } else {
    return [];
  }

  if (!await root.exists()) return [];

  final result = <OrphanProfile>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final id = p.basename(entity.path);
    if (!_uuidPattern.hasMatch(id)) continue; // ignore les dossiers non-UUID
    if (knownIds.contains(id)) continue;      // déjà référencé, pas orphelin

    DateTime? modified;
    try { modified = (await entity.stat()).modified; } catch (_) {}

    result.add(OrphanProfile(id: id, path: entity.path, modifiedAt: modified));
  }

  // Les plus récemment modifiés en premier (probablement les plus
  // pertinents à récupérer après un incident récent).
  result.sort((a, b) =>
      (b.modifiedAt ?? DateTime(0)).compareTo(a.modifiedAt ?? DateTime(0)));
  return result;
}
