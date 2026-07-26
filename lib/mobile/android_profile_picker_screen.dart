import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'android_app_control.dart';
import 'android_export_service.dart';
import 'android_profile.dart';
import 'android_profile_repository.dart';

/// Écran de sélection de profil Android. Affiché au démarrage tant
/// qu'aucun profil n'est actif, et accessible depuis le navigateur via
/// "Changer de profil".
///
/// Activer un profil (tap sur la tuile) déclenche un redémarrage complet
/// de l'application : c'est la seule façon d'appliquer un nouveau suffixe
/// WebView.setDataDirectorySuffix() (voir AndroidAppControl).
class AndroidProfilePickerScreen extends StatefulWidget {
  final AndroidProfileRepository repository;

  const AndroidProfilePickerScreen({super.key, required this.repository});

  @override
  State<AndroidProfilePickerScreen> createState() => _AndroidProfilePickerScreenState();
}

class _AndroidProfilePickerScreenState extends State<AndroidProfilePickerScreen> {
  List<AndroidProfile> _profiles = [];
  bool _loading = true;
  bool _activating = false;
  final _exportService = AndroidExportService();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await widget.repository.load();
    profiles.sort((a, b) {
      final ad = a.lastUsedAt, bd = b.lastUsedAt;
      if (ad == null && bd == null) return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (ad == null) return 1;
      if (bd == null) return -1;
      return bd.compareTo(ad);
    });
    if (!mounted) return;
    setState(() { _profiles = profiles; _loading = false; });
  }

  Future<void> _createProfile() async {
    final result = await showDialog<AndroidProfile>(
      context: context,
      builder: (_) => const _ProfileDialog(),
    );
    if (result == null) return;
    setState(() => _profiles.insert(0, result));
    await widget.repository.save(_profiles);
  }

  Future<void> _editProfile(AndroidProfile profile) async {
    final result = await showDialog<AndroidProfile>(
      context: context,
      builder: (_) => _ProfileDialog(existing: profile),
    );
    if (result == null) return;
    setState(() {
      final idx = _profiles.indexWhere((p) => p.id == profile.id);
      if (idx != -1) _profiles[idx] = result;
    });
    await widget.repository.save(_profiles);
  }

  Future<void> _deleteProfile(AndroidProfile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer le profil'),
        content: Text(
          'Supprimer "${profile.name}" ?\n\n'
          'Les données de navigation (cookies, session…) resteront sur '
          'l\'appareil mais ne seront plus accessibles depuis PulseProjects.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _profiles.removeWhere((p) => p.id == profile.id));
    await widget.repository.save(_profiles);
  }

  Future<void> _activate(AndroidProfile profile) async {
    setState(() => _activating = true);

    profile.lastUsedAt = DateTime.now();
    await widget.repository.save(_profiles);
    await widget.repository.setCurrentProfileId(profile.id);

    // Redémarrage obligatoire : voir AndroidAppControl pour le détail de
    // cette contrainte de l'API WebView Android.
    await AndroidAppControl.restart();
    // Le process se termine dans Runtime.exit(0) côté natif juste après —
    // ce setState ne sera généralement jamais atteint, laissé par sécurité.
    if (mounted) setState(() => _activating = false);
  }

  // ── Export / Import ───────────────────────────────────────────────────────

  Future<void> _exportProfile(AndroidProfile profile) async {
    final currentId = await widget.repository.getCurrentProfileId();
    if (currentId == profile.id && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Profil actuellement actif'),
          content: const Text(
            'Ce profil est celui actuellement actif sur cet appareil. '
            'Certaines données très récentes pourraient être verrouillées '
            'par le moteur WebView et absentes de l\'export.\n\n'
            'Continuer quand même ?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continuer')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    String? savePath;
    try {
      final location = await getSaveLocation(
        suggestedName: '${_sanitizeFileName(profile.name)}.pulseproject.zip',
        acceptedTypeGroups: [const XTypeGroup(label: 'ZIP', extensions: ['zip'])],
        confirmButtonText: 'Exporter',
      );
      savePath = location?.path;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible d\'ouvrir le sélecteur de fichier : $e')),
      );
      return;
    }
    if (savePath == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 16),
          Text('Export en cours…'),
        ]),
      ),
    );

    try {
      await _exportService.exportProfile(profile, savePath);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Profil "${profile.name}" exporté avec succès')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'export : $e')),
      );
    }
  }

  Future<void> _importProfile() async {
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Export PulseProjects', extensions: ['zip']),
        ],
        confirmButtonText: 'Importer',
      );
    } catch (e) {
      // Le sélecteur de fichier natif peut lever une exception (canal de
      // plateforme indisponible, permission refusée...) — on l'intercepte
      // ici pour ne jamais laisser planter l'application.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible d\'ouvrir le sélecteur de fichier : $e')),
      );
      return;
    }
    if (file == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 16),
          Text('Import en cours…'),
        ]),
      ),
    );

    try {
      final imported = await _exportService.importAny(file.path);
      setState(() => _profiles.insertAll(0, imported));
      await widget.repository.save(_profiles);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PulseProjects'),
        actions: [
          if (!_loading && !_activating)
            IconButton(
              tooltip: 'Importer un profil (.zip)',
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _importProfile,
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _activating
              ? const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Redémarrage pour activer le profil…'),
                  ]),
                )
              : _profiles.isEmpty
                  ? _EmptyState(onCreate: _createProfile)
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _profiles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final p = _profiles[i];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(p.name.isNotEmpty ? p.name[0].toUpperCase() : '?'),
                            ),
                            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(p.homeUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => _activate(p),
                            trailing: PopupMenuButton<String>(
                              itemBuilder: (ctx) => const [
                                PopupMenuItem(value: 'edit', child: Text('Modifier')),
                                PopupMenuItem(value: 'export', child: Text('Exporter')),
                                PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                              ],
                              onSelected: (v) {
                                if (v == 'edit') _editProfile(p);
                                if (v == 'export') _exportProfile(p);
                                if (v == 'delete') _deleteProfile(p);
                              },
                            ),
                          ),
                        );
                      },
                    ),
      floatingActionButton: (_loading || _activating)
          ? null
          : FloatingActionButton.extended(
              onPressed: _createProfile,
              icon: const Icon(Icons.add),
              label: const Text('Nouveau profil'),
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
        const Icon(Icons.public, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('Aucun profil', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Un seul profil peut être actif à la fois sur Android '
            '(limitation de l\'API WebView). Créez-en un pour commencer.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Créer un profil'),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ProfileDialog extends StatefulWidget {
  final AndroidProfile? existing;
  const _ProfileDialog({this.existing});

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _urlCtrl = TextEditingController(text: widget.existing?.homeUrl ?? 'https://');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  String? _validateUrl(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Champ requis';
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return 'URL invalide';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final profile = widget.existing ??
        AndroidProfile(
          id: const Uuid().v4(),
          name: '',
          homeUrl: '',
          createdAt: DateTime.now(),
        );
    profile.name = _nameCtrl.text.trim();
    profile.homeUrl = _urlCtrl.text.trim();
    Navigator.pop(context, profile);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing != null ? 'Modifier le profil' : 'Nouveau profil'),
      content: Form(
        key: _formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nom du profil'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL de démarrage',
              hintText: 'https://...',
            ),
            keyboardType: TextInputType.url,
            validator: _validateUrl,
            onFieldSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}
