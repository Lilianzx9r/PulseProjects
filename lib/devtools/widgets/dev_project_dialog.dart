import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/dev_project.dart';

/// Boîte de dialogue de création ou d'édition d'un projet Flutter suivi
/// par l'outil "Build & Release".
///
/// [titleOverride]/[submitLabelOverride] permettent de réutiliser ce
/// dialogue comme étape de conversion lors d'un déplacement d'un profil
/// Web vers les projets Flutter (voir LauncherHome._moveToFlutter).
class DevProjectDialog extends StatefulWidget {
  final DevProject? existing;
  final String? titleOverride;
  final String? submitLabelOverride;

  const DevProjectDialog({
    super.key,
    this.existing,
    this.titleOverride,
    this.submitLabelOverride,
  });

  @override
  State<DevProjectDialog> createState() => _DevProjectDialogState();
}

class _DevProjectDialogState extends State<DevProjectDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _sourceCtrl;
  late final TextEditingController _releasesCtrl;
  late final TextEditingController _deployCtrl;
  late bool _deployAfterBuild;
  late bool _deployVersioned;

  @override
  void initState() {
    super.initState();
    _nameCtrl     = TextEditingController(text: widget.existing?.name ?? '');
    _sourceCtrl   = TextEditingController(text: widget.existing?.sourcePath ?? '');
    _releasesCtrl = TextEditingController(text: widget.existing?.releasesFolderOverride ?? '');
    _deployCtrl   = TextEditingController(text: widget.existing?.deployFolder ?? '');
    _deployAfterBuild = widget.existing?.deployAfterBuild ?? false;
    _deployVersioned  = widget.existing?.deployVersioned  ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sourceCtrl.dispose();
    _releasesCtrl.dispose();
    _deployCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickSourceFolder() async {
    try {
      final path = await getDirectoryPath(confirmButtonText: 'Sélectionner');
      if (path == null) return;

      setState(() {
        _sourceCtrl.text = path;
        // Auto-remplissage du nom depuis le nom du dossier, si vide
        if (_nameCtrl.text.trim().isEmpty) {
          final parts = path.split(RegExp(r'[\\/]'));
          _nameCtrl.text = parts.isNotEmpty ? parts.last : '';
        }
      });
    } catch (_) {}
  }

  Future<void> _pickReleasesFolder() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: _releasesCtrl.text.isNotEmpty ? _releasesCtrl.text : null,
        confirmButtonText: 'Sélectionner',
      );
      if (path != null) setState(() => _releasesCtrl.text = path);
    } catch (_) {}
  }

  Future<void> _pickDeployFolder() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: _deployCtrl.text.isNotEmpty ? _deployCtrl.text : null,
        confirmButtonText: 'Sélectionner',
      );
      if (path != null) setState(() => _deployCtrl.text = path);
    } catch (_) {}
  }

  String? _validateSource(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Champ requis';
    if (!File('$v${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return 'Aucun pubspec.yaml trouvé dans ce dossier';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final releases = _releasesCtrl.text.trim();
    final project = widget.existing ??
        DevProject(
          id: const Uuid().v4(),
          name: '',
          sourcePath: '',
          createdAt: DateTime.now(),
        );

    final deploy = _deployCtrl.text.trim();

    project.name       = _nameCtrl.text.trim();
    project.sourcePath = _sourceCtrl.text.trim();
    project.releasesFolderOverride = releases.isEmpty ? null : releases;
    project.deployFolder     = deploy.isEmpty ? null : deploy;
    project.deployAfterBuild = deploy.isNotEmpty && _deployAfterBuild;
    project.deployVersioned  = _deployVersioned;

    Navigator.pop(context, project);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final defaultReleasesHint = _sourceCtrl.text.isNotEmpty
        ? '${File(_sourceCtrl.text).parent.path}${Platform.pathSeparator}Releases'
        : '(dossier frère "Releases" par défaut)';

    return AlertDialog(
      title: Text(widget.titleOverride ?? (isEditing ? 'Modifier le projet Flutter' : 'Nouveau projet Flutter')),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Dossier source ────────────────────────────────────────────
              const Text('Dossier source (contient pubspec.yaml)',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _sourceCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Chemin du projet Flutter…',
                      prefixIcon: Icon(Icons.folder_outlined),
                      isDense: true,
                    ),
                    validator: _validateSource,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Parcourir…',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickSourceFolder,
                ),
              ]),
              const SizedBox(height: 16),

              // ── Nom ────────────────────────────────────────────────────────
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nom du projet',
                  hintText: 'Utilisé comme préfixe des archives (ex: MonApp_20260707.zip)',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 16),

              // ── Dossier releases (optionnel) ─────────────────────────────
              const Text('Dossier des releases (optionnel)',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _releasesCtrl,
                    decoration: InputDecoration(
                      hintText: defaultReleasesHint,
                      prefixIcon: const Icon(Icons.inventory_2_outlined),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Parcourir…',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickReleasesFolder,
                ),
              ]),
              const SizedBox(height: 4),
              const Text(
                'Si laissé vide, les archives sont déposées dans un dossier '
                '"Releases" frère du dossier source (comme le script .bat '
                'd\'origine). Les anciennes archives sont automatiquement '
                'déplacées vers "ReleasesOld".',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),

              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),

              // ── Déploiement de l'exécutable (optionnel) ────────────────────
              Row(children: [
                const Icon(Icons.rocket_launch_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Déploiement de l\'exécutable',
                    style: Theme.of(context).textTheme.titleSmall),
              ]),
              const SizedBox(height: 4),
              const Text(
                'Dossier où publier automatiquement l\'exécutable desktop '
                '(Windows/macOS) après un build réussi — distinct du '
                'dossier Releases (qui garde un historique zippé).',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _deployCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Dossier de déploiement (optionnel)…',
                      prefixIcon: Icon(Icons.rocket_launch_outlined),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Parcourir…',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickDeployFolder,
                ),
              ]),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _deployAfterBuild,
                onChanged: (v) => setState(() => _deployAfterBuild = v ?? false),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Déployer automatiquement après un build réussi',
                    style: TextStyle(fontSize: 13)),
              ),
              CheckboxListTile(
                value: _deployVersioned,
                onChanged: (v) => setState(() => _deployVersioned = v ?? false),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Dossier versionné (sinon écrase la copie précédente)',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'Créé un sous-dossier horodaté à chaque déploiement, au lieu '
                  'd\'écraser le contenu du dossier de déploiement.',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabelOverride ?? 'Enregistrer')),
      ],
    );
  }
}
