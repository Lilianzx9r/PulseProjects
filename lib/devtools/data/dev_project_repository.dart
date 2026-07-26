import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/dev_project.dart';

/// Persistance des projets Flutter gérés par l'outil "Build & Release".
///
/// Stocké séparément des profils navigateur (`projects.json`), dans le
/// même dossier racine PulseProjects :
///   • Windows : %APPDATA%\PulseProjects\dev_projects.json
///   • macOS   : ~/Library/Application Support/PulseProjects/dev_projects.json
class DevProjectRepository {
  Directory? _rootDirCache;

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

  Future<File> get _file async {
    final root = await _rootDir;
    return File(p.join(root.path, 'dev_projects.json'));
  }

  Future<List<DevProject>> load() async {
    final file = await _file;
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => DevProject.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> save(List<DevProject> projects) async {
    final file = await _file;
    await file.writeAsString(
        jsonEncode(projects.map((e) => e.toJson()).toList()));
  }

  /// Dossier des releases effectif pour [project] : l'override s'il est
  /// défini, sinon `<parent(sourcePath)>/Releases` (comportement du script
  /// .bat d'origine, où Releases est un dossier frère du projet source).
  String effectiveReleasesFolder(DevProject project) {
    if (project.releasesFolderOverride != null &&
        project.releasesFolderOverride!.isNotEmpty) {
      return project.releasesFolderOverride!;
    }
    return p.join(p.dirname(project.sourcePath), 'Releases');
  }

  /// Dossier d'archivage des anciennes releases : toujours un dossier frère
  /// du dossier de releases courant, nommé `ReleasesOld` (même logique que
  /// le .bat : %ROOT%ReleasesOld à côté de %ROOT%Releases).
  String effectiveOldReleasesFolder(DevProject project) {
    final releases = effectiveReleasesFolder(project);
    return p.join(p.dirname(releases), 'ReleasesOld');
  }
}
