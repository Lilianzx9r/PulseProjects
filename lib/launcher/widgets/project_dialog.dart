import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';

/// Boîte de dialogue de création ou d'édition d'un profil.
///
/// Retourne le [Project] créé/modifié via `Navigator.pop`, ou `null`
/// si l'utilisateur annule.
///
/// [titleOverride]/[submitLabelOverride] permettent de réutiliser ce
/// dialogue comme étape de conversion lors d'un déplacement d'un projet
/// Flutter vers les profils Web (voir DevProjectsView._moveToWeb).
class ProjectDialog extends StatefulWidget {
  final Project? existing;
  final String? titleOverride;
  final String? submitLabelOverride;

  const ProjectDialog({
    super.key,
    this.existing,
    this.titleOverride,
    this.submitLabelOverride,
  });

  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<ProjectDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _folderController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _urlController = TextEditingController(
      text: widget.existing?.homeUrl ?? 'https://',
    );
    _folderController = TextEditingController(
      text: widget.existing?.workFolder ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: _folderController.text.isNotEmpty
            ? _folderController.text
            : null,
        confirmButtonText: 'Sélectionner',
      );
      if (path != null) {
        setState(() => _folderController.text = path);
      }
    } catch (e) {
      // Fallback : si le sélecteur natif échoue (env de test sans UI),
      // on ne fait rien.
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final workFolder = _folderController.text.trim();

    final project = widget.existing ??
        Project(
          id: const Uuid().v4(),
          name: '',
          homeUrl: '',
          createdAt: DateTime.now(),
        );

    project.name = _nameController.text.trim();
    project.homeUrl = _urlController.text.trim();
    project.workFolder = workFolder.isEmpty ? null : workFolder;

    Navigator.pop(context, project);
  }

  String? _validateUrl(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Champ requis';
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      return 'URL invalide (ex: https://example.com)';
    }
    return null;
  }

  String? _validateFolder(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null; // optionnel
    if (!Directory(v).existsSync()) {
      return 'Ce dossier n\'existe pas';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(widget.titleOverride ?? (isEditing ? 'Modifier le profil' : 'Nouveau profil')),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Nom ────────────────────────────────────────────────
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nom du profil',
                  hintText: 'Ex: Compte client A',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 16),

              // ── URL de démarrage ───────────────────────────────────
              TextFormField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'URL de démarrage',
                  hintText: 'https://...',
                  prefixIcon: Icon(Icons.public),
                ),
                keyboardType: TextInputType.url,
                validator: _validateUrl,
              ),
              const SizedBox(height: 16),

              // ── Dossier de travail ─────────────────────────────────
              const Text(
                'Dossier de travail (optionnel)',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _folderController,
                      decoration: InputDecoration(
                        hintText: Platform.isWindows ? r'C:\MonProjet\...' : '/Users/.../MonProjet',
                        prefixIcon: const Icon(Icons.folder_outlined),
                        isDense: true,
                      ),
                      validator: _validateFolder,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Parcourir…',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickFolder,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                Platform.isWindows
                    ? 'Ce dossier sera le répertoire courant à l\'ouverture '
                      'de CMD ou PowerShell depuis la fenêtre de ce profil.'
                    : 'Ce dossier sera le répertoire courant à l\'ouverture '
                      'du terminal (zsh) depuis la fenêtre de ce profil.',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.submitLabelOverride ?? 'Enregistrer'),
        ),
      ],
    );
  }
}
