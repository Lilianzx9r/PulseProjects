import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../common/app_settings.dart';

/// Écran de paramètres globaux PulseProjects.
/// Accessible via le bouton ⚙ de l'AppBar du lanceur.
class SettingsScreen extends StatefulWidget {
  final AppSettings initial;

  const SettingsScreen({super.key, required this.initial});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  final _folderCtrl   = TextEditingController();
  final _exeCtrl      = TextEditingController();
  final _explorerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _settings = widget.initial;
    _folderCtrl.text   = widget.initial.downloadFolder ?? '';
    _exeCtrl.text      = widget.initial.fileManagerExe  ?? '';
    _explorerCtrl.text = widget.initial.explorerExe     ?? '';
  }

  @override
  void dispose() {
    _folderCtrl.dispose();
    _exeCtrl.dispose();
    _explorerCtrl.dispose();
    super.dispose();
  }

  // ── Sélecteur de dossier ──────────────────────────────────────────────────

  Future<void> _pickFolder() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: _folderCtrl.text.isNotEmpty ? _folderCtrl.text : null,
        confirmButtonText: 'Sélectionner',
      );
      if (path != null) setState(() => _folderCtrl.text = path);
    } catch (_) {}
  }

  // ── Sélecteur d'exécutable ────────────────────────────────────────────────

  Future<void> _pickExe() async {
    try {
      final typeGroups = Platform.isWindows
          ? [const XTypeGroup(label: 'Exécutables', extensions: ['exe'])]
          : <XTypeGroup>[];
      final file = await openFile(acceptedTypeGroups: typeGroups);
      if (file != null) setState(() => _exeCtrl.text = file.path);
    } catch (_) {}
  }

  Future<void> _pickExplorerExe() async {
    try {
      final typeGroups = Platform.isWindows
          ? [const XTypeGroup(label: 'Exécutables', extensions: ['exe'])]
          : <XTypeGroup>[];
      final file = await openFile(acceptedTypeGroups: typeGroups);
      if (file != null) setState(() => _explorerCtrl.text = file.path);
    } catch (_) {}
  }

  // ── Sauvegarde ────────────────────────────────────────────────────────────

  void _save() {
    final folder   = _folderCtrl.text.trim();
    final exe      = _exeCtrl.text.trim();
    final explorer = _explorerCtrl.text.trim();
    final updated = _settings.copyWith(
      downloadFolder:  folder.isNotEmpty ? folder : null,
      fileManagerExe:  exe.isNotEmpty    ? exe    : null,
      explorerExe:     explorer.isNotEmpty ? explorer : null,
      clearDownloadFolder:  folder.isEmpty,
      clearFileManagerExe:  exe.isEmpty,
      clearExplorerExe:     explorer.isEmpty,
    );
    Navigator.of(context).pop(updated);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isWindows = Platform.isWindows;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres globaux'),
        actions: [
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Enregistrer'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [

          // ── Section : Application de gestion de fichiers ──────────────────
          _SectionHeader(
            icon: Icons.folder_special_outlined,
            title: 'Application de gestion de fichiers',
            subtitle: 'Optionnel — peut être ouverte après chaque téléchargement.',
          ),
          const SizedBox(height: 12),

          // Exécutable
          _FieldRow(
            label: 'Exécutable de l\'application',
            hint: isWindows ? r'C:\MonApp\MonApp.exe' : '/Applications/MonApp.app',
            controller: _exeCtrl,
            onBrowse: _pickExe,
            onClear: () => setState(() => _exeCtrl.clear()),
            validatePath: true,
          ),
          const SizedBox(height: 8),

          // Dossier de téléchargement
          _FieldRow(
            label: 'Dossier de téléchargement de l\'application',
            hint: isWindows ? r'C:\MonApp\downloads' : '/Users/moi/MonApp/downloads',
            controller: _folderCtrl,
            onBrowse: _pickFolder,
            onClear: () => setState(() => _folderCtrl.clear()),
            isFolder: true,
            validatePath: true,
          ),

          const SizedBox(height: 28),
          Divider(color: cs.outlineVariant),
          const SizedBox(height: 20),

          // ── Section : Explorateur de fichiers ──────────────────────────────
          _SectionHeader(
            icon: Icons.folder_copy_outlined,
            title: 'Explorateur de fichiers',
            subtitle: 'Application utilisée pour parcourir les dossiers depuis '
                'PulseProjects (dossiers de données, sources, releases…). '
                'Laissez vide pour utiliser l\'explorateur natif de l\'OS.',
          ),
          const SizedBox(height: 12),
          _FieldRow(
            label: 'Exécutable de l\'explorateur de fichiers',
            hint: isWindows ? r'C:\MonExplorateur\MonExplorateur.exe' : '/Applications/MonExplorateur.app',
            controller: _explorerCtrl,
            onBrowse: _pickExplorerExe,
            onClear: () => setState(() => _explorerCtrl.clear()),
            validatePath: true,
          ),

          const SizedBox(height: 28),
          Divider(color: cs.outlineVariant),
          const SizedBox(height: 20),

          // ── Section : Comportement des téléchargements ────────────────────
          _SectionHeader(
            icon: Icons.download_outlined,
            title: 'Comportement des téléchargements',
            subtitle: 'Que faire lorsqu\'un fichier est téléchargé depuis le navigateur ?',
          ),
          const SizedBox(height: 16),

          // Choix du mode
          ...DownloadBehavior.values.map((b) => _BehaviorTile(
            value:    b,
            selected: _settings.downloadBehavior,
            onTap:    () => setState(() => _settings = _settings.copyWith(downloadBehavior: b)),
          )),

          const SizedBox(height: 20),

          // Ouvrir l'app après téléchargement
          Card(
            child: SwitchListTile(
              value: _settings.openFileManagerAfterDownload,
              onChanged: (v) => setState(() =>
                  _settings = _settings.copyWith(openFileManagerAfterDownload: v)),
              title: const Text('Ouvrir l\'application après chaque téléchargement'),
              subtitle: Text(
                _settings.hasFileManager
                    ? 'Ouvre "${_settings.fileManagerExe!.split(isWindows ? r'\' : '/').last}" '
                      'une fois le fichier enregistré.'
                    : 'Aucune application configurée ci-dessus.',
                style: TextStyle(
                  color: _settings.hasFileManager ? null : cs.error,
                ),
              ),
              secondary: Icon(
                Icons.open_in_new,
                color: _settings.openFileManagerAfterDownload
                    ? cs.primary
                    : cs.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 28),
          Divider(color: cs.outlineVariant),
          const SizedBox(height: 16),

          // ── Aperçu de la configuration effective ─────────────────────────
          _EffectiveSummary(settings: _settings),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets internes
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;

  const _SectionHeader({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 22, color: cs.primary),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ]),
      ),
    ]);
  }
}

class _FieldRow extends StatelessWidget {
  final String label, hint;
  final TextEditingController controller;
  final VoidCallback onBrowse, onClear;
  final bool isFolder, validatePath;

  const _FieldRow({
    required this.label,
    required this.hint,
    required this.controller,
    required this.onBrowse,
    required this.onClear,
    this.isFolder    = false,
    this.validatePath = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextFormField(
            controller: controller,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              prefixIcon: Icon(isFolder ? Icons.folder_outlined : Icons.apps_outlined, size: 18),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: controller.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: onClear)
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: isFolder ? 'Parcourir…' : 'Choisir l\'exécutable…',
          icon: Icon(isFolder ? Icons.folder_open : Icons.file_open_outlined),
          onPressed: onBrowse,
        ),
      ]),
    ]);
  }
}

class _BehaviorTile extends StatelessWidget {
  final DownloadBehavior value, selected;
  final VoidCallback onTap;

  const _BehaviorTile({required this.value, required this.selected, required this.onTap});

  IconData get _icon {
    switch (value) {
      case DownloadBehavior.disabled:  return Icons.download_outlined;
      case DownloadBehavior.automatic: return Icons.download_done;
      case DownloadBehavior.confirm:   return Icons.rule_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs       = Theme.of(context).colorScheme;
    final isSelected = value == selected;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isSelected ? cs.primaryContainer.withOpacity(0.35) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(_icon, color: isSelected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(child: Text(value.label, style: const TextStyle(fontSize: 13))),
            if (isSelected)
              Icon(Icons.check_circle, color: cs.primary, size: 20),
          ]),
        ),
      ),
    );
  }
}

class _EffectiveSummary extends StatelessWidget {
  final AppSettings settings;

  const _EffectiveSummary({required this.settings});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Configuration effective', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
        const SizedBox(height: 10),
        _SummaryRow(Icons.download_for_offline_outlined, 'Dossier downloads',
            settings.effectiveDownloadFolder),
        _SummaryRow(Icons.folder_special_outlined, 'Application',
            settings.hasFileManager ? settings.fileManagerExe! : '(aucune)'),
        _SummaryRow(Icons.settings_outlined, 'Mode',
            settings.downloadBehavior.label),
        _SummaryRow(Icons.open_in_new, 'Ouvrir app après DL',
            settings.openFileManagerAfterDownload && settings.hasFileManager ? 'Oui' : 'Non'),
        _SummaryRow(Icons.folder_copy_outlined, 'Explorateur de fichiers',
            settings.hasExplorer ? settings.explorerExe! : '(natif de l\'OS)'),
      ]),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label, value;

  const _SummaryRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 8),
        SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
