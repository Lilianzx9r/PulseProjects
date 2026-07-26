import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Sous-dossiers Chromium/WebView2 considérés comme du cache régénérable
/// (pas nécessaires pour restaurer une session : cookies, localStorage,
/// IndexedDB en sont indépendants). Exclus par défaut de l'export pour
/// limiter la taille de l'archive.
const _kCacheDirNames = {
  'cache',
  'code cache',
  'gpucache',
  'grshadercache',
  'shadercache',
  'graphitedawncache',
  'crashpad',
  'datalessfilescache',
  'service worker',
};

/// Fichiers de verrou d'instance et de télémétrie propres à la machine
/// d'origine. Copiés tels quels sur un autre poste, ils peuvent laisser
/// croire à WebView2 qu'une instance précédente existe encore ou que le
/// profil est dans un état incohérent, ce qui se traduit par des
/// avertissements internes Chromium au démarrage (ex: messages
/// "ui::AXTree" liés à l'arbre d'accessibilité interne, ou autres logs
/// de récupération de profil) — généralement sans gravité, mais évités
/// en excluant ces fichiers de l'export.
const _kHostSpecificFileNames = {
  'lockfile',
  'singletonlock',
  'singletonsocket',
  'singletoncookie',
  'runningchromeversion',
  'browsermetrics-spare.pma',
};

bool _shouldExcludeFromExport(String relPath, bool includeCache) {
  final lowerSegments = relPath.toLowerCase().split('/');

  if (!includeCache && lowerSegments.any(_kCacheDirNames.contains)) {
    return true;
  }

  final fileName = lowerSegments.isNotEmpty ? lowerSegments.last : '';
  if (_kHostSpecificFileNames.contains(fileName)) return true;
  if (fileName.startsWith('browsermetrics-')) return true;

  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Primitives bas niveau (décodage / extraction génériques)
// ─────────────────────────────────────────────────────────────────────────────

/// Décode l'archive zip [zipPath] en mémoire. Utilisé une seule fois puis
/// partagé entre les opérations de lecture (manifest) et d'extraction,
/// pour éviter de relire le fichier plusieurs fois.
Future<Archive> decodeZipFile(String zipPath) async {
  final bytes = await File(zipPath).readAsBytes();
  return ZipDecoder().decodeBytes(bytes);
}

/// Cherche une entrée JSON nommée [entryName] à la racine de [archive]
/// (ex: "metadata.json" ou "manifest.json"), ou retourne null si absente.
Map<String, dynamic>? findJsonEntry(Archive archive, String entryName) {
  for (final f in archive) {
    if (f.isFile && f.name == entryName) {
      return jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
    }
  }
  return null;
}

/// Extrait toutes les entrées de [archive] dont le chemin commence par
/// [prefix] vers [destDir], en retirant ce préfixe.
Future<void> extractArchiveSubtree({
  required Archive archive,
  required String prefix,
  required String destDir,
}) async {
  for (final f in archive) {
    if (!f.isFile) continue;
    if (!f.name.startsWith(prefix)) continue;
    final rel = f.name.substring(prefix.length);
    if (rel.isEmpty) continue;

    final outFile = File(p.join(destDir, rel));
    await outFile.parent.create(recursive: true);
    await outFile.writeAsBytes(f.content as List<int>, flush: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Export d'un seul profil
// ─────────────────────────────────────────────────────────────────────────────

/// Compresse [profileDir] (récursivement) + un fichier `metadata.json`
/// synthétique vers l'archive zip [destZipPath].
///
/// Les fichiers de cache regénérables sont exclus sauf si [includeCache]
/// est vrai. Les fichiers verrouillés/inaccessibles (ex: lockfile WebView2
/// si le profil tourne encore) sont silencieusement ignorés.
Future<void> zipProjectToFile({
  required String profileDir,
  required Map<String, dynamic> metadata,
  required String destZipPath,
  bool includeCache = false,
}) async {
  final archive = Archive();

  final metaBytes = utf8.encode(jsonEncode(metadata));
  archive.addFile(ArchiveFile('metadata.json', metaBytes.length, metaBytes));

  await _addDirectoryToArchive(
    archive: archive,
    sourceDir: profileDir,
    entryPrefix: 'profile/',
    includeCache: includeCache,
  );

  await _writeArchive(archive, destZipPath);
}

/// Décompresse une archive de profil unique [zipPath] vers
/// [destProfileDir] (entrées sous `profile/`) et retourne `metadata.json`.
Future<Map<String, dynamic>> unzipProjectFile({
  required String zipPath,
  required String destProfileDir,
}) async {
  final archive  = await decodeZipFile(zipPath);
  final metadata = findJsonEntry(archive, 'metadata.json');
  if (metadata == null) {
    throw Exception(
      'Archive invalide : metadata.json introuvable '
      '(ce fichier n\'a peut-être pas été exporté par PulseProjects).',
    );
  }
  await extractArchiveSubtree(archive: archive, prefix: 'profile/', destDir: destProfileDir);
  return metadata;
}

// ─────────────────────────────────────────────────────────────────────────────
// Export groupé (bundle) de plusieurs profils
// ─────────────────────────────────────────────────────────────────────────────

/// Un profil à inclure dans un export groupé.
class BundleEntry {
  /// Identifiant d'origine (sert de préfixe de dossier dans l'archive ;
  /// à l'import, un nouvel identifiant est généré pour éviter toute
  /// collision avec un profil existant).
  final String sourceId;

  /// Dossier de données WebView2 du profil à inclure.
  final String profileDir;

  /// Métadonnées du profil, sérialisées telles quelles dans le manifest
  /// (nom, URL, dossier de travail, dates...).
  final Map<String, dynamic> meta;

  const BundleEntry({
    required this.sourceId,
    required this.profileDir,
    required this.meta,
  });
}

/// Compresse plusieurs profils ([entries]) en une seule archive « bundle ».
///
/// Structure de l'archive :
///   manifest.json                  — liste des métadonnées de profils
///   profiles/<sourceId>/...        — données WebView2 de chaque profil
Future<void> zipBundleToFile({
  required List<BundleEntry> entries,
  required String destZipPath,
  bool includeCache = false,
}) async {
  final archive = Archive();
  final manifestProjects = <Map<String, dynamic>>[];

  for (final entry in entries) {
    manifestProjects.add({'sourceId': entry.sourceId, ...entry.meta});
    await _addDirectoryToArchive(
      archive: archive,
      sourceDir: entry.profileDir,
      entryPrefix: 'profiles/${entry.sourceId}/',
      includeCache: includeCache,
    );
  }

  final manifest = {
    'schemaVersion': 1,
    'app': 'PulseProjects',
    'platform': 'desktop',
    'kind': 'bundle',
    'exportedAt': DateTime.now().toIso8601String(),
    'projects': manifestProjects,
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));

  await _writeArchive(archive, destZipPath);
}

// ─────────────────────────────────────────────────────────────────────────────
// Détection du type d'archive à l'import
// ─────────────────────────────────────────────────────────────────────────────

enum ZipArchiveKind { single, bundle, unknown }

ZipArchiveKind detectZipKind(Archive archive) {
  if (findJsonEntry(archive, 'manifest.json') != null) return ZipArchiveKind.bundle;
  if (findJsonEntry(archive, 'metadata.json') != null) return ZipArchiveKind.single;
  return ZipArchiveKind.unknown;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internes
// ─────────────────────────────────────────────────────────────────────────────

/// Parcourt [sourceDir] récursivement et ajoute chaque fichier retenu à
/// [archive]. Contrairement à `Directory.list(recursive: true)`, le
/// parcours est fait dossier par dossier : si l'énumération d'un
/// sous-dossier échoue (chemin trop long pour Windows, fichier verrouillé,
/// suppression concurrente par le navigateur...), seul CE sous-dossier est
/// ignoré — le reste de l'arborescence continue d'être exporté. Avec
/// `list(recursive: true)`, une seule erreur d'énumération fait échouer
/// l'intégralité du parcours (observé notamment sur les dossiers
/// `Service Worker\CacheStorage\<hash>\<hash>\` de WebView2, dont les noms
/// de fichiers combinés au chemin complet dépassent parfois la limite de
/// 260 caractères de Windows).
Future<void> _addDirectoryToArchive({
  required Archive archive,
  required String sourceDir,
  required String entryPrefix,
  required bool includeCache,
}) async {
  final root = Directory(sourceDir);
  if (!await root.exists()) return;
  await _walkDirectory(root, sourceDir, entryPrefix, includeCache, archive);
}

Future<void> _walkDirectory(
  Directory dir,
  String sourceDir,
  String entryPrefix,
  bool includeCache,
  Archive archive,
) async {
  List<FileSystemEntity> entities;
  try {
    entities = await dir.list(followLinks: false).toList();
  } catch (_) {
    // Ce dossier est inaccessible (chemin trop long, verrouillé, supprimé
    // entre-temps...) : on l'ignore et on poursuit le reste de
    // l'arborescence plutôt que de faire échouer tout l'export.
    return;
  }

  for (final entity in entities) {
    if (entity is Directory) {
      final name = p.basename(entity.path).toLowerCase();
      if (!includeCache && _kCacheDirNames.contains(name)) continue;
      await _walkDirectory(entity, sourceDir, entryPrefix, includeCache, archive);
      continue;
    }
    if (entity is! File) continue;

    final rel = p.relative(entity.path, from: sourceDir).replaceAll('\\', '/');
    if (_shouldExcludeFromExport(rel, includeCache)) continue;

    try {
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile('$entryPrefix$rel', bytes.length, bytes));
    } catch (_) {
      // Fichier verrouillé, inaccessible ou chemin trop long → ignoré
      // silencieusement, sans interrompre le reste de l'export.
    }
  }
}

Future<void> _writeArchive(Archive archive, String destZipPath) async {
  final zipBytes = ZipEncoder().encode(archive);
  if (zipBytes == null) {
    throw Exception('Échec de la compression de l\'archive.');
  }
  await File(destZipPath).writeAsBytes(zipBytes, flush: true);
}
