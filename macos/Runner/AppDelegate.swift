import Cocoa
import FlutterMacOS

@NSApplicationMain
class AppDelegate: FlutterAppDelegate {

    override func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // PulseProjects lance plusieurs fenêtres (lanceur + browsers
        // indépendants en mode --project=<id>) : ne pas quitter l'app
        // tant qu'au moins une fenêtre existe, mais laisser chaque
        // process être un binaire séparé gère déjà l'indépendance —
        // ici on garde le comportement standard d'une app desktop.
        return true
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)

        // Enregistrement du plugin WebView custom (WKWebView +
        // WKWebsiteDataStore isolé par profil). Les autres plugins
        // (window_manager, file_selector, etc.) sont enregistrés
        // automatiquement par le générateur Flutter dans
        // GeneratedPluginRegistrant.swift — ne pas le dupliquer ici.
        if let controller = mainFlutterWindow?.contentViewController
            as? FlutterViewController {
            PulseWebViewPlugin.register(
                with: controller.registrar(forPlugin: "PulseWebViewPlugin")
            )
        }
    }
}
