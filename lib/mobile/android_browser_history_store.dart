import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/browser_history_entry.dart';

/// Persiste l'historique des pages visitées, par profil Android, dans le
/// dossier de données propre à l'app (path_provider) — distinct du
/// contexte WebView (cookies/session), donc non affecté par la
/// réinitialisation des données d'un profil.
class AndroidBrowserHistoryStore {
  AndroidBrowserHistoryStore._();

  static const _maxEntries = 500;

  static Future<File> _fileFor(String profileId) async {
    final dir = await getApplicationSupportDirectory();
    final historyDir = Directory(p.join(dir.path, 'browser_history'));
    if (!await historyDir.exists()) await historyDir.create(recursive: true);
    return File(p.join(historyDir.path, '$profileId.json'));
  }

  /// Charge l'historique sauvegardé pour [profileId], le plus récent en
  /// premier (échec silencieux en cas d'erreur de lecture).
  static Future<List<BrowserHistoryEntry>> load(String profileId) async {
    try {
      final file = await _fileFor(profileId);
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

  /// Ajoute [entry] à l'historique de [profileId], tronqué aux
  /// [_maxEntries] entrées les plus récentes. Met à jour la dernière
  /// entrée au lieu de dupliquer si elle pointe déjà vers la même URL.
  static Future<List<BrowserHistoryEntry>> append(
    String profileId,
    BrowserHistoryEntry entry,
  ) async {
    try {
      final current = await load(profileId);
      if (current.isNotEmpty && current.first.url == entry.url) {
        current[0] = entry;
      } else {
        current.insert(0, entry);
      }
      final capped = current.length > _maxEntries
          ? current.sublist(0, _maxEntries)
          : current;
      final file = await _fileFor(profileId);
      await file.writeAsString(
          jsonEncode(capped.map((e) => e.toJson()).toList()));
      return capped;
    } catch (_) {
      return load(profileId);
    }
  }

  /// Efface tout l'historique de [profileId].
  static Future<void> clear(String profileId) async {
    try {
      final file = await _fileFor(profileId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Échec silencieux : pas critique
    }
  }
}
