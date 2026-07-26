import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:window_manager/window_manager.dart';

import '../common/app_settings.dart';
import '../common/process_tracker.dart';
import '../common/script_store.dart';
import '../common/terminal_history_store.dart';
import '../common/terminal_launcher.dart';
import '../launcher/data/project_repository.dart';
import '../launcher/models/project.dart';
import 'download_notification_panel.dart';
import 'script_editor_dialog.dart';
import 'terminal_pane.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BrowserView
// ─────────────────────────────────────────────────────────────────────────────

class BrowserView extends StatefulWidget {
  final Project project;
  final String  dataDir;
  const BrowserView({super.key, required this.project, required this.dataDir});

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

/// État d'un onglet du navigateur : un controller WebView2 dédié (même
/// profil que les autres onglets → session/cookies partagés), sa barre
/// d'URL, et son statut de chargement.
class _BrowserTab {
  _BrowserTab({required this.id, required this.homeUrl});

  final String id;
  final String homeUrl;

  WinWebViewController? ctrl;
  final TextEditingController urlCtrl  = TextEditingController();
  final FocusNode             urlFocus = FocusNode();

  bool    loading  = true;
  double  progress = 0;
  String? error;
  String  title    = '';
}

class _BrowserViewState extends State<BrowserView> with WindowListener, DownloadWatcherMixin<BrowserView> {
  final List<_BrowserTab> _tabs = [];
  int _activeIndex = 0;
  Timer? _urlPollTimer;

  _BrowserTab get _active => _tabs[_activeIndex];

  // ── Terminal intégré ───────────────────────────────────────────────────────
  bool   _showTerm  = false;
  bool   _termIsCmd = true;      // true = CMD, false = PowerShell
  double _termH     = 220.0;     // hauteur du panneau terminal
  int    _termKey   = 0;         // incrémenté pour forcer le redémarrage

  // Historique des commandes, conservé ici (survit aux redémarrages du
  // panneau et au switch CMD↔PowerShell, contrairement à l'état interne
  // de TerminalPane qui est recréé via la clé ci-dessus) ET persisté sur
  // disque par projet (survit à la fermeture de la fenêtre browser).
  List<String> _termHistory = [];

  static const _termHMin = 80.0;
  static const _termHMax = 600.0;

  // ── Terminal externe (vraie fenêtre console Windows) ───────────────────────
  //
  // Le terminal intégré utilise de simples pipes stdin/stdout (pas ConPTY,
  // bloqué par certains EDR comme SentinelOne). Il ne peut donc pas afficher
  // correctement les menus interactifs à flèches, ni transmettre les flèches
  // du clavier au processus. Pour ces cas, on ouvre une vraie console Windows
  // (conhost.exe via ShellExecuteW) sur le dossier du projet.
  bool    _showExtBar = false;  // barre inline (pas de popup : Z-order WebView)
  String? _extError;            // message d'erreur transitoire
  bool    _showScript = false;  // panneau inline (même raison Z-order)

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    ProcessTracker.writePid(widget.project.id);
    _loadTerminalHistory();
    _init();
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

  // ── Init WebView / Onglets ───────────────────────────────────────────────
  //
  // Chaque onglet possède son propre WinWebViewController (même profil,
  // même userDataFolder → cookies/session partagés entre onglets, comme
  // dans un navigateur classique). Un seul WinWebViewWidget est monté à la
  // fois (celui de l'onglet actif) : voir la note Z-order dans build() —
  // insérer plusieurs WebView2 flottantes simultanément casserait leur
  // empilement natif. Changer d'onglet ne détruit pas le controller (donc
  // pas de perte de session), seul l'attachement du widget change.

  Future<void> _init() async {
    await _openTab(widget.project.homeUrl, activate: true);

    // Polling URL via JS — plus fiable que currentUrl() qui ne se met
    // pas à jour pour les navigations SPA (history.pushState). Ne
    // concerne que l'onglet actif (seul dont l'URL est affichée).
    _urlPollTimer = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (!mounted || _tabs.isEmpty) return;
      final tab = _active;
      if (tab.ctrl == null) return;
      try {
        final raw = await tab.ctrl!.runJavaScriptReturningResult(
          'window.location.href',
        );
        final url = raw.toString().replaceAll('"', '').trim();
        if (url.isNotEmpty && url.startsWith('http') && url != tab.urlCtrl.text
            && !tab.urlFocus.hasFocus) {
          if (mounted) setState(() => tab.urlCtrl.text = url);
        }
      } catch (_) {}
    });
  }

  /// Crée un nouvel onglet, charge [url], et l'ajoute à la liste. Si
  /// [activate] est vrai (par défaut), l'onglet devient l'onglet actif.
  Future<_BrowserTab> _openTab(String url, {bool activate = true}) async {
    final tab = _BrowserTab(
      id:      '${DateTime.now().microsecondsSinceEpoch}',
      homeUrl: url,
    );
    tab.urlCtrl.text = url;
    try {
      final ctrl = _buildController(tab);
      await ctrl.loadRequest(Uri.parse(url));
      tab.ctrl = ctrl;
    } catch (e) {
      tab.error   = e.toString();
      tab.loading = false;
    }
    if (mounted) {
      setState(() {
        _tabs.add(tab);
        if (activate) _activeIndex = _tabs.length - 1;
      });
    }
    return tab;
  }

  void _addTab() => _openTab(widget.project.homeUrl, activate: true);

  void _selectTab(int i) {
    if (i == _activeIndex) return;
    setState(() => _activeIndex = i);
    _updateWindowTitle();
  }

  void _closeTab(int i) {
    if (_tabs.length <= 1) {
      // Fermer le dernier onglet ferme la fenêtre du navigateur, comme
      // dans un navigateur classique.
      onWindowClose();
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
    _updateWindowTitle();
  }

  Future<void> _retryActiveTab() async {
    final tab = _active;
    setState(() { tab.error = null; tab.loading = true; });
    try {
      final ctrl = _buildController(tab);
      await ctrl.loadRequest(Uri.parse(tab.homeUrl));
      if (!mounted) return;
      setState(() => tab.ctrl = ctrl);
    } catch (e) {
      if (!mounted) return;
      setState(() { tab.error = e.toString(); tab.loading = false; });
    }
  }

  void _updateWindowTitle() {
    if (_tabs.isEmpty) return;
    final t = _active.title;
    windowManager.setTitle(
      t.isNotEmpty ? '${widget.project.name} – $t' : widget.project.name);
  }

  WinWebViewController _buildController(_BrowserTab tab) {
    final params = WindowsWebViewControllerCreationParams(
      userDataFolder: widget.dataDir,
      profileName:    'pulse_${widget.project.id}',
    );
    final ctrl = WinWebViewController.fromPlatformCreationParams(params);
    ctrl
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(WinNavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() { tab.loading = true; tab.progress = 0; });
          if (url.isNotEmpty && !tab.urlFocus.hasFocus) tab.urlCtrl.text = url;
        },
        onProgress: (pct) {
          if (!mounted) return;
          setState(() => tab.progress = pct / 100.0);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() { tab.loading = false; tab.progress = 1.0; });
          if (url.isNotEmpty && !tab.urlFocus.hasFocus) tab.urlCtrl.text = url;
          try {
            final raw = await ctrl.runJavaScriptReturningResult('document.title');
            final t   = raw.toString().replaceAll('"', '').trim();
            if (mounted) setState(() => tab.title = t);
          } catch (_) {}
          if (_tabs.isNotEmpty && identical(tab, _active)) _updateWindowTitle();
          // Watcher SPA : détecte pushState/replaceState/popstate
          // pour mettre à jour l'URL immédiatement sans attendre le poll.
          _injectUrlWatcher(ctrl);
        },
        onWebResourceError: (_) {
          if (mounted) setState(() => tab.loading = false);
        },
      ));
    return ctrl;
  }

  // ── Injection watcher URL (SPA) ──────────────────────────────────────────

  /// Injecte un script JS qui surcharge history.pushState et
  /// history.replaceState pour écrire window.__pulseUrl à chaque
  /// navigation SPA. Le poll lit window.location.href directement,
  /// mais ce watcher garantit la mise à jour immédiate.
  void _injectUrlWatcher(WinWebViewController ctrl) {
    ctrl.runJavaScript(
      '(function(){'
      'if(window.__pulseUrlWatcher)return;'
      'window.__pulseUrlWatcher=true;'
      'var _p=history.pushState.bind(history);'
      'var _r=history.replaceState.bind(history);'
      'history.pushState=function(){_p.apply(history,arguments);};'
      'history.replaceState=function(){_r.apply(history,arguments);};'
      '})()',
    ).catchError((_) {});
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _navigate() {
    if (_tabs.isEmpty) return;
    var v = _active.urlCtrl.text.trim();
    if (v.isEmpty) return;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
    _active.ctrl?.loadRequest(Uri.parse(v));
  }

  // ── Terminal externe ─────────────────────────────────────────────────────

  void _launchExternal(bool isCmd, bool asAdmin) {
    final folder = widget.project.workFolder;
    final ok = isCmd
        ? launchTerminal(kind: TerminalKind.cmd, asAdmin: asAdmin, workFolder: folder)
        : launchPowerShell(asAdmin: asAdmin, workFolder: folder);

    setState(() {
      _extError = ok ? null : 'Impossible d\'ouvrir le terminal (UAC refusé ou introuvable).';
    });

    if (ok) {
      // Petit délai puis disparition de la barre pour ne pas encombrer
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _showExtBar = false);
      });
    } else {
      // Le message d'erreur reste visible quelques secondes
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _extError = null);
      });
    }
  }

  // ── Script personnalisé ──────────────────────────────────────────────────
  //
  // La fenêtre navigateur tourne dans un process séparé du lanceur (lancée
  // en mode détaché via --project=<id>) : toute modification du script doit
  // donc être persistée directement sur disque via ProjectRepository, et
  // pas seulement en mémoire dans widget.project (qui ne serait jamais vu
  // par le lanceur sans ça).

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

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _urlPollTimer?.cancel();
    stopWatcher();
    windowManager.removeListener(this);
    ProcessTracker.deletePid(widget.project.id);
    for (final tab in _tabs) {
      tab.urlCtrl.dispose();
      tab.urlFocus.dispose();
    }
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_active.error != null && _active.ctrl == null) {
      return _ErrorView(error: _active.error!, onRetry: _retryActiveTab);
    }

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          // ── Barre d'onglets ────────────────────────────────────────────
          _TabStrip(
            tabs:        _tabs,
            activeIndex: _activeIndex,
            onSelect:    _selectTab,
            onClose:     _closeTab,
            onAdd:       _addTab,
          ),

          // ── Toolbar ────────────────────────────────────────────────────
          _Toolbar(
            ctrl:          _active.ctrl!,
            urlCtrl:       _active.urlCtrl,
            urlFocus:      _active.urlFocus,
            loading:       _active.loading,
            showTerm:      _showTerm,
            showExtBar:    _showExtBar,
            onNavigate:    _navigate,
            onToggleTerm:  () => setState(() => _showTerm = !_showTerm),
            onToggleExt:   () => setState(() => _showExtBar = !_showExtBar),
            onScript:      () => setState(() => _showScript = !_showScript),
          ),

          // ── Barre de progression ───────────────────────────────────────
          if (_active.loading)
            LinearProgressIndicator(
              value:           _active.progress,
              minHeight:       2,
              backgroundColor: Colors.transparent,
            ),

          // ── Zone principale : WebView + panneaux redimensionnables ──────
          //
          // IMPORTANT : tous les panneaux optionnels (terminal externe,
          // script, terminal intégré) sont placés APRÈS WinWebViewWidget
          // dans cette Column, jamais AVANT. webview_win_floating gère la
          // WebView2 via une fenêtre Win32 native (HWND) positionnée/
          // redimensionnée selon la mise en page Flutter ; insérer un
          // widget AU-DESSUS d'elle ne repositionne pas correctement ce
          // HWND (il reste affiché à son ancienne position, dissimulant
          // les panneaux ajoutés). En les plaçant EN DESSOUS, seule la
          // hauteur de la WebView diminue depuis le bas — cas correctement
          // géré par le plugin, comme le confirme déjà le panneau terminal
          // intégré ci-dessous.
          Expanded(
            child: Column(children: [
              // WebView occupe tout l'espace restant. Un seul onglet est
              // monté à la fois (celui actif) — voir note dans
              // _openTab().
              Expanded(child: WinWebViewWidget(controller: _active.ctrl!)),

              // ── Barre terminal externe (inline, sous la WebView) ────────
              if (_showExtBar)
                _ExternalTerminalBar(
                  workFolder: widget.project.workFolder,
                  error:      _extError,
                  onLaunch:   _launchExternal,
                ),

              // ── Panneau Script (inline, sous la WebView) ────────────────
              if (_showScript)
                ScriptPanel(
                  projectName:    widget.project.name,
                  initialContent: widget.project.scriptContent,
                  initialFolder:  widget.project.scriptFolder ?? widget.project.workFolder,
                  onSave:         _saveScript,
                  onExecute:      _executeScript,
                  onClose:        () => setState(() => _showScript = false),
                ),

              // Séparateur + panneau terminal (uniquement si ouvert)
              if (_showTerm) ...[
                _TerminalHeader(
                  isCmd:           _termIsCmd,
                  workDir:         widget.project.workFolder,
                  termHeight:      _termH,
                  onDrag:          (dy) => setState(() {
                    // Drag vers le haut = dy négatif = terminal plus grand
                    _termH = (_termH - dy).clamp(_termHMin, _termHMax);
                  }),
                  onSwitchKind:    (isCmd) => setState(() {
                    _termIsCmd = isCmd;
                    _termKey++;     // redémarre le terminal avec le nouvel exécutable
                  }),
                  onRestart:       () => setState(() => _termKey++),
                  onClose:         () => setState(() => _showTerm = false),
                ),
                SizedBox(
                  height: _termH,
                  child: TerminalPane(
                    // La clé change lors du switch CMD↔PS ou d'un redémarrage
                    key:     ValueKey('${_termIsCmd}_$_termKey'),
                    isCmd:   _termIsCmd,
                    workDir: widget.project.workFolder,
                    initialHistory: _termHistory,
                    onHistoryChanged: (h) {
                      _termHistory = h; // survit aux redémarrages du panneau
                      TerminalHistoryStore.save(widget.project.id, h); // survit à la fermeture
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
// Toolbar
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final WinWebViewController  ctrl;
  final TextEditingController urlCtrl;
  final FocusNode              urlFocus;
  final bool loading, showTerm, showExtBar;
  final VoidCallback onNavigate, onToggleTerm, onToggleExt, onScript;

  const _Toolbar({
    required this.ctrl,      required this.urlCtrl,
    required this.urlFocus,
    required this.loading,   required this.showTerm,
    required this.showExtBar,
    required this.onNavigate, required this.onToggleTerm,
    required this.onToggleExt, required this.onScript,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back),    tooltip: 'Précédent', onPressed: () => ctrl.goBack()),
        IconButton(icon: const Icon(Icons.arrow_forward), tooltip: 'Suivant',   onPressed: () => ctrl.goForward()),
        IconButton(
          icon:    Icon(loading ? Icons.close : Icons.refresh),
          tooltip: loading ? 'Arrêter' : 'Recharger',
          onPressed: () => loading
              ? ctrl.runJavaScript('window.stop()')
              : ctrl.reload(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: urlCtrl,
            focusNode:  urlFocus,
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
        IconButton(
          icon: const Icon(Icons.arrow_circle_right_outlined),
          tooltip: 'Aller',
          onPressed: onNavigate,
        ),
        const SizedBox(width: 4),
        // Bouton terminal intégré
        Tooltip(
          message: showTerm ? 'Fermer le terminal intégré' : 'Ouvrir un terminal intégré',
          child: IconButton(
            icon:  Icon(showTerm ? Icons.terminal : Icons.terminal_outlined),
            style: showTerm
                ? IconButton.styleFrom(backgroundColor: cs.primaryContainer)
                : null,
            color: showTerm ? cs.primary : null,
            onPressed: onToggleTerm,
          ),
        ),
        // Bouton terminal externe (vraie console Windows)
        Tooltip(
          message: showExtBar
              ? 'Fermer'
              : 'Ouvrir un terminal externe (CMD/PowerShell)\n'
                'Recommandé pour les invites interactives à flèches',
          child: IconButton(
            icon:  Icon(showExtBar ? Icons.open_in_new : Icons.open_in_new_outlined),
            style: showExtBar
                ? IconButton.styleFrom(backgroundColor: cs.primaryContainer)
                : null,
            color: showExtBar ? cs.primary : null,
            onPressed: onToggleExt,
          ),
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
// Barre d'onglets
// ─────────────────────────────────────────────────────────────────────────────

class _TabStrip extends StatelessWidget {
  final List<_BrowserTab> tabs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onAdd;

  const _TabStrip({
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
      height: 36,
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
                  constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
                  margin:  const EdgeInsets.only(right: 2, top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
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
                      Icon(Icons.public, size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize:   12,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => onClose(i),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 13, color: cs.onSurfaceVariant),
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

// ─────────────────────────────────────────────────────────────────────────────
// Barre inline « Terminal externe » (CMD / PowerShell, normal / admin)
// ─────────────────────────────────────────────────────────────────────────────
//
// Toujours INLINE (jamais en popup/overlay) : webview_win_floating affiche
// la WebView2 dans une fenêtre Win32 native flottante au-dessus du
// compositor Flutter, ce qui masque tout overlay (PopupMenu, Tooltip étendu,
// Dialog) dès qu'il déborde sous la barre d'outils. Une Column inline n'a
// pas ce problème car elle pousse réellement le WebView vers le bas.

class _ExternalTerminalBar extends StatelessWidget {
  final String? workFolder;
  final String? error;
  final void Function(bool isCmd, bool asAdmin) onLaunch;

  const _ExternalTerminalBar({
    required this.workFolder,
    required this.error,
    required this.onLaunch,
  });

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final hasFolder = workFolder?.isNotEmpty == true;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.folder_outlined, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                hasFolder ? workFolder! : 'Aucun dossier de travail configuré pour ce profil',
                style: TextStyle(
                  fontSize: 12,
                  color: hasFolder ? cs.onSurfaceVariant : cs.error,
                  fontStyle: hasFolder ? FontStyle.normal : FontStyle.italic,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => onLaunch(true, false),
                icon:  const Icon(Icons.terminal, size: 16),
                label: const Text('CMD', style: TextStyle(fontSize: 13)),
              ),
              FilledButton.tonalIcon(
                onPressed: () => onLaunch(true, true),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.errorContainer,
                  foregroundColor: cs.onErrorContainer,
                ),
                icon:  const Icon(Icons.terminal, size: 16),
                label: const Text('CMD  ⚡ Admin', style: TextStyle(fontSize: 13)),
              ),
              FilledButton.tonalIcon(
                onPressed: () => onLaunch(false, false),
                icon:  const Icon(Icons.code, size: 16),
                label: const Text('PowerShell', style: TextStyle(fontSize: 13)),
              ),
              FilledButton.tonalIcon(
                onPressed: () => onLaunch(false, true),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.errorContainer,
                  foregroundColor: cs.onErrorContainer,
                ),
                icon:  const Icon(Icons.code, size: 16),
                label: const Text('PowerShell  ⚡ Admin', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.error_outline, size: 14, color: cs.error),
              const SizedBox(width: 4),
              Expanded(child: Text(error!, style: TextStyle(fontSize: 11, color: cs.error))),
            ]),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// En-tête du terminal (séparateur draggable + contrôles)
// ─────────────────────────────────────────────────────────────────────────────

class _TerminalHeader extends StatelessWidget {
  final bool     isCmd;
  final String?  workDir;
  final double   termHeight;
  final void Function(double dy) onDrag;
  final void Function(bool isCmd) onSwitchKind;
  final VoidCallback onRestart, onClose;

  const _TerminalHeader({
    required this.isCmd,      required this.workDir,
    required this.termHeight, required this.onDrag,
    required this.onSwitchKind,
    required this.onRestart,  required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ── Poignée de redimensionnement ─────────────────────────────────
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          child: Container(
            height: 8,
            color: cs.surfaceContainerHighest,
            child: Center(
              child: Container(
                width: 40, height: 3,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),

      // ── Barre de contrôles du terminal ───────────────────────────────
      Container(
        height: 36,
        color: const Color(0xFF2D2D2D),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          // Sélecteur CMD / PowerShell
          _KindChip(
            label:    'CMD',
            selected: isCmd,
            onTap:    () => onSwitchKind(true),
          ),
          const SizedBox(width: 4),
          _KindChip(
            label:    'PowerShell',
            selected: !isCmd,
            onTap:    () => onSwitchKind(false),
          ),

          const SizedBox(width: 8),

          // Dossier de travail
          if (workDir?.isNotEmpty == true) ...[
            const Icon(Icons.folder_outlined, size: 12, color: Color(0xFF999999)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                workDir!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),

          // Hauteur courante
          Text(
            '${termHeight.round()} px',
            style: const TextStyle(fontSize: 10, color: Color(0xFF666666)),
          ),
          const SizedBox(width: 8),

          // Redémarrer
          _HeaderBtn(
            icon:    Icons.replay,
            tooltip: 'Redémarrer le terminal',
            onTap:   onRestart,
          ),
          // Fermer
          _HeaderBtn(
            icon:    Icons.close,
            tooltip: 'Fermer le terminal',
            onTap:   onClose,
          ),
        ]),
      ),

      // ── Hint : limite du terminal intégré ─────────────────────────────
      // Texte inline (jamais en Tooltip/overlay qui déborderait sous la
      // WebView native et serait masqué).
      Container(
        width: double.infinity,
        color: const Color(0xFF252526),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: const Text(
          'ℹ Menu interactif à flèches qui ne répond pas ? '
          'Utilisez le bouton « Terminal externe » de la barre d\'outils — '
          'il ouvre une vraie console Windows qui gère le clavier complet.',
          style: TextStyle(fontSize: 10.5, color: Color(0xFF858585)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }
}

class _KindChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _KindChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:        selected ? const Color(0xFF007ACC) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize:   12,
            color:      selected ? Colors.white : const Color(0xFF999999),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _HeaderBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: const Color(0xFF999999)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 16),
        const Text('Impossible d\'initialiser le navigateur.\n'
            'Vérifiez que le WebView2 Runtime est installé.',
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(error, style: const TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onRetry,
            icon: const Icon(Icons.refresh), label: const Text('Réessayer')),
      ]),
    )));
  }
}
