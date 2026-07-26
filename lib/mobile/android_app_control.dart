import 'package:flutter/services.dart';

/// Pont vers le code natif Android (voir MainActivity.kt) pour :
///   • redémarrer complètement l'application (changement de profil)
///   • récupérer le chemin du dossier de données privé de l'app, utilisé
///     pour localiser le dossier `app_webview_<profileId>` de chaque
///     profil (export/import — voir AndroidExportService).
class AndroidAppControl {
  AndroidAppControl._();

  static const _channel = MethodChannel('com.pulseprojects/app_control');

  static Future<void> restart() => _channel.invokeMethod('restart');

  static Future<String?> getDataDir() => _channel.invokeMethod<String>('getDataDir');
}
