package com.pulseprojects.pulse_projects

import android.app.Application
import android.content.SharedPreferences
import android.webkit.WebView

/**
 * Application Android personnalisée pour PulseProjects.
 *
 * Applique WebView.setDataDirectorySuffix() AVANT toute création de
 * WebView dans ce process — condition impérative de cette API (Android 9+
 * / API 28). Le suffixe correspond à l'identifiant du profil actif,
 * persisté par le plugin shared_preferences Flutter (fichier Android
 * "FlutterSharedPreferences", clé préfixée "flutter.").
 *
 * Cette méthode ne peut être appelée QU'UNE SEULE FOIS par process : il
 * est impossible de changer de profil "à chaud". Changer de profil
 * nécessite donc un redémarrage complet de l'application — voir
 * MainActivity.kt (canal "restart") et lib/mobile/android_app_control.dart
 * côté Flutter.
 */
class PulseApplication : Application() {

    override fun onCreate() {
        super.onCreate()

        val prefs: SharedPreferences = getSharedPreferences(
            "FlutterSharedPreferences", MODE_PRIVATE
        )
        val profileId = prefs.getString("flutter.current_profile_id", null)

        if (!profileId.isNullOrEmpty()) {
            // Le suffixe ne doit contenir que des caractères sûrs pour un
            // nom de dossier — filtré par sécurité même si l'UI Flutter ne
            // génère que des UUID (lettres, chiffres, tirets).
            val safeSuffix = profileId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            try {
                WebView.setDataDirectorySuffix(safeSuffix)
            } catch (e: IllegalStateException) {
                // Ne devrait jamais se produire : onCreate() de Application
                // n'est exécuté qu'une seule fois par process, et aucune
                // WebView n'a encore pu être créée à ce stade. Ignoré par
                // sécurité plutôt que de faire planter le démarrage.
            }
        }
    }
}
