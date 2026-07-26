import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/browser_history_entry.dart';
import 'android_browser_history_store.dart';
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
  final _urlCtrl  = TextEditingController();
  final _urlFocus = FocusNode();
  bool _loading = true;

  // ── Historique de navigation (persistant, par profil) ──────────────────────
  bool _showHistory = false;
  List<BrowserHistoryEntry> _history = [];

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = widget.profile.homeUrl;
    _loadHistory();

    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() { _loading = true; });
          if (!_urlFocus.hasFocus) _urlCtrl.text = url;
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() { _loading = false; });
          if (!_urlFocus.hasFocus) _urlCtrl.text = url;
          String pageTitle = '';
          try {
            final raw = await _ctrl.runJavaScriptReturningResult('document.title');
            pageTitle = raw.toString().replaceAll('"', '').trim();
          } catch (_) {}
          _recordVisit(url, pageTitle);
        },
      ))
      ..loadRequest(Uri.parse(widget.profile.homeUrl));
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  // ── Historique ───────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    final history = await AndroidBrowserHistoryStore.load(widget.profile.id);
    if (mounted) setState(() => _history = history);
  }

  Future<void> _recordVisit(String url, String title) async {
    if (url.isEmpty) return;
    final entry = BrowserHistoryEntry(url: url, title: title, visitedAt: DateTime.now());
    final updated = await AndroidBrowserHistoryStore.append(widget.profile.id, entry);
    if (mounted) setState(() => _history = updated);
  }

  Future<void> _clearHistory() async {
    await AndroidBrowserHistoryStore.clear(widget.profile.id);
    if (mounted) setState(() => _history = []);
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
            tooltip: _showHistory ? 'Fermer l\'historique' : 'Historique de navigation',
            icon: Icon(_showHistory ? Icons.history : Icons.history_outlined),
            onPressed: () => setState(() => _showHistory = !_showHistory),
          ),
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
                focusNode:  _urlFocus,
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
        if (_showHistory)
          _MobileHistoryPanel(
            entries: _history,
            onOpen: (url) {
              _urlCtrl.text = url;
              _navigate();
              setState(() => _showHistory = false);
            },
            onClear: _clearHistory,
            onClose: () => setState(() => _showHistory = false),
          ),
        Expanded(child: WebViewWidget(controller: _ctrl)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panneau Historique (mobile)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileHistoryPanel extends StatelessWidget {
  final List<BrowserHistoryEntry> entries;
  final ValueChanged<String> onOpen;
  final VoidCallback onClear;
  final VoidCallback onClose;

  const _MobileHistoryPanel({
    required this.entries,
    required this.onOpen,
    required this.onClear,
    required this.onClose,
  });

  static String _formatTime(DateTime dt) {
    final d = dt.toLocal();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(Icons.history, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Historique (${entries.length})',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
            if (entries.isNotEmpty)
              TextButton.icon(
                onPressed: onClear,
                icon:  const Icon(Icons.delete_outline, size: 15),
                label: const Text('Effacer', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Fermer',
              onPressed: onClose,
            ),
          ]),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('Aucune page visitée pour le moment.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount:  entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                final label = e.title.isNotEmpty ? e.title : e.url;
                return InkWell(
                  onTap: () => onOpen(e.url),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.public, size: 14, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5)),
                            Text(e.url, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_formatTime(e.visitedAt),
                          style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
                    ]),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }
}
