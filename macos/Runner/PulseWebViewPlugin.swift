import FlutterMacOS
import WebKit

// ─────────────────────────────────────────────────────────────────────────────
// PulseWebViewPlugin
//
// Plugin Flutter macOS qui expose une vue native WKWebView avec un
// WKWebsiteDataStore isolé et persistant par profil PulseProjects
// (WKWebsiteDataStore(forIdentifier:), disponible depuis macOS 14 = Sonoma).
//
// Sur macOS Tahoe 26 cette API est garantie disponible.
//
// Enregistrement : à appeler depuis MainFlutterWindow.swift ou AppDelegate.swift
//   PulseWebViewPlugin.register(with: registrar)
// ─────────────────────────────────────────────────────────────────────────────

public class PulseWebViewPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let factory = PulseWebViewFactory(messenger: registrar.messenger)
        registrar.register(factory, withId: "com.pulseprojects/webview")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Factory : crée une PulseWebViewNSView par ID de vue Flutter
// ─────────────────────────────────────────────────────────────────────────────

class PulseWebViewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withViewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> NSView {
        let params = args as? [String: Any] ?? [:]
        let projectId = params["projectId"] as? String ?? ""
        let homeUrl   = params["homeUrl"]   as? String ?? "about:blank"
        return PulseWebViewNSView(
            viewId:    viewId,
            projectId: projectId,
            homeUrl:   homeUrl,
            messenger: messenger
        )
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NSView conteneur + WKWebView + canaux Flutter
// ─────────────────────────────────────────────────────────────────────────────

class PulseWebViewNSView: NSView {

    private let wk:            WKWebView
    private let methodChannel: FlutterMethodChannel
    private let eventChannel:  FlutterEventChannel
    private var eventSink:     FlutterEventSink?

    init(
        viewId:    Int64,
        projectId: String,
        homeUrl:   String,
        messenger: FlutterBinaryMessenger
    ) {
        // ── Création de la configuration WebView avec data store isolé ──────
        let config = WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            if let uuid = UUID(uuidString: projectId) {
                config.websiteDataStore = WKWebsiteDataStore.dataStore(
                    forIdentifier: uuid
                )
            }
        }

        wk = WKWebView(frame: .zero, configuration: config)
        wk.translatesAutoresizingMaskIntoConstraints = false

        let baseName = "com.pulseprojects/webview/\(viewId)"
        methodChannel = FlutterMethodChannel(
            name:             baseName,
            binaryMessenger:  messenger
        )
        eventChannel = FlutterEventChannel(
            name:             "\(baseName)/events",
            binaryMessenger:  messenger
        )

        super.init(frame: .zero)

        // Embeds WKWebView en remplissant toute la vue
        addSubview(wk)
        NSLayoutConstraint.activate([
            wk.topAnchor.constraint(equalTo: topAnchor),
            wk.bottomAnchor.constraint(equalTo: bottomAnchor),
            wk.leadingAnchor.constraint(equalTo: leadingAnchor),
            wk.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        wk.navigationDelegate = self
        methodChannel.setMethodCallHandler(handle)
        eventChannel.setStreamHandler(self)

        // Chargement initial
        if let url = URL(string: homeUrl) {
            wk.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── Gestionnaire de méthodes Flutter → WebView ────────────────────────

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "loadUrl":
            guard let args = call.arguments as? [String: Any],
                  let urlStr = args["url"] as? String,
                  let url = URL(string: urlStr) else {
                result(FlutterError(code: "INVALID_URL", message: nil, details: nil))
                return
            }
            wk.load(URLRequest(url: url))
            result(nil)

        case "currentUrl":
            result(wk.url?.absoluteString)

        case "getTitle":
            result(wk.title)

        case "goBack":
            wk.goBack();   result(nil)

        case "goForward":
            wk.goForward(); result(nil)

        case "reload":
            wk.reload();   result(nil)

        case "stopLoading":
            wk.stopLoading(); result(nil)

        case "runJavaScript":
            guard let args = call.arguments as? [String: Any],
                  let script = args["script"] as? String else {
                result(nil); return
            }
            wk.evaluateJavaScript(script) { _, _ in }
            result(nil)

        case "runJavaScriptReturningResult":
            guard let args = call.arguments as? [String: Any],
                  let script = args["script"] as? String else {
                result(nil); return
            }
            wk.evaluateJavaScript(script) { value, error in
                if let error = error {
                    result(FlutterError(
                        code: "JS_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                } else {
                    // Convertir les types JS → types Flutter/Dart
                    result(value.map { "\($0)" } ?? NSNull())
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WKNavigationDelegate → émission d'événements vers Dart
// ─────────────────────────────────────────────────────────────────────────────

extension PulseWebViewNSView: WKNavigationDelegate {

    func webView(_ wv: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        emit(["type": "pageStarted", "url": wv.url?.absoluteString ?? ""])
    }

    func webView(_ wv: WKWebView, didCommit _: WKNavigation!) {
        emit(["type": "urlChanged", "url": wv.url?.absoluteString ?? ""])
    }

    func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        emit(["type": "pageFinished", "url": wv.url?.absoluteString ?? "",
              "title": wv.title ?? ""])
    }

    func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        emit(["type": "error", "message": error.localizedDescription])
    }

    func webView(
        _ wv: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    private func emit(_ event: [String: String]) {
        DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterStreamHandler → eventSink pour les événements de navigation
// ─────────────────────────────────────────────────────────────────────────────

extension PulseWebViewNSView: FlutterStreamHandler {

    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
