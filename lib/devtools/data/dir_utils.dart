import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Copie récursivement [sourceDir] vers [destDir], en excluant tout
/// sous-dossier dont le NOM (à n'importe quelle profondeur) figure dans
/// [excludeDirNames]. Reproduit le comportement de `robocopy /XD` utilisé
/// par le script .bat d'origine (exclusion par nom de dossier, pas par
/// chemin complet).
Future<void> copyDirectoryExcluding({
  required String sourceDir,
  required String destDir,
  required Set<String> excludeDirNames,
}) async {
  final src = Directory(sourceDir);
  if (!await src.exists()) return;

  await Directory(destDir).create(recursive: true);

  await for (final entity in src.list(followLinks: false)) {
    final name = p.basename(entity.path);

    if (entity is Directory) {
      if (excludeDirNames.contains(name)) continue; // exclusion par nom
      await copyDirectoryExcluding(
        sourceDir: entity.path,
        destDir: p.join(destDir, name),
        excludeDirNames: excludeDirNames,
      );
    } else if (entity is File) {
      try {
        await entity.copy(p.join(destDir, name));
      } catch (_) {
        // Fichier verrouillé/inaccessible → ignoré silencieusement
      }
    }
  }
}

/// Copie récursivement [sourceDir] vers [destDir] SANS exclusion — utilisé
/// pour copier les dossiers de build (déjà propres par nature).
Future<void> copyDirectoryAll({
  required String sourceDir,
  required String destDir,
}) async {
  await copyDirectoryExcluding(
    sourceDir: sourceDir,
    destDir: destDir,
    excludeDirNames: const {},
  );
}

/// Supprime [dir] s'il existe (récursivement), sans lever d'exception en
/// cas d'échec (fichiers verrouillés, permissions...).
Future<void> deleteIfExists(String dir) async {
  try {
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

/// Compresse le contenu de [sourceDir] (tous ses fichiers/sous-dossiers,
/// PAS le dossier racine lui-même) dans une archive zip [destZipPath].
/// Équivalent de `Compress-Archive -Path '<sourceDir>\*' -DestinationPath`.
///
/// Parcours dossier par dossier (pas `list(recursive: true)`) : une erreur
/// d'énumération sur un sous-dossier (chemin trop long, verrouillé...)
/// n'interrompt que ce sous-dossier, jamais tout l'export.
Future<void> zipDirectoryContents({
  required String sourceDir,
  required String destZipPath,
}) async {
  final archive = Archive();
  final root = Directory(sourceDir);

  if (await root.exists()) {
    await _walkAndZip(root, sourceDir, archive);
  }

  final zipBytes = ZipEncoder().encode(archive);
  if (zipBytes == null) {
    throw Exception('Échec de la compression de l\'archive.');
  }
  await File(destZipPath).writeAsBytes(zipBytes, flush: true);
}

Future<void> _walkAndZip(Directory dir, String sourceDir, Archive archive) async {
  List<FileSystemEntity> entities;
  try {
    entities = await dir.list(followLinks: false).toList();
  } catch (_) {
    return; // dossier inaccessible → ignoré, le reste continue
  }

  for (final entity in entities) {
    if (entity is Directory) {
      await _walkAndZip(entity, sourceDir, archive);
      continue;
    }
    if (entity is! File) continue;

    final rel = p.relative(entity.path, from: sourceDir).replaceAll('\\', '/');
    try {
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    } catch (_) {
      // Fichier verrouillé/inaccessible → ignoré silencieusement
    }
  }
}

/// Déplace tous les fichiers de [sourceDir] dont le nom correspond au motif
/// `<namePrefix>_*<extension>` vers [destDir]. Reproduit le
/// `move /Y "%RELEASE%\%PROJECT%_*.zip" "%OLD%\"` du script .bat.
Future<void> moveMatchingFiles({
  required String sourceDir,
  required String destDir,
  required String namePrefix,
  required String extension, // ex: '.zip' ou '.apk' (avec le point)
}) async {
  final src = Directory(sourceDir);
  if (!await src.exists()) return;
  await Directory(destDir).create(recursive: true);

  await for (final entity in src.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith('${namePrefix}_') || !name.endsWith(extension)) continue;

    final destPath = p.join(destDir, name);
    try {
      await entity.rename(destPath);
    } catch (_) {
      try {
        await entity.copy(destPath);
        await entity.delete();
      } catch (_) {
        // Échec de déplacement → fichier laissé en place, non bloquant
      }
    }
  }
}
