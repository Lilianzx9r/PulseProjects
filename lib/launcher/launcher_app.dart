import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../common/app_settings.dart';
import '../common/file_launcher.dart' show openFolder;
import '../common/process_tracker.dart';
import '../devtools/data/dev_project_repository.dart';
import '../devtools/devtools_screen.dart';
import '../devtools/models/dev_project.dart';
import '../devtools/widgets/dev_project_dialog.dart';
import 'data/export_service.dart';
import 'data/project_repository.dart';
import 'models/project.dart';
import 'settings_screen.dart';
import 'widgets/orphan_profiles_dialog.dart';
import 'widgets/project_dialog.dart';
import 'widgets/project_row_compact.dart';
import 'widgets/project_tile.dart';
import 'widgets/project_tile_mosaic.dart';
import 'widgets/reorderable_tile.dart';

class LauncherApp extends StatelessWidget {
  final ProjectRepository repository;
  const LauncherApp({super.key, required this.repository});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseProjects',
      debugShowCheckedModeBanner: false,
      theme:     ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark),
      home: LauncherHome(repository: repository),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode d'affichage
// ─────────────────────────────────────────────────────────────────────────────

enum _ViewMode { detailed, compact, mosaic }

extension _ViewModeIO on _ViewMode {
  String get storageName => name;

  static _ViewMode fromStorage(String? s) {
    return _ViewMode.values.firstWhere(
      (v) => v.name == s,
      orElse: () => _ViewMode.detailed,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class LauncherHome extends StatefulWidget {
  final ProjectRepository repository;
  const LauncherHome({super.key, required this.repository});

  @override
  State<LauncherHome> createState() => _LauncherHomeState();
}

class _LauncherHomeState extends State<LauncherHome> with WindowListener, SingleTickerProviderStateMixin {
  List<Project>    _projects = [];
  Map<String, int> _running  = {};
  bool             _loading  = true;
  bool             _closing  = false;
  _ViewMode        _viewMode = _ViewMode.detailed;
  AppSettings      _settings = AppSettings.defaults;
  Timer?           _refreshTimer;

  final _scrollCtrl  = ScrollController();
  final _scrollFocus = FocusNode(debugLabel: 'launcher-scroll');
  late final ExportService _exportService;

  // ── Onglets : "Profils Web" (index 0) / "Projets Flutter" (index 1) ──────
  // Distingue explicitement les deux types de projets gérés par
  // PulseProjects, avec une UI et des actions adaptées à chacun.
  late final TabController _tabController;
  final _devProjectsKey = GlobalKey<DevProjectsViewState>();
  final _devProjectRepo = DevProjectRepository();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    _exportService = ExportService(widget.repository);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {})); // rafraîchit AppBar/FAB
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshRunning());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _refreshTimer?.cancel();
    _scrollCtrl.dispose();
    _scrollFocus.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ── WindowListener ────────────────────────────────────────────────────────

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;

    final running = await ProcessTracker.runningProjects();
    if (running.isEmpty) { await windowManager.destroy(); return; }
    if (!mounted) { await windowManager.destroy(); return; }

    final count  = running.length;
    final choice = await showDialog<_CloseChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Fermer PulseProjects'),
        content: Text(
          '$count browser${count > 1 ? 's' : ''} '
          '${count > 1 ? 'sont ouverts' : 'est ouvert'}.\n'
          'Que souhaitez-vous faire ?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, _CloseChoice.cancel), child: const Text('Annuler')),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, _CloseChoice.keepBrowsers), child: const Text('Garder les browsers ouverts')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, _CloseChoice.closeAll),
            child: const Text('Fermer tout'),
          ),
        ],
      ),
    );

    _closing = false;
    switch (choice) {
      case _CloseChoice.closeAll:
        await ProcessTracker.killAll(running);
        await windowManager.destroy();
      case _CloseChoice.keepBrowsers:
        await windowManager.destroy();
      case _CloseChoice.cancel:
      case null:
        break;
    }
  }

  // ── Chargement ─────────────────────────────────────────────────────────────
  //
  // L'ordre des profils N'EST PLUS recalculé automatiquement (ex: par date
  // de dernier lancement). Il correspond strictement à l'ordre stocké dans
  // projects.json, modifiable uniquement par glisser-déposer (_moveProject).

  Future<void> _load() async {
    final projects  = await widget.repository.loadProjects();
    final running   = await ProcessTracker.runningProjects();
    final savedMode = await widget.repository.loadViewMode();
    final settings  = await AppSettingsStore.load();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _running  = running;
      _viewMode = _ViewModeIO.fromStorage(savedMode);
      _settings = settings;
      _loading  = false;
    });
  }

  Future<void> _refreshRunning() async {
    final running = await ProcessTracker.runningProjects();
    if (mounted) setState(() => _running = running);
  }

  Future<void> _save() => widget.repository.saveProjects(_projects);

  void _setViewMode(_ViewMode mode) {
    setState(() => _viewMode = mode);
    widget.repository.saveViewMode(mode.storageName);
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(initial: _settings),
      ),
    );
    if (updated != null) {
      setState(() => _settings = updated);
      await AppSettingsStore.save(updated);
    }
  }

  // ── Réordonnancement (glisser-déposer) ──────────────────────────────────────

  void _moveProject(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    if (fromIndex < 0 || fromIndex >= _projects.length) return;
    if (toIndex   < 0 || toIndex   >= _projects.length) return;
    setState(() {
      final item = _projects.removeAt(fromIndex);
      _projects.insert(toIndex, item);
    });
    _save();
  }

  // ── Scroll clavier ───────────────────────────────────────────────────────────

  KeyEventResult _handleScrollKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_scrollCtrl.hasClients) return KeyEventResult.ignored;

    final pos = _scrollCtrl.position;
    double? target;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowDown) {
      target = pos.pixels + 70;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      target = pos.pixels - 70;
    } else if (key == LogicalKeyboardKey.pageDown) {
      target = pos.pixels + pos.viewportDimension * 0.85;
    } else if (key == LogicalKeyboardKey.pageUp) {
      target = pos.pixels - pos.viewportDimension * 0.85;
    } else if (key == LogicalKeyboardKey.home) {
      target = 0;
    } else if (key == LogicalKeyboardKey.end) {
      target = pos.maxScrollExtent;
    } else {
      return KeyEventResult.ignored;
    }

    final clamped = target.clamp(0.0, pos.maxScrollExtent);
    _scrollCtrl.animateTo(
      clamped,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  // ── Actions CRUD ──────────────────────────────────────────────────────────

  Future<void> _createOrEdit({Project? existing}) async {
    final result = await showDialog<Project>(
      context: context,
      builder: (_) => ProjectDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (existing != null) {
        final i = _projects.indexWhere((p) => p.id == existing.id);
        if (i != -1) _projects[i] = result;
      } else {
        _projects.insert(0, result); // nouveau profil en tête
      }
    });
    await _save();
  }

  Future<void> _delete(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer le profil'),
        content: Text(
          'Supprimer "${project.name}" ?\n\n'
          'Le dossier de données (cookies, cache…) n\'est pas supprimé. '
          'Utilisez "Réinitialiser les données" avant si nécessaire.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _projects.removeWhere((p) => p.id == project.id));
    await _save();
  }

  // ── Déplacement vers/depuis les projets Flutter ─────────────────────────
  //
  // Réutilise DevProjectDialog comme étape de conversion : le dossier de
  // travail du profil Web (s'il pointe vers un projet Flutter valide, avec
  // un pubspec.yaml) est proposé comme dossier source ; sinon l'utilisateur
  // doit le choisir via le sélecteur de dossier (le champ est validé de la
  // même façon que pour un nouveau projet Flutter classique).

  Future<void> _moveToFlutter(Project project) async {
    final temp = DevProject(
      id: const Uuid().v4(),
      name: project.name,
      sourcePath: project.workFolder ?? '',
      createdAt: DateTime.now(),
    );

    final result = await showDialog<DevProject>(
      context: context,
      builder: (_) => DevProjectDialog(
        existing: temp,
        titleOverride: 'Convertir "${project.name}" en projet Flutter',
        submitLabelOverride: 'Convertir',
      ),
    );
    if (result == null) return;

    // Si l'onglet "Projets Flutter" n'a encore jamais été affiché,
    // TabBarView peut ne pas avoir construit DevProjectsView : son State
    // vaut alors null et un simple appel via GlobalKey serait silencieusement
    // ignoré (le projet disparaîtrait sans jamais être ajouté). On écrit
    // donc TOUJOURS directement sur disque via le repository, ce qui
    // fonctionne que l'onglet ait été visité ou non ; si son State existe
    // déjà, on l'appelle en plus pour rafraîchir l'affichage sans attendre
    // un rechargement.
    final devState = _devProjectsKey.currentState;
    if (devState != null) {
      await devState.addProject(result);
    } else {
      final devProjects = await _devProjectRepo.load();
      devProjects.insert(0, result);
      await _devProjectRepo.save(devProjects);
    }

    setState(() => _projects.removeWhere((p) => p.id == project.id));
    await _save();

    if (!mounted) return;
    _tabController.animateTo(1); // bascule sur l'onglet Projets Flutter
    // Si DevProjectsView vient tout juste d'être construit par ce switch
    // d'onglet, son initState() a déjà chargé la donnée fraîchement écrite
    // ci-dessus. On force quand même un reload pour couvrir le cas où son
    // State existait déjà avant l'écriture ci-dessus (currentState non nul
    // mais capturé avant addProject) — ce reload est sans effet néfaste,
    // juste redondant dans le cas nominal.
    await _devProjectsKey.currentState?.reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${project.name}" déplacé vers Projets Flutter')),
    );
  }

  /// Reçoit un profil Web converti depuis un projet Flutter (voir
  /// DevProjectsView._moveToWeb) : l'ajoute à la liste des profils Web,
  /// sauvegarde, et bascule sur l'onglet correspondant.
  Future<void> _receiveMovedToWeb(Project project) async {
    setState(() => _projects.insert(0, project));
    await _save();
    if (!mounted) return;
    _tabController.animateTo(0); // bascule sur l'onglet Profils Web
  }

  /// Ouvre le dialogue de récupération des profils orphelins (dossiers de
  /// données présents sur le disque mais plus référencés dans la liste,
  /// typiquement suite à un déplacement Web → Flutter interrompu).
  Future<void> _openOrphanRecovery() async {
    await showDialog(
      context: context,
      builder: (_) => OrphanProfilesDialog(
        knownProjects: _projects,
        onRestore: (project) async {
          setState(() => _projects.insert(0, project));
          await _save();
        },
      ),
    );
    // Le contenu de _projects peut avoir changé pendant que le dialogue
    // était ouvert (profils restaurés) : pas besoin de _load() complet,
    // l'état est déjà à jour via les setState() successifs de onRestore.
  }

  Future<void> _launch(Project project) async {
    final launched = await widget.repository.launchProject(project);
    if (launched) {
      project.lastLaunchedAt = DateTime.now();
      await _save();
      await Future.delayed(const Duration(milliseconds: 800));
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(launched
          ? '"${project.name}" lancé dans une instance indépendante'
          : '"${project.name}" déjà ouvert — mis au premier plan'),
    ));
  }

  Future<void> _openDataFolder(Project project) async {
    try {
      final dir = await widget.repository.profileDataDir(project.id);
      openFolder(dir, customExplorerExe: _settings.explorerExe);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible d\'ouvrir le dossier : $e')));
    }
  }

  Future<void> _resetData(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Réinitialiser les données'),
        content: Text(
          'Cookies, sessions et cache du profil "${project.name}" seront '
          'définitivement supprimés.\n\n'
          'Assurez-vous que ce profil n\'est pas en cours d\'exécution.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: const Text('Réinitialiser')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.repository.resetProfileData(project.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Données réinitialisées pour "${project.name}"')));
  }

  // ── Export / Import ───────────────────────────────────────────────────────
  //
  // Un export contient les métadonnées du profil (nom, URL, dossier de
  // travail) et une copie du dossier de données WebView2 (cookies,
  // localStorage, IndexedDB, sessions...). Voir la documentation de
  // ExportService pour la limite de portabilité liée au chiffrement DPAPI
  // des cookies/mots de passe (lié au compte Windows).

  Future<void> _exportProject(Project project) async {
    // Le profil ne doit pas être en cours d'exécution : ses fichiers de
    // données pourraient être verrouillés ou en cours d'écriture.
    final running = await ProcessTracker.runningProjects();
    if (running.containsKey(project.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Fermez d\'abord "${project.name}" avant de l\'exporter '
          '(ses fichiers de données sont en cours d\'utilisation).',
        ),
      ));
      return;
    }

    final includeCache = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ExportOptionsDialog(projectName: project.name),
    );
    if (includeCache == null) return; // annulé

    final location = await getSaveLocation(
      suggestedName: '${_sanitizeFileName(project.name)}.pulseproject.zip',
      acceptedTypeGroups: [const XTypeGroup(label: 'ZIP', extensions: ['zip'])],
      confirmButtonText: 'Exporter',
    );
    final savePath = location?.path;
    if (savePath == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BusyDialog(message: 'Export en cours…'),
    );

    try {
      await _exportService.exportProject(project, savePath, includeCache: includeCache);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // ferme _BusyDialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Profil "${project.name}" exporté avec succès')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'export : $e')),
      );
    }
  }

  // ── Export groupé (tous les profils) ────────────────────────────────────

  Future<void> _exportAllProjects() async {
    if (_projects.isEmpty) return;

    final running    = await ProcessTracker.runningProjects();
    final exportable = _projects.where((p) => !running.containsKey(p.id)).toList();
    final skipped    = _projects.where((p) => running.containsKey(p.id)).toList();

    if (exportable.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tous les profils sont actuellement ouverts — fermez-les avant d\'exporter.'),
      ));
      return;
    }

    if (!mounted) return;
    final includeCache = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ExportAllOptionsDialog(
        exportableCount: exportable.length,
        skippedNames: skipped.map((p) => p.name).toList(),
      ),
    );
    if (includeCache == null) return; // annulé

    final stamp = DateTime.now();
    final stampStr = '${stamp.year}${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}_'
        '${stamp.hour.toString().padLeft(2, '0')}${stamp.minute.toString().padLeft(2, '0')}';

    final location = await getSaveLocation(
      suggestedName: 'PulseProjects_export_${exportable.length}profils_$stampStr.zip',
      acceptedTypeGroups: [const XTypeGroup(label: 'ZIP', extensions: ['zip'])],
      confirmButtonText: 'Exporter',
    );
    final savePath = location?.path;
    if (savePath == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BusyDialog(message: 'Export de ${exportable.length} profils en cours…'),
    );

    try {
      await _exportService.exportAllProjects(exportable, savePath, includeCache: includeCache);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${exportable.length} profils exportés avec succès'),
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'export groupé : $e')),
      );
    }
  }

  Future<void> _importProject() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Export PulseProjects', extensions: ['zip']),
      ],
      confirmButtonText: 'Importer',
    );
    if (file == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BusyDialog(message: 'Import en cours…'),
    );

    try {
      final imported = await _exportService.importAny(file.path);
      setState(() => _projects.insertAll(0, imported));
      await _save();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final count = imported.length;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(count == 1
            ? 'Profil "${imported.first.name}" importé avec succès'
            : '$count profils importés avec succès'),
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'import : $e')),
      );
    }
  }

  String _sanitizeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'profil' : cleaned;
  }

  // ── Construction des tuiles ──────────────────────────────────────────────────

  Widget _buildItem(int i) {
    final p = _projects[i];
    final running = _running.containsKey(p.id);

    final Widget tile;
    switch (_viewMode) {
      case _ViewMode.detailed:
        tile = ProjectTile(
          index: i, project: p, isRunning: running,
          onLaunch: () => _launch(p), onEdit: () => _createOrEdit(existing: p),
          onDelete: () => _delete(p), onOpenFolder: () => _openDataFolder(p),
          onResetData: () => _resetData(p), onExport: () => _exportProject(p),
          onMoveToFlutter: () => _moveToFlutter(p),
        );
      case _ViewMode.compact:
        tile = ProjectRowCompact(
          index: i, project: p, isRunning: running,
          onLaunch: () => _launch(p), onEdit: () => _createOrEdit(existing: p),
          onDelete: () => _delete(p), onOpenFolder: () => _openDataFolder(p),
          onResetData: () => _resetData(p), onExport: () => _exportProject(p),
          onMoveToFlutter: () => _moveToFlutter(p),
        );
      case _ViewMode.mosaic:
        tile = ProjectTileMosaic(
          index: i, project: p, isRunning: running,
          onLaunch: () => _launch(p), onEdit: () => _createOrEdit(existing: p),
          onDelete: () => _delete(p), onOpenFolder: () => _openDataFolder(p),
          onResetData: () => _resetData(p), onExport: () => _exportProject(p),
          onMoveToFlutter: () => _moveToFlutter(p),
        );
    }

    return ReorderDropTarget(
      key: ValueKey(p.id),
      index: i,
      onReorder: _moveProject,
      borderRadius: BorderRadius.circular(_viewMode == _ViewMode.mosaic ? 14 : 12),
      child: tile,
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_projects.isEmpty) return _EmptyState(onCreate: () => _createOrEdit());

    return Focus(
      focusNode:  _scrollFocus,
      autofocus:  true,
      onKeyEvent: _handleScrollKey,
      child: Scrollbar(
        controller: _scrollCtrl,
        child: SingleChildScrollView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(16),
          child: _viewMode == _ViewMode.mosaic
              ? Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (var i = 0; i < _projects.length; i++) _buildItem(i)],
                )
              : Column(
                  children: [
                    for (var i = 0; i < _projects.length; i++) ...[
                      _buildItem(i),
                      if (i != _projects.length - 1) const SizedBox(height: 8),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isWebTab = _tabController.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PulseProjects'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.public), text: 'Profils Web'),
            Tab(icon: Icon(Icons.flutter_dash), text: 'Projets Flutter'),
          ],
        ),
        actions: [
          // ── Actions spécifiques aux profils web ─────────────────────────
          if (isWebTab) ...[
            if (_running.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: Chip(
                  avatar: const Icon(Icons.circle, color: Colors.green, size: 10),
                  label: Text('${_running.length} ouvert${_running.length > 1 ? 's' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            const SizedBox(width: 8),
            _ViewModeToggle(mode: _viewMode, onChanged: _setViewMode),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Exporter tous les profils',
              icon: const Icon(Icons.folder_zip_outlined),
              onPressed: _projects.isEmpty ? null : _exportAllProjects,
            ),
            IconButton(
              tooltip: 'Importer un profil (.zip)',
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _importProject,
            ),
            IconButton(
              tooltip: 'Récupérer un profil orphelin',
              icon: const Icon(Icons.restore),
              onPressed: _openOrphanRecovery,
            ),
            IconButton(tooltip: 'Actualiser', icon: const Icon(Icons.refresh), onPressed: _load),
          ] else
            // ── Actions spécifiques aux projets Flutter ────────────────────
            IconButton(
              tooltip: 'Actualiser',
              icon: const Icon(Icons.refresh),
              onPressed: () => _devProjectsKey.currentState?.reload(),
            ),

          // ── Actions communes ──────────────────────────────────────────────
          IconButton(
            tooltip: 'Paramètres globaux',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBody(),
          DevProjectsView(
            key: _devProjectsKey,
            explorerExe: _settings.explorerExe,
            onMoveToWeb: _receiveMovedToWeb,
          ),
        ],
      ),
      floatingActionButton: isWebTab
          ? FloatingActionButton.extended(
              onPressed: () => _createOrEdit(),
              icon:  const Icon(Icons.add),
              label: const Text('Nouveau profil'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _devProjectsKey.currentState?.createProject(),
              icon:  const Icon(Icons.add),
              label: const Text('Ajouter un projet Flutter'),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sélecteur de mode d'affichage
// ─────────────────────────────────────────────────────────────────────────────

class _ViewModeToggle extends StatelessWidget {
  final _ViewMode mode;
  final ValueChanged<_ViewMode> onChanged;

  const _ViewModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_ViewMode>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(
          value: _ViewMode.detailed,
          icon: Tooltip(message: 'Liste détaillée', child: Icon(Icons.view_agenda_outlined, size: 18)),
        ),
        ButtonSegment(
          value: _ViewMode.compact,
          icon: Tooltip(message: 'Liste condensée (1 ligne)', child: Icon(Icons.view_headline, size: 18)),
        ),
        ButtonSegment(
          value: _ViewMode.mosaic,
          icon: Tooltip(message: 'Mosaïque', child: Icon(Icons.grid_view_outlined, size: 18)),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

enum _CloseChoice { cancel, keepBrowsers, closeAll }

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.public, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('Aucun profil pour le moment', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onCreate, icon: const Icon(Icons.add), label: const Text('Créer un profil')),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialogue de progression (export / import)
// ─────────────────────────────────────────────────────────────────────────────

class _BusyDialog extends StatelessWidget {
  final String message;
  const _BusyDialog({required this.message});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Text(message),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Options d'export (inclusion du cache + avertissement portabilité)
// ─────────────────────────────────────────────────────────────────────────────

class _ExportOptionsDialog extends StatefulWidget {
  final String projectName;
  const _ExportOptionsDialog({required this.projectName});

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  bool _includeCache = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Exporter "${widget.projectName}"'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'L\'archive contiendra les métadonnées du profil (nom, URL, '
              'dossier de travail) ainsi que ses données de navigation '
              '(cookies, sessions, stockage local…).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Les cookies de session et mots de passe enregistrés sont '
                    'chiffrés via le compte Windows actuel. Restaurer cette '
                    'archive sur le même PC + même compte Windows fonctionnera '
                    'pleinement. Sur une autre machine ou un autre compte, ces '
                    'sessions peuvent nécessiter une nouvelle connexion '
                    '(le reste — historique, stockage local — reste intact). '
                    'Des avertissements internes Chromium sans gravité (ex: '
                    '« AXTree ») peuvent apparaître au premier lancement après '
                    'un import sur une autre machine ; ils n\'empêchent pas la '
                    'navigation.',
                    style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _includeCache,
              onChanged: (v) => setState(() => _includeCache = v ?? false),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Inclure le cache', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Augmente fortement la taille de l\'archive ; non nécessaire '
                'pour restaurer la session (régénéré automatiquement).',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _includeCache),
          child: const Text('Exporter'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Options d'export groupé (tous les profils)
// ─────────────────────────────────────────────────────────────────────────────

class _ExportAllOptionsDialog extends StatefulWidget {
  final int exportableCount;
  final List<String> skippedNames;

  const _ExportAllOptionsDialog({
    required this.exportableCount,
    required this.skippedNames,
  });

  @override
  State<_ExportAllOptionsDialog> createState() => _ExportAllOptionsDialogState();
}

class _ExportAllOptionsDialogState extends State<_ExportAllOptionsDialog> {
  bool _includeCache = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasSkipped = widget.skippedNames.isNotEmpty;

    return AlertDialog(
      title: const Text('Exporter tous les profils'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.exportableCount} profil${widget.exportableCount > 1 ? 's' : ''} '
              'seront inclus dans une seule archive (métadonnées + données '
              'de navigation : cookies, sessions, stockage local…).',
              style: const TextStyle(fontSize: 13),
            ),
            if (hasSkipped) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.skippedNames.length} profil${widget.skippedNames.length > 1 ? 's' : ''} '
                      'actuellement ouvert${widget.skippedNames.length > 1 ? 's' : ''} '
                      'seront ignorés : ${widget.skippedNames.join(', ')}.\n'
                      'Fermez-les puis relancez l\'export pour les inclure.',
                      style: TextStyle(fontSize: 11.5, color: cs.onErrorContainer),
                    ),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Les cookies de session et mots de passe enregistrés sont '
                    'chiffrés via le compte Windows actuel. Restaurer cette '
                    'archive sur le même PC + même compte Windows fonctionnera '
                    'pleinement ; sur une autre machine, ces sessions peuvent '
                    'nécessiter une nouvelle connexion. Des avertissements '
                    'internes Chromium sans gravité (ex: « AXTree ») peuvent '
                    'apparaître au premier lancement après import ; ils '
                    'n\'empêchent pas la navigation.',
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _includeCache,
              onChanged: (v) => setState(() => _includeCache = v ?? false),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Inclure le cache', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Augmente fortement la taille de l\'archive (cumulé sur tous '
                'les profils) ; non nécessaire pour restaurer les sessions.',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _includeCache),
          child: Text('Exporter ${widget.exportableCount} profil${widget.exportableCount > 1 ? 's' : ''}'),
        ),
      ],
    );
  }
}
