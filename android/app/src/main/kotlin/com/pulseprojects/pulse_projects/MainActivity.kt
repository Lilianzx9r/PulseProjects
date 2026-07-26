package com.pulseprojects.pulse_projects

import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Expose un canal Flutter ("com.pulseprojects/app_control", méthode
 * "restart") permettant de redémarrer complètement l'application.
 *
 * Nécessaire pour appliquer un changement de profil : voir
 * PulseApplication.kt — WebView.setDataDirectorySuffix() ne peut être
 * appelée qu'une seule fois par process, avant toute création de WebView.
 */
/**
 * Expose un canal Flutter ("com.pulseprojects/app_control") avec deux
 * méthodes :
 *   • "restart"     — redémarre complètement l'application (changement de
 *     profil, voir PulseApplication.kt)
 *   • "getDataDir"  — retourne le chemin absolu du dossier de données
 *     privé de l'app (`applicationInfo.dataDir`, ex:
 *     `/data/data/com.pulseprojects.pulse_projects`). Utilisé côté Dart
 *     pour localiser le dossier `app_webview_<profileId>` de chaque
 *     profil (export/import) : ce dossier est dans le stockage privé de
 *     l'app, donc lisible/inscriptible par notre propre process (même
 *     UID) sans permission particulière, mais son chemin exact n'est
 *     pas exposé nativement par path_provider.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.pulseprojects/app_control"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "restart" -> {
                        restartApp()
                        result.success(null)
                    }
                    "getDataDir" -> {
                        result.success(applicationInfo.dataDir)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Relance une nouvelle instance de l'activité principale dans une
     * intention "propre" (CLEAR_TOP + NEW_TASK), puis termine le process
     * courant. Le prochain démarrage de PulseApplication lira le profil
     * actif fraîchement enregistré dans SharedPreferences et appliquera
     * le bon suffixe WebView.
     */
    private fun restartApp() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        intent?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        Runtime.getRuntime().exit(0)
    }
}
