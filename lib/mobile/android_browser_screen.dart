import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'android_profile.dart';
import 'android_profile_picker_screen.dart';
import 'android_profile_repository.dart';

/// État d'un onglet du navigateur mobile : un WebViewController dédié
/// (même profil Android que les autres onglets → session/cookies
/// partagés, cf. WebView.setDataDirectorySuffix() appliqué une fois par
/// process), sa barre d'URL et son statut de chargement.
class _MobileTab {
  _MobileTab({required this.id, required this.homeUrl});

  final String id;
  final String homeUrl;

  late final WebViewController ctrl;
  final TextEditingController urlCtrl  = TextEditingController();
  final FocusNode              urlFocus = FocusNode();

  bool loading = true;
  String title = '';
}

/// Navigateur plein écran pour le profil Android actif. Le contexte
/// (cookies, session, stockage local…) est persistant grâce au suffixe
/// WebView.setDataDirectorySuffix() appliqué côté natif au démarrage du
/// process (voir PulseApplication.kt), correspondant à [profile.id].
/// Plusieurs onglets peuvent être ouverts simultanément dans ce même
/// profil : ils partagent tous le même contexte de session.
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
  final List<_MobileTab> _tabs = [];
  int _activeIndex = 0;

  _MobileTab get _active => _tabs[_activeIndex];

  @override
  void initState() {
    super.initState();
    _openTab(widget.profile.homeUrl, activate: true);
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.urlCtrl.dispose();
      tab.urlFocus.dispose();
    }
    super.dispose();
  }

  // ── Onglets ──────────────────────────────────────────────────────────────

  void _openTab(String url, {bool activate = true}) {
    final tab = _MobileTab(
      id:      '${DateTime.now().microsecondsSinceEpoch}',
      homeUrl: url,
    );
    tab.urlCtrl.text = url;
    tab.ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (u) {
          if (!mounted) return;
          setState(() { tab.loading = true; });
          if (!tab.urlFocus.hasFocus) tab.urlCtrl.text = u;
        },
        onPageFinished: (u) async {
          if (!mounted) return;
          setState(() { tab.loading = false; });
          if (!tab.urlFocus.hasFocus) tab.urlCtrl.text = u;
          try {
            final raw = await tab.ctrl.runJavaScriptReturningResult('document.title');
            final t   = raw.toString().replaceAll('"', '').trim();
            if (mounted) setState(() => tab.title = t);
          } catch (_) {}
        },
      ))
      ..loadRequest(Uri.parse(url));

    setState(() {
      _tabs.add(tab);
      if (activate) _activeIndex = _tabs.length - 1;
    });
  }

  void _addTab() => _openTab(widget.profile.homeUrl, activate: true);

  void _selectTab(int i) {
    if (i == _activeIndex) return;
    setState(() => _activeIndex = i);
  }

  void _closeTab(int i) {
    if (_tabs.length <= 1) {
      // Fermer le dernier onglet quitte le navigateur, comme un retour
      // au sélecteur de profil.
      _changeProfile();
      return;
    }
    setState(() {
      _tabs[i].urlCtrl.dispose();
      _tabs[i].urlFocus.dispose();
      _tabs.removeAt(i);
      if (_activeIndex >= _tabs.length) {
        _activeIndex = _tabs.length - 1;
      } else if (i < _activeIndex) {
        _activeIndex--;
      }
    });
  }

  void _navigate() {
    var v = _active.urlCtrl.text.trim();
    if (v.isEmpty) return;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
    _active.ctrl.loadRequest(Uri.parse(v));
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
    if (_tabs.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
        _MobileTabStrip(
          tabs:        _tabs,
          activeIndex: _activeIndex,
          onSelect:    _selectTab,
          onClose:     _closeTab,
          onAdd:       _addTab,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Précédent',
              onPressed: () => _active.ctrl.goBack(),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: 'Suivant',
              onPressed: () => _active.ctrl.goForward(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Recharger',
              onPressed: () => _active.ctrl.reload(),
            ),
            Expanded(
              child: TextField(
                controller: _active.urlCtrl,
                focusNode:  _active.urlFocus,
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
        if (_active.loading) const LinearProgressIndicator(minHeight: 2),
        // IndexedStack conserve tous les WebView montés (au lieu de les
        // recréer à chaque changement d'onglet) : contrairement au port
        // Windows, webview_flutter (WebView Android natif) n'a pas de
        // contrainte de Z-order avec des vues natives flottantes, donc
        // garder plusieurs WebView vivantes simultanément est sûr et
        // évite de perdre la position de défilement ou l'état de la page
        // en changeant d'onglet.
        Expanded(
          child: IndexedStack(
            index: _activeIndex,
            children: [
              for (final tab in _tabs) WebViewWidget(controller: tab.ctrl),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Barre d'onglets (mobile)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileTabStrip extends StatelessWidget {
  final List<_MobileTab> tabs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onAdd;

  const _MobileTabStrip({
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      color: cs.surfaceContainerHighest,
      child: Row(children: [
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount:       tabs.length,
            itemBuilder: (context, i) {
              final tab      = tabs[i];
              final selected = i == activeIndex;
              final label = tab.title.isNotEmpty
                  ? tab.title
                  : (tab.urlCtrl.text.isNotEmpty ? tab.urlCtrl.text : 'Nouvel onglet');

              return GestureDetector(
                onTap: () => onSelect(i),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 100, maxWidth: 160),
                  margin:  const EdgeInsets.only(right: 2, top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: selected ? cs.surface : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                  child: Row(children: [
                    if (tab.loading)
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
                      )
                    else
                      Icon(Icons.public, size: 13, color: cs.onSurfaceVariant),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize:   11,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    InkWell(
                      onTap: () => onClose(i),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
        IconButton(
          icon:    const Icon(Icons.add, size: 18),
          tooltip: 'Nouvel onglet',
          onPressed: onAdd,
        ),
      ]),
    );
  }
}
