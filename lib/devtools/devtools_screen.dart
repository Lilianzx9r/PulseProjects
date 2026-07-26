import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../common/file_launcher.dart';
import '../launcher/models/project.dart';
import '../launcher/widgets/project_dialog.dart';
import 'build_service.dart';
import 'data/dev_project_repository.dart';
import 'models/dev_project.dart';
import 'widgets/build_console_dialog.dart';
import 'widgets/dev_project_dialog.dart';

/// Contenu de l'outil "Build & Release" — liste des projets Flutter suivis,
/// build, déploiement et export de releases (équivalent GUI du script
/// `DevTool.bat` d'origine).
///
/// Ce widget N'A PAS son propre Scaffold/AppBar : il est conçu pour être
/// intégré comme onglet dans [LauncherHome] (voir launcher_app.dart), qui
/// distingue ainsi explicitement deux types de projets — "Profils Web" et
/// "Projets Flutter" — avec une UI et des actions adaptées à chacun. L'état
/// est exposé via [DevProjectsViewState] (publique) pour permettre au
/// parent de déclencher "Ajouter un projet" depuis un FloatingActionButton
/// partagé entre les deux onglets.
class DevProjectsView extends StatefulWidget {
  /// Exécutable de l'explorateur de fichiers configuré globalement
  /// (paramètre "Explorateur de fichiers" de PulseProjects), utilisé pour
  /// ouvrir les dossiers source/releases. Null = explorateur natif de l'OS.
  final String? explorerExe;

  /// Appelé lorsqu'un projet Flutter est déplacé vers les profils Web
  /// (voir [_moveToWeb]) : [LauncherHome] insère le [Project] résultant
  /// dans sa propre liste et la sauvegarde, car cette liste vit dans
  /// l'état de [LauncherHome], pas dans celui de ce widget.
  final Future<void> Function(Project project)? onMoveToWeb;

  const DevProjectsView({super.key, this.explorerExe, this.onMoveToWeb});

  @override
  State<DevProjectsView> createState() => DevProjectsViewState();
}

class DevProjectsViewState extends State<DevProjectsView> {
  final _repo = DevProjectRepository();
  List<DevProject> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final projects = await _repo.load();
    if (!mounted) return;
    setState(() { _projects = projects; _loading = false; });
  }

  Future<void> _save() => _repo.save(_projects);

  // ── CRUD ──────────────────────────────────────────────────────────────────

  /// Ouvre le formulaire de création d'un projet Flutter. Exposé
  /// publiquement pour être déclenché depuis le FAB partagé de
  /// [LauncherHome] lorsque l'onglet "Projets Flutter" est actif.
  Future<void> createProject() => _createOrEdit();

  /// Recharge la liste depuis le disque. Exposé publiquement pour le
  /// bouton "Actualiser" de l'AppBar partagée de [LauncherHome].
  Future<void> reload() => _load();

  /// Insère [project] en tête de liste et sauvegarde. Exposé publiquement
  /// pour recevoir un projet converti depuis les profils Web (voir
  /// [LauncherHome._moveToFlutter]).
  Future<void> addProject(DevProject project) async {
    setState(() => _projects.insert(0, project));
    await _save();
  }

  // ── Déplacement vers les profils Web ────────────────────────────────────
  //
  // Réutilise ProjectDialog (le formulaire des profils Web) comme étape de
  // conversion : le dossier source Flutter devient le "dossier de travail"
  // du profil Web (le terminal intégré s'ouvrira donc directement dedans),
  // et l'utilisateur doit renseigner l'URL de démarrage (champ propre aux
  // profils Web, absent des projets Flutter).

  Future<void> _moveToWeb(DevProject devProject) async {
    final temp = Project(
      id: const Uuid().v4(),
      name: devProject.name,
      homeUrl: 'https://',
      workFolder: devProject.sourcePath,
      createdAt: DateTime.now(),
    );

    final result = await showDialog<Project>(
      context: context,
      builder: (_) => ProjectDialog(
        existing: temp,
        titleOverride: 'Convertir "${devProject.name}" en profil Web',
        submitLabelOverride: 'Convertir',
      ),
    );
    if (result == null) return;

    if (widget.onMoveToWeb != null) {
      await widget.onMoveToWeb!(result);
    }

    setState(() => _projects.removeWhere((p) => p.id == devProject.id));
    await _save();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${devProject.name}" déplacé vers Profils Web')),
    );
  }

  Future<void> _createOrEdit({DevProject? existing}) async {
    final result = await showDialog<DevProject>(
      context: context,
      builder: (_) => DevProjectDialog(existing: existing),
    );
    if (result == null) return;

    setState(() {
      if (existing != null) {
        final i = _projects.indexWhere((p) => p.id == existing.id);
        if (i != -1) _projects[i] = result;
      } else {
        _projects.insert(0, result);
      }
    });
    await _save();
  }

  Future<void> _delete(DevProject project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirer le projet'),
        content: Text(
          'Retirer "${project.name}" de la liste ?\n\n'
          'Les sources et les releases déjà générées ne sont pas supprimées.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Retirer')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _projects.removeWhere((p) => p.id == project.id));
    await _save();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Future<void> _build(DevProject project) async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => BuildConsoleDialog(
        project: project,
        releasesFolder: _repo.effectiveReleasesFolder(project),
        oldReleasesFolder: _repo.effectiveOldReleasesFolder(project),
      ),
    );

    if (result != null) {
      setState(() {
        project.lastBuiltAt = DateTime.now();
        if (result.deployedPath != null) project.lastDeployedAt = DateTime.now();
      });
      await _save();
    }
  }

  // ── Redéploiement rapide (sans rebuild) ─────────────────────────────────

  Future<void> _redeploy(DevProject project) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Déploiement en cours…'), duration: Duration(seconds: 2)),
    );

    final service = BuildService(
      project: project,
      releasesFolder: _repo.effectiveReleasesFolder(project),
      oldReleasesFolder: _repo.effectiveOldReleasesFolder(project),
      onLog: (_) {}, // pas de console pour ce redéploiement rapide
    );
    final result = await service.redeployOnly();

    if (!mounted) return;
    if (result.success) {
      setState(() => project.lastDeployedAt = DateTime.now());
      await _save();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Déployé : ${result.deployedPath}')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Échec du déploiement.')),
      );
    }
  }

  // ── Ouverture de dossiers (respecte l'explorateur configuré) ──────────────

  void _openSource(DevProject project) =>
      openFolder(project.sourcePath, customExplorerExe: widget.explorerExe);

  void _openReleases(DevProject project) =>
      openFolder(_repo.effectiveReleasesFolder(project), customExplorerExe: widget.explorerExe);

  void _openDeployFolder(DevProject project) {
    if (!project.hasDeployFolder) return;
    openFolder(project.deployFolder!, customExplorerExe: widget.explorerExe);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_projects.isEmpty) return _EmptyState(onCreate: () => _createOrEdit());

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final project = _projects[i];
        return _DevProjectTile(
          project: project,
          releasesFolder: _repo.effectiveReleasesFolder(project),
          onBuild: () => _build(project),
          onRedeploy: project.hasDeployFolder ? () => _redeploy(project) : null,
          onEdit: () => _createOrEdit(existing: project),
          onDelete: () => _delete(project),
          onOpenSource: () => _openSource(project),
          onOpenReleases: () => _openReleases(project),
          onOpenDeployFolder: project.hasDeployFolder ? () => _openDeployFolder(project) : null,
          onMoveToWeb: () => _moveToWeb(project),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _DevProjectTile extends StatelessWidget {
  final DevProject project;
  final String releasesFolder;
  final VoidCallback onBuild, onEdit, onDelete, onOpenSource, onOpenReleases, onMoveToWeb;
  final VoidCallback? onRedeploy, onOpenDeployFolder;

  const _DevProjectTile({
    required this.project, required this.releasesFolder,
    required this.onBuild, required this.onEdit, required this.onDelete,
    required this.onOpenSource, required this.onOpenReleases,
    required this.onMoveToWeb,
    this.onRedeploy, this.onOpenDeployFolder,
  });

  String _fmt(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year} à $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final last = project.lastBuiltAt;
    final lastDeploy = project.lastDeployedAt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flutter_dash, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(project.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text(project.sourcePath,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (onRedeploy != null) ...[
              OutlinedButton.icon(
                onPressed: onRedeploy,
                icon: const Icon(Icons.rocket_launch_outlined, size: 16),
                label: const Text('Redéployer'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: onBuild,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Build'),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.inventory_2_outlined, size: 13, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(releasesFolder,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          if (project.hasDeployFolder) ...[
            const SizedBox(height: 2),
            Row(children: [
              Icon(Icons.rocket_launch_outlined, size: 13, color: cs.primary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(project.deployFolder!,
                    style: TextStyle(fontSize: 11, color: cs.primary),
                    overflow: TextOverflow.ellipsis),
              ),
              if (project.deployAfterBuild)
                Tooltip(
                  message: 'Déploiement automatique après build',
                  child: Icon(Icons.bolt, size: 13, color: cs.primary),
                ),
            ]),
          ],
          const SizedBox(height: 2),
          Text(
            'Dernier build : ${last != null ? _fmt(last) : 'jamais'}'
            '${lastDeploy != null ? '  •  Déployé : ${_fmt(lastDeploy)}' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(children: [
            TextButton.icon(
              onPressed: onOpenSource,
              icon: const Icon(Icons.folder_outlined, size: 16),
              label: const Text('Sources', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
            TextButton.icon(
              onPressed: onOpenReleases,
              icon: const Icon(Icons.folder_zip_outlined, size: 16),
              label: const Text('Releases', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
            if (onOpenDeployFolder != null)
              TextButton.icon(
                onPressed: onOpenDeployFolder,
                icon: const Icon(Icons.rocket_launch_outlined, size: 16),
                label: const Text('Déploiement', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            const Spacer(),
            IconButton(
              tooltip: 'Déplacer vers Profils Web',
              icon: const Icon(Icons.public, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onMoveToWeb,
            ),
            IconButton(
              tooltip: 'Modifier',
              icon: const Icon(Icons.edit_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Retirer',
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            ),
          ]),
        ]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.flutter_dash, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('Aucun projet Flutter suivi', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            'Ajoutez un projet pour lancer des builds Windows/macOS ou APK, '
            'générer des archives de release horodatées et publier '
            'automatiquement l\'exécutable dans un dossier de déploiement.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Ajouter un projet Flutter'),
        ),
      ]),
    );
  }
}
