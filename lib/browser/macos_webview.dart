import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrapper autour du PlatformView natif macOS (`PulseWebViewPlugin.swift`)
/// qui expose un WKWebView avec WKWebsiteDataStore isolé et persistant
/// par profil (`WKWebsiteDataStore.dataStore(forIdentifier:)`, macOS 14+).
///
/// Utilisé uniquement quand `Platform.isMacOS` est vrai — sur Windows,
/// `BrowserView` continue d'utiliser `webview_win_floating` directement.
///
/// API volontairement similaire à `WinWebViewController` pour minimiser
/// les divergences de code dans browser_view.dart.
class MacWebViewController {
  final int _viewId;
  late final MethodChannel _channel;
  late final EventChannel  _events;
  StreamSubscription? _eventSub;

  final _urlController     = StreamController<String>.broadcast();
  final _titleController   = StreamController<String>.broadcast();
  final _loadingController = StreamController<bool>.broadcast();

  Stream<String> get onUrlChanged     => _urlController.stream;
  Stream<String> get onTitleChanged   => _titleController.stream;
  Stream<bool>   get onLoadingChanged => _loadingController.stream;

  MacWebViewController(this._viewId) {
    final base = 'com.pulseprojects/webview/$_viewId';
    _channel = MethodChannel(base);
    _events  = EventChannel('$base/events');
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['type']) {
      case 'pageStarted':
        _loadingController.add(true);
        if (map['url'] != null) _urlController.add(map['url'] as String);
      case 'urlChanged':
        if (map['url'] != null) _urlController.add(map['url'] as String);
      case 'pageFinished':
        _loadingController.add(false);
        if (map['url'] != null)   _urlController.add(map['url'] as String);
        if (map['title'] != null) _titleController.add(map['title'] as String);
      case 'error':
        _loadingController.add(false);
        if (kDebugMode) debugPrint('[MacWebView] ${map['message']}');
    }
  }

  Future<void> loadUrl(String url) =>
      _channel.invokeMethod('loadUrl', {'url': url});

  Future<String?> currentUrl() =>
      _channel.invokeMethod<String>('currentUrl');

  Future<void> goBack()    => _channel.invokeMethod('goBack');
  Future<void> goForward() => _channel.invokeMethod('goForward');
  Future<void> reload()    => _channel.invokeMethod('reload');
  Future<void> stop()      => _channel.invokeMethod('stopLoading');

  Future<void> runJavaScript(String script) =>
      _channel.invokeMethod('runJavaScript', {'script': script});

  Future<String?> runJavaScriptReturningResult(String script) =>
      _channel.invokeMethod<String>('runJavaScriptReturningResult', {'script': script});

  void dispose() {
    _eventSub?.cancel();
    _urlController.close();
    _titleController.close();
    _loadingController.close();
  }
}

/// Widget Flutter qui héberge le PlatformView natif macOS et fournit
/// son [MacWebViewController] via [onCreated].
class MacWebView extends StatefulWidget {
  final String projectId;   // UUID — utilisé pour WKWebsiteDataStore isolé
  final String homeUrl;
  final void Function(MacWebViewController controller) onCreated;

  const MacWebView({
    super.key,
    required this.projectId,
    required this.homeUrl,
    required this.onCreated,
  });

  @override
  State<MacWebView> createState() => _MacWebViewState();
}

class _MacWebViewState extends State<MacWebView> {
  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: 'com.pulseprojects/webview',
      creationParams: {
        'projectId': widget.projectId,
        'homeUrl':   widget.homeUrl,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        widget.onCreated(MacWebViewController(id));
      },
    );
  }
}
