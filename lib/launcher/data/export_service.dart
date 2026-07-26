import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';

import '../../common/zip_utils.dart';
import '../models/project.dart';
import 'project_repository.dart';

/// Export/Import de profils PulseProjects, en un seul profil ou en groupe.
///
/// Un export « simple » contient :
///   • metadata.json — nom, URL de démarrage, dossier de travail
///   • profile/…     — copie du dossier de données WebView2 du profil
///
/// Un export « groupé » (bundle, plusieurs profils en une archive) contient :
///   • manifest.json          — métadonnées de tous les profils inclus
///   • profiles/<id>/…        — données WebView2 de chaque profil
///
/// IMPORTANT — portabilité des cookies/mots de passe :
/// Chromium/WebView2 chiffre certaines données sensibles (cookies,
/// identifiants enregistrés) via l'API Windows DPAPI, qui dérive sa clé
/// du compte Windows courant. Un export réimporté sur le MÊME PC et le
/// MÊME compte Windows retrouve une session pleinement fonctionnelle.
/// Sur une autre machine ou un autre compte Windows, les cookies de
/// session peuvent devenir illisibles (le site redemandera une connexion),
/// alors que localStorage et IndexedDB restent eux intacts (non chiffrés
/// par DPAPI).
class ExportService {
  final ProjectRepository repository;
  const ExportService(this.repository);

  // ── Export d'un seul profil ────────────────────────────────────────────

  /// Exporte [project] vers l'archive [destZipPath].
  ///
  /// Le profil ne doit pas être en cours d'exécution au moment de l'export
  /// (fichiers potentiellement verrouillés par WebView2, copie incohérente).
  /// C'est à l'appelant de vérifier cette condition au préalable.
  Future<void> exportProject(
    Project project,
    String destZipPath, {
    bool includeCache = false,
  }) async {
    final profileDir = await repository.profileDataDir(project.id);
    await zipProjectToFile(
      profileDir: profileDir,
      metadata: {
        'schemaVersion': 1,
        'app': 'PulseProjects',
        'platform': 'desktop',
        'exportedAt': DateTime.now().toIso8601String(),
        'project': _projectMeta(project),
      },
      destZipPath: destZipPath,
      includeCache: includeCache,
    );
  }

  // ── Export groupé (plusieurs profils en une archive) ──────────────────

  /// Exporte tous les profils de [projects] dans une seule archive
  /// « bundle ». Aucun des profils fournis ne doit être en cours
  /// d'exécution — c'est à l'appelant de filtrer la liste au préalable
  /// (voir `ProcessTracker.runningProjects`).
  Future<void> exportAllProjects(
    List<Project> projects,
    String destZipPath, {
    bool includeCache = false,
  }) async {
    final entries = <BundleEntry>[];
    for (final project in projects) {
      final profileDir = await repository.profileDataDir(project.id);
      entries.add(BundleEntry(
        sourceId: project.id,
        profileDir: profileDir,
        meta: _projectMeta(project),
      ));
    }
    await zipBundleToFile(
      entries: entries,
      destZipPath: destZipPath,
      includeCache: includeCache,
    );
  }

  Map<String, dynamic> _projectMeta(Project project) => {
        'name': project.name,
        'homeUrl': project.homeUrl,
        'workFolder': project.workFolder,
        'sourceCreatedAt': project.createdAt.toIso8601String(),
      };

  // ── Import (détection automatique simple / groupé) ─────────────────────

  /// Importe l'archive [zipPath], qu'il s'agisse d'un export simple ou
  /// groupé — le format est détecté automatiquement.
  ///
  /// Crée systématiquement de NOUVEAUX profils (nouveaux identifiants),
  /// même en cas de ré-import d'une archive déjà importée, pour éviter
  /// tout écrasement accidentel d'un profil existant. Retourne la liste
  /// des [Project] créés (un seul élément pour un export simple) — c'est
  /// à l'appelant de les ajouter à la liste et de sauvegarder.
  Future<List<Project>> importAny(String zipPath) async {
    final archive = await decodeZipFile(zipPath);
    final kind    = detectZipKind(archive);

    switch (kind) {
      case ZipArchiveKind.single:
        return [await _importSingle(archive)];
      case ZipArchiveKind.bundle:
        return _importBundle(archive);
      case ZipArchiveKind.unknown:
        throw Exception(
          'Archive invalide : ni metadata.json ni manifest.json trouvés '
          '(ce fichier n\'a peut-être pas été exporté par PulseProjects).',
        );
    }
  }

  Future<Project> _importSingle(Archive archive) async {
    final metadata = findJsonEntry(archive, 'metadata.json')!;
    final projMeta = Map<String, dynamic>.from(
      (metadata['project'] as Map?) ?? const {},
    );

    final newId   = const Uuid().v4();
    final destDir = await repository.profileDataDir(newId);
    await extractArchiveSubtree(archive: archive, prefix: 'profile/', destDir: destDir);

    return _buildProject(newId, projMeta);
  }

  Future<List<Project>> _importBundle(Archive archive) async {
    final manifest = findJsonEntry(archive, 'manifest.json')!;
    final projects = (manifest['projects'] as List?) ?? const [];

    final result = <Project>[];
    for (final raw in projects) {
      final projMeta = Map<String, dynamic>.from(raw as Map);
      final sourceId = projMeta['sourceId'] as String?;
      if (sourceId == null) continue;

      final newId   = const Uuid().v4();
      final destDir = await repository.profileDataDir(newId);
      await extractArchiveSubtree(
        archive: archive,
        prefix: 'profiles/$sourceId/',
        destDir: destDir,
      );
      result.add(_buildProject(newId, projMeta));
    }
    return result;
  }

  Project _buildProject(String newId, Map<String, dynamic> projMeta) {
    final name = (projMeta['name'] as String?)?.trim();
    return Project(
      id: newId,
      name: (name != null && name.isNotEmpty) ? name : 'Profil importé',
      homeUrl: projMeta['homeUrl'] as String? ?? 'https://www.google.com',
      workFolder: projMeta['workFolder'] as String?,
      createdAt: DateTime.now(),
    );
  }
}
