import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../common/process_tracker.dart';
import '../models/project.dart';

class ProjectRepository {
  Directory? _rootDirCache;

  /// Dossier racine des données PulseProjects (projets.json, vue, etc.) :
  ///   • Windows : %APPDATA%\PulseProjects
  ///   • macOS   : ~/Library/Application Support/PulseProjects
  Future<Directory> get _rootDir async {
    if (_rootDirCache != null) return _rootDirCache!;

    final Directory dir;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
      dir = Directory(p.join(appData, 'PulseProjects'));
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      dir = Directory(p.join(home, 'Library', 'Application Support', 'PulseProjects'));
    } else {
      throw UnsupportedError('Unsupported platform');
    }

    if (!await dir.exists()) await dir.create(recursive: true);
    _rootDirCache = dir;
    return dir;
  }

  Future<File> get _projectsFile async {
    final root = await _rootDir;
    return File(p.join(root.path, 'projects.json'));
  }

  Future<List<Project>> loadProjects() async {
    final file = await _projectsFile;
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveProjects(List<Project> projects) async {
    final file = await _projectsFile;
    await file.writeAsString(
        jsonEncode(projects.map((e) => e.toJson()).toList()));
  }

  Future<Project?> getProject(String id) async {
    for (final project in await loadProjects()) {
      if (project.id == id) return project;
    }
    return null;
  }

  /// Dossier de données du profil web isolé pour [projectId].
  ///
  ///   • Windows : %APPDATA%\PulseProjects\profiles\<id>
  ///     (utilisé comme userDataFolder de WindowsWebViewControllerCreationParams)
  ///
  ///   • macOS : ~/Library/WebKit/WebsiteDataStores/<id>
  ///     C'est l'emplacement RÉEL sur disque où WKWebsiteDataStore.dataStore(
  ///     forIdentifier:) persiste cookies/localStorage/IndexedDB — [projectId]
  ///     DOIT être l'UUID exact passé au plugin Swift (project.id), pour que
  ///     l'export/import et la réinitialisation agissent sur les bonnes
  ///     données. Ce dossier est géré par WebKit lui-même (créé au premier
  ///     lancement du WKWebView) : on ne le crée pas nous-mêmes ici si la
  ///     WebView n'a encore jamais tourné.
  Future<String> profileDataDir(String projectId) async {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      final dir = Directory(
        p.join(home, 'Library', 'WebKit', 'WebsiteDataStores', projectId),
      );
      // Ne pas forcer la création : WebKit la crée lui-même au premier
      // chargement de page. Un dossier vide créé prématurément n'est pas
      // un problème, mais inutile de l'imposer.
      return dir.path;
    }

    // Windows
    final root = await _rootDir;
    final dir  = Directory(p.join(root.path, 'profiles', projectId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> resetProfileData(String projectId) async {
    if (Platform.isMacOS) {
      // Sur macOS, on ne doit PAS supprimer le dossier
      // ~/Library/WebKit/WebsiteDataStores/<id> directement pendant que
      // l'app tourne : WebKit gère ce store en interne. La méthode propre
      // est de demander à WKWebsiteDataStore de purger ses propres données
      // via le plugin Swift (removeData(ofTypes:modifiedSince:)). Comme
      // BrowserViewMacOS doit être fermé pour réinitialiser (cf. UI), on
      // peut alors supprimer le dossier en toute sécurité : WebKit le
      // recréera proprement au prochain lancement.
      final dir = Directory(await profileDataDir(projectId));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    }

    // Windows
    final root = await _rootDir;
    final dir  = Directory(p.join(root.path, 'profiles', projectId));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  }

  /// Lance une instance browser pour [project], ou met au premier plan
  /// l'instance existante si elle est déjà ouverte.
  Future<bool> launchProject(Project project) async {
    // Vérifier si une instance tourne déjà pour ce profil
    final running = await ProcessTracker.runningProjects();
    final pid = running[project.id];
    if (pid != null && ProcessTracker.isPidAlive(pid)) {
      ProcessTracker.bringToFront(pid);
      return false; // false = pas de nouvelle instance, on a juste focus
    }

    final exe = Platform.resolvedExecutable;
    await Process.start(
      exe,
      ['--project=${project.id}'],
      mode: ProcessStartMode.detached,
      workingDirectory: p.dirname(exe),
    );
    return true; // true = nouvelle instance lancée
  }

  // ── Préférence d'affichage (detailed / compact / mosaic) ───────────────────

  Future<File> get _viewModeFile async {
    final root = await _rootDir;
    return File(p.join(root.path, 'view_mode.txt'));
  }

  /// Retourne le nom du mode d'affichage sauvegardé (ex: "compact"),
  /// ou null si jamais défini.
  Future<String?> loadViewMode() async {
    try {
      final f = await _viewModeFile;
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveViewMode(String modeName) async {
    try {
      final f = await _viewModeFile;
      await f.writeAsString(modeName);
    } catch (_) {}
  }
}
