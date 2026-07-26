import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'android_profile.dart';
import 'android_profile_picker_screen.dart';
import 'android_profile_repository.dart';

/// Navigateur plein écran pour le profil Android actif. Le contexte
/// (cookies, session, stockage local…) est persistant grâce au suffixe
/// WebView.setDataDirectorySuffix() appliqué côté natif au démarrage du
/// process (voir PulseApplication.kt), correspondant à [profile.id].
class AndroidBrowserScreen extends StatefulWidget {
  final AndroidProfile profile;
  final AndroidProfileRepository repository;

  const AndroidBrowserScreen({
    super.key,
    required this.profile,
    required this.repository,
  });

  @override
  State<AndroidBrowserScreen> createState() => _AndroidBrowserScreenState();
}

class _AndroidBrowserScreenState extends State<AndroidBrowserScreen> {
  late final WebViewController _ctrl;
  final _urlCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = widget.profile.homeUrl;

    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() { _loading = true; _urlCtrl.text = url; });
        },
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() { _loading = false; _urlCtrl.text = url; });
        },
      ))
      ..loadRequest(Uri.parse(widget.profile.homeUrl));
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _navigate() {
    var v = _urlCtrl.text.trim();
    if (v.isEmpty) return;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
    _ctrl.loadRequest(Uri.parse(v));
  }

  void _changeProfile() {
    // Ne PAS effacer le profil actif ici : tant que l'utilisateur n'a pas
    // réellement choisi un autre profil dans le picker, on veut que le
    // profil courant reste résolu au prochain lancement à froid. Seul
    // AndroidProfilePickerScreen._activate() écrit un nouveau profil actif
    // (et redémarre l'app pour l'appliquer).
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AndroidProfilePickerScreen(repository: widget.repository),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            tooltip: 'Changer de profil',
            icon: const Icon(Icons.switch_account_outlined),
            onPressed: _changeProfile,
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Précédent',
              onPressed: () => _ctrl.goBack(),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: 'Suivant',
              onPressed: () => _ctrl.goForward(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Recharger',
              onPressed: () => _ctrl.reload(),
            ),
            Expanded(
              child: TextField(
                controller: _urlCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                  hintText: 'URL ou recherche…',
                ),
                onSubmitted: (_) => _navigate(),
              ),
            ),
          ]),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: WebViewWidget(controller: _ctrl)),
      ]),
    );
  }
}
