import 'dart:io';

import 'package:path/path.dart' as p;

/// Écrit le script d'un profil dans un fichier de cache PulseProjects
/// avant exécution, avec l'extension adaptée à la plateforme (.bat sur
/// Windows, .sh sur macOS).
///
/// Ce fichier est distinct du "dossier d'exécution" choisi par
/// l'utilisateur : celui-ci définit le répertoire de travail (cwd) du
/// script au moment de son lancement, tandis que le fichier script
/// lui-même est toujours stocké ici, indépendamment du projet, pour ne
/// jamais avoir à écrire dans les sources du projet.
class ScriptStore {
  ScriptStore._();

  static Future<Directory> _scriptsDir() async {
    final Directory base;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
      base = Directory(p.join(appData, 'PulseProjects'));
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      base = Directory(p.join(home, 'Library', 'Application Support', 'PulseProjects'));
    } else {
      throw UnsupportedError('Unsupported platform');
    }
    final dir = Directory(p.join(base.path, 'scripts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Écrit [content] pour le profil [projectId] et retourne le chemin du
  /// fichier écrit, prêt à être exécuté.
  static Future<String> write(String projectId, String content) async {
    final dir = await _scriptsDir();
    final ext = Platform.isWindows ? 'bat' : 'sh';
    final file = File(p.join(dir.path, '$projectId.$ext'));
    await file.writeAsString(content);
    return file.path;
  }
}
