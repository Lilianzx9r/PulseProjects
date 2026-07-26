import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Serveur HTTP minimal sur 127.0.0.1 (port aléatoire) qui reçoit les
/// requêtes du script JS injecté dans WebView2.
///
/// Le JS injecté dans les pages utilise `fetch('http://127.0.0.1:<port>/dl', …)`
/// pour envoyer les données de téléchargement à Dart.
/// Cette approche est bien plus fiable que `window.chrome.webview.postMessage`
/// car elle repose uniquement sur fetch() standard, toujours disponible.
class DownloadServer {
  HttpServer? _server;
  int _port = 0;

  /// Callback appelé avec le JSON parsé de chaque requête POST /dl.
  final void Function(Map<String, dynamic> data) onMessage;

  DownloadServer({required this.onMessage});

  int get port => _port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _serve();
  }

  void _serve() {
    _server!.listen(
      _handleRequest,
      onError: (_) {}, // ignore les erreurs réseau
      cancelOnError: false,
    );
  }

  Future<void> _handleRequest(HttpRequest req) async {
    // Headers CORS pour que WebView2 accepte la réponse du fetch() JS
    req.response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'POST, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method == 'OPTIONS') {
      // Preflight CORS
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    if (req.method == 'POST') {
      try {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        onMessage(data);
      } catch (_) {}
    }

    req.response.statusCode = 200;
    await req.response.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
