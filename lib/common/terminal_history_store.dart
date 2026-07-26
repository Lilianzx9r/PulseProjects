import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Persiste l'historique des commandes saisies dans le terminal intégré,
/// par profil, sur disque :
///   • Windows : %APPDATA%\PulseProjects\terminal_history\<id>.json
///   • macOS   : ~/Library/Application Support/PulseProjects/terminal_history/<id>.json
///
/// Stocké en dehors du dossier de profil web : ainsi « Réinitialiser
/// les données » (qui efface cookies/cache) n'efface pas l'historique de
/// commandes, qui n'a aucun rapport avec la navigation web.
class TerminalHistoryStore {
  TerminalHistoryStore._();

  static const _maxEntries = 200;

  static Future<Directory> _historyDir() async {
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

    final dir = Directory(p.join(base.path, 'terminal_history'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fileFor(String projectId) async {
    final dir = await _historyDir();
    return File(p.join(dir.path, '$projectId.json'));
  }

  /// Charge l'historique sauvegardé pour [projectId], ou une liste vide
  /// si aucun historique n'existe encore (échec silencieux en cas
  /// d'erreur de lecture : l'historique n'est qu'un confort, pas critique).
  static Future<List<String>> load(String projectId) async {
    try {
      final file = await _fileFor(projectId);
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  /// Sauvegarde [history] pour [projectId], tronqué aux [_maxEntries]
  /// entrées les plus récentes.
  static Future<void> save(String projectId, List<String> history) async {
    try {
      final file = await _fileFor(projectId);
      final capped = history.length > _maxEntries
          ? history.sublist(history.length - _maxEntries)
          : history;
      await file.writeAsString(jsonEncode(capped));
    } catch (_) {
      // Échec silencieux : pas critique pour le fonctionnement du terminal
    }
  }
}
