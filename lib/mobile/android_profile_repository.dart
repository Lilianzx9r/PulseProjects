import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_profile.dart';

/// Persistance des profils Android :
///   • Liste complète des profils (nom, URL) → fichier JSON classique,
///     via path_provider (dossier de données propre à l'app).
///   • Identifiant du profil ACTIF → SharedPreferences, car c'est la
///     SEULE donnée qui doit être lisible depuis le code natif Kotlin
///     (PulseApplication.onCreate(), avant même le démarrage du moteur
///     Flutter) pour appliquer WebView.setDataDirectorySuffix() au bon
///     moment. Le plugin shared_preferences stocke ses valeurs dans le
///     fichier SharedPreferences Android nommé "FlutterSharedPreferences",
///     avec un préfixe de clé "flutter." — voir PulseApplication.kt qui
///     lit directement cette clé.
class AndroidProfileRepository {
  static const _kCurrentProfileKey = 'current_profile_id';

  Future<File> get _file async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'android_profiles.json'));
  }

  Future<List<AndroidProfile>> load() async {
    final file = await _file;
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => AndroidProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> save(List<AndroidProfile> profiles) async {
    final file = await _file;
    await file.writeAsString(
        jsonEncode(profiles.map((e) => e.toJson()).toList()));
  }

  /// Identifiant du profil actuellement actif (celui dont le suffixe a été
  /// appliqué à WebView.setDataDirectorySuffix() par le code natif au
  /// démarrage du process), ou null si aucun.
  Future<String?> getCurrentProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kCurrentProfileKey);
  }

  /// Définit le profil actif. À appeler AVANT un redémarrage de
  /// l'application (voir AndroidAppControl.restart()) : le nouveau
  /// suffixe WebView ne sera appliqué qu'au prochain démarrage du process,
  /// jamais en cours d'exécution (limitation de l'API Android).
  Future<void> setCurrentProfileId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentProfileKey, id);
  }
}
