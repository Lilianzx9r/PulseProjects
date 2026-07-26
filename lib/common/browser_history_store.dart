import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'browser_history_entry.dart';

/// Persiste l'historique des pages visitées dans la fenêtre navigateur,
/// par profil, sur disque :
///   • Windows : %APPDATA%\PulseProjects\browser_history\<id>.json
///   • macOS   : ~/Library/Application Support/PulseProjects/browser_history/<id>.json
///
/// Stocké en dehors du dossier de profil web (userDataFolder WebView2) :
/// ainsi « Réinitialiser les données » (qui efface cookies/cache) n'efface
/// pas l'historique de navigation, qui est une donnée applicative distincte
/// gérée par PulseProjects lui-même, pas par le moteur WebView.
class BrowserHistoryStore {
  BrowserHistoryStore._();

  static const _maxEntries = 500;

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

    final dir = Directory(p.join(base.path, 'browser_history'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fileFor(String projectId) async {
    final dir = await _historyDir();
    return File(p.join(dir.path, '$projectId.json'));
  }

  /// Charge l'historique sauvegardé pour [projectId], le plus récent en
  /// premier, ou une liste vide si aucun historique n'existe encore
  /// (échec silencieux en cas d'erreur de lecture : l'historique n'est
  /// qu'un confort, pas critique).
  static Future<List<BrowserHistoryEntry>> load(String projectId) async {
    try {
      final file = await _fileFor(projectId);
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => BrowserHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Ajoute [entry] à l'historique de [projectId] et sauvegarde,
  /// tronqué aux [_maxEntries] entrées les plus récentes. Si la dernière
  /// entrée pointe déjà vers la même URL (rechargement, watcher SPA
  /// redondant…), elle est simplement mise à jour plutôt que dupliquée.
  static Future<List<BrowserHistoryEntry>> append(
    String projectId,
    BrowserHistoryEntry entry,
  ) async {
    try {
      final current = await load(projectId);
      if (current.isNotEmpty && current.first.url == entry.url) {
        current[0] = entry;
      } else {
        current.insert(0, entry);
      }
      final capped = current.length > _maxEntries
          ? current.sublist(0, _maxEntries)
          : current;
      final file = await _fileFor(projectId);
      await file.writeAsString(
          jsonEncode(capped.map((e) => e.toJson()).toList()));
      return capped;
    } catch (_) {
      return load(projectId);
    }
  }

  /// Efface tout l'historique de [projectId].
  static Future<void> clear(String projectId) async {
    try {
      final file = await _fileFor(projectId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Échec silencieux : pas critique
    }
  }
}
