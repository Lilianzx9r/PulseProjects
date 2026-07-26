import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../common/app_settings.dart';
import '../common/process_tracker.dart';
import '../common/script_store.dart';
import '../common/terminal_history_store.dart';
import '../common/terminal_launcher.dart';
import '../launcher/data/project_repository.dart';
import '../launcher/models/project.dart';
import 'download_notification_panel.dart';
import 'macos_webview.dart';
import 'script_editor_dialog.dart';
import 'terminal_pane.dart';

/// Navigateur isolé pour macOS, basé sur le plugin Swift custom
/// (`PulseWebViewPlugin.swift`) qui expose un WKWebView avec
/// WKWebsiteDataStore isolé par profil (cookies, localStorage,
/// IndexedDB séparés entre profils, persistants entre lancements).
///
/// Contrairement à la version Windows (`browser_view.dart`), WKWebView
/// est un VRAI NSView embarqué dans la hiérarchie Flutter — les menus
/// popup, dialogs et tooltips Flutter s'affichent normalement par
/// dessus, sans le problème de Z-order rencontré avec webview_win_floating
/// (fenêtre Win32 flottante au-dessus du compositor Flutter). L'UI peut
/// donc utiliser des PopupMenuButton classiques.
class BrowserViewMacOS extends StatefulWidget {
  final Project project;
  const BrowserViewMacOS({super.key, required this.project});

  @override
  State<BrowserViewMacOS> createState() => _BrowserViewMacOSState();
}

class _BrowserViewMacOSState extends State<BrowserViewMacOS> with WindowListener, DownloadWatcherMixin<BrowserViewMacOS> {
  MacWebViewController? _ctrl;
  final _urlCtrl = TextEditingController();

  bool _loading = true;
  StreamSubscription? _urlSub, _titleSub, _loadingSub;

  // ── Terminal intégré ─────────────────────────────────────────────────────
  bool   _showTerm  = false;
  double _termH     = 220.0;
  int    _termKey   = 0;
  List<String> _termHistory = [];
  bool   _showScript = false;

  static const _termHMin = 80.0;
  static const _termHMax = 600.0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    ProcessTracker.writePid(widget.project.id);
    _loadTerminalHistory();
    _initWatcher();
  }

  Future<void> _initWatcher() async {
    final settings = await AppSettingsStore.load();
    if (mounted) await startWatcher(settings);
  }

  Future<void> _loadTerminalHistory() async {
    final history = await TerminalHistoryStore.load(widget.project.id);
    if (mounted && history.isNotEmpty) {
      setState(() => _termHistory = history);
    }
  }

  @override
  void onWindowClose() async {
    await ProcessTracker.deletePid(widget.project.id);
    await windowManager.destroy();
  }

  void _onWebViewCreated(MacWebViewController ctrl) {
    _ctrl = ctrl;
    _urlSub = ctrl.onUrlChanged.listen((u) {
      if (mounted) setState(() => _urlCtrl.text = u);
    });
    _titleSub = ctrl.onTitleChanged.listen((t) {
      windowManager.setTitle(t.isNotEmpty ? '${widget.project.name} – $t' : widget.project.name);
    });
    _loadingSub = ctrl.onLoadingChanged.listen((l) {
      if (mounted) setState(() => _loading = l);
    });
  }

  void _navigate() {
    var v = _urlCtrl.text.trim();
    if (v.isEmpty) return;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
    _ctrl?.loadUrl(v);
  }

  // ── Script personnalisé ──────────────────────────────────────────────────
  //
  // Même principe que côté Windows (voir browser_view.dart) : la fenêtre
  // navigateur tourne dans un process séparé du lanceur, donc toute
  // modification du script doit être persistée directement sur disque via
  // ProjectRepository. Panneau inline (pas de Dialog) pour rester cohérent
  // avec la version Windows, même si macOS n'a pas de problème de Z-order.

  final _repo = ProjectRepository();

  Future<void> _saveScript(String content, String? folder) async {
    final all = await _repo.loadProjects();
    final idx = all.indexWhere((p) => p.id == widget.project.id);
    if (idx != -1) {
      all[idx].scriptContent = content;
      all[idx].scriptFolder  = folder;
      await _repo.saveProjects(all);
    }
    widget.project.scriptContent = content;
    widget.project.scriptFolder  = folder;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Script enregistré'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _executeScript(String content, String? folder) async {
    await _saveScript(content, folder);

    final scriptPath = await ScriptStore.write(widget.project.id, content);
    final execFolder = folder ?? widget.project.workFolder;
    final ok = runScriptFile(scriptPath: scriptPath, workFolder: execFolder);

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible de lancer le script.')),
      );
    }
  }

  @override
  void dispose() {
    _urlSub?.cancel();
    _titleSub?.cancel();
    _loadingSub?.cancel();
    stopWatcher();
    windowManager.removeListener(this);
    ProcessTracker.deletePid(widget.project.id);
    _ctrl?.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          _Toolbar(
            loading:     _loading,
            urlCtrl:     _urlCtrl,
            showTerm:    _showTerm,
            onBack:      () => _ctrl?.goBack(),
            onForward:   () => _ctrl?.goForward(),
            onReload:    () => _ctrl?.reload(),
            onStop:      () => _ctrl?.stop(),
            onNavigate:  _navigate,
            onToggleTerm: () => setState(() => _showTerm = !_showTerm),
            workFolder:  widget.project.workFolder,
            onLaunchTerminal: (asAdmin) =>
                launchTerminal(kind: TerminalKind.cmd, asAdmin: asAdmin, workFolder: widget.project.workFolder),
            onScript: () => setState(() => _showScript = !_showScript),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          // Tous les panneaux optionnels sont placés APRÈS la WebView dans
          // la Column interne (jamais avant), par cohérence structurelle
          // avec la version Windows — bien que macOS (WKWebView, vrai
          // NSView Flutter) n'ait pas le problème de repositionnement HWND
          // qui impose cette contrainte sur Windows.
          Expanded(
            child: Column(children: [
              Expanded(
                child: MacWebView(
                  projectId: widget.project.id,
                  homeUrl:   widget.project.homeUrl,
                  onCreated: _onWebViewCreated,
                ),
              ),
              if (_showScript)
                ScriptPanel(
                  projectName:    widget.project.name,
                  initialContent: widget.project.scriptContent,
                  initialFolder:  widget.project.scriptFolder ?? widget.project.workFolder,
                  onSave:         _saveScript,
                  onExecute:      _executeScript,
                  onClose:        () => setState(() => _showScript = false),
                ),
              if (_showTerm) ...[
                _TerminalHeaderMac(
                  termHeight: _termH,
                  workDir:    widget.project.workFolder,
                  onDrag:     (dy) => setState(() => _termH = (_termH - dy).clamp(_termHMin, _termHMax)),
                  onRestart:  () => setState(() => _termKey++),
                  onClose:    () => setState(() => _showTerm = false),
                ),
                SizedBox(
                  height: _termH,
                  child: TerminalPane(
                    key:     ValueKey('mac_term_$_termKey'),
                    isCmd:   false, // sur macOS : lance zsh (voir terminal_pane.dart)
                    workDir: widget.project.workFolder,
                    initialHistory: _termHistory,
                    onHistoryChanged: (h) {
                      _termHistory = h;
                      TerminalHistoryStore.save(widget.project.id, h);
                    },
                  ),
                ),
              ],
            ]),
          ),
          buildNotifPanel(),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toolbar — peut utiliser PopupMenuButton normalement (pas de Z-order issue)
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final bool loading, showTerm;
  final TextEditingController urlCtrl;
  final VoidCallback onBack, onForward, onReload, onStop, onNavigate, onToggleTerm, onScript;
  final String? workFolder;
  final void Function(bool asAdmin) onLaunchTerminal;

  const _Toolbar({
    required this.loading, required this.showTerm, required this.urlCtrl,
    required this.onBack, required this.onForward, required this.onReload,
    required this.onStop, required this.onNavigate, required this.onToggleTerm,
    required this.workFolder, required this.onLaunchTerminal, required this.onScript,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back),    tooltip: 'Précédent', onPressed: onBack),
        IconButton(icon: const Icon(Icons.arrow_forward), tooltip: 'Suivant',   onPressed: onForward),
        IconButton(
          icon: Icon(loading ? Icons.close : Icons.refresh),
          tooltip: loading ? 'Arrêter' : 'Recharger',
          onPressed: loading ? onStop : onReload,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: urlCtrl,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
              hintText: 'URL ou recherche…',
            ),
            onSubmitted: (_) => onNavigate(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(icon: const Icon(Icons.arrow_circle_right_outlined), tooltip: 'Aller', onPressed: onNavigate),
        const SizedBox(width: 4),
        Tooltip(
          message: showTerm ? 'Fermer le terminal intégré' : 'Ouvrir un terminal intégré',
          child: IconButton(
            icon:  Icon(showTerm ? Icons.terminal : Icons.terminal_outlined),
            style: showTerm ? IconButton.styleFrom(backgroundColor: cs.primaryContainer) : null,
            color: showTerm ? cs.primary : null,
            onPressed: onToggleTerm,
          ),
        ),
        // PopupMenuButton normal : pas de problème de Z-order sur macOS
        PopupMenuButton<bool>(
          tooltip: 'Ouvrir Terminal.app (zsh/sudo)',
          icon: const Icon(Icons.open_in_new_outlined),
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: false, child: Text('Terminal.app')),
            const PopupMenuItem(value: true,  child: Text('Terminal.app (sudo)')),
          ],
          onSelected: onLaunchTerminal,
        ),
        // Bouton Script personnalisé (éditable, dossier d'exécution configurable)
        IconButton(
          tooltip: 'Script personnalisé',
          icon: const Icon(Icons.integration_instructions_outlined),
          onPressed: onScript,
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// En-tête terminal intégré macOS
// ─────────────────────────────────────────────────────────────────────────────

class _TerminalHeaderMac extends StatelessWidget {
  final double termHeight;
  final String? workDir;
  final void Function(double dy) onDrag;
  final VoidCallback onRestart, onClose;

  const _TerminalHeaderMac({
    required this.termHeight, required this.workDir,
    required this.onDrag, required this.onRestart, required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          child: Container(
            height: 8,
            color: const Color(0xFF2D2D2D),
            child: Center(
              child: Container(
                width: 40, height: 3,
                decoration: BoxDecoration(color: const Color(0xFF666666), borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
        ),
      ),
      Container(
        height: 32,
        color: const Color(0xFF2D2D2D),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          const Text('zsh', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (workDir?.isNotEmpty == true) ...[
            const Icon(Icons.folder_outlined, size: 12, color: Color(0xFF999999)),
            const SizedBox(width: 4),
            Expanded(child: Text(workDir!, style: const TextStyle(fontSize: 11, color: Color(0xFF999999)), overflow: TextOverflow.ellipsis)),
          ] else const Spacer(),
          IconButton(icon: const Icon(Icons.replay, size: 16, color: Color(0xFF999999)), onPressed: onRestart, tooltip: 'Redémarrer'),
          IconButton(icon: const Icon(Icons.close,  size: 16, color: Color(0xFF999999)), onPressed: onClose,   tooltip: 'Fermer'),
        ]),
      ),
    ]);
  }
}
