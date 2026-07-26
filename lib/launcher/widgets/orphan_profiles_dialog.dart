import 'package:flutter/material.dart';

import '../data/orphan_profile_scanner.dart';
import '../models/project.dart';
import 'project_dialog.dart';

/// Dialogue de récupération des profils orphelins : dossiers de données
/// WebView2/WKWebView présents sur le disque mais dont l'entrée a disparu
/// de la liste des profils (ex: suite à un déplacement Web → Flutter
/// interrompu par un bug avant construction de l'onglet Flutter).
///
/// Restaurer un profil réutilise le MÊME identifiant que le dossier
/// orphelin (via [ProjectDialog] avec `existing`), ce qui rattache le
/// nouveau profil exactement aux mêmes cookies/session/stockage local déjà
/// présents sur disque — la session est retrouvée telle quelle.
class OrphanProfilesDialog extends StatefulWidget {
  final List<Project> knownProjects;
  final Future<void> Function(Project project) onRestore;

  const OrphanProfilesDialog({
    super.key,
    required this.knownProjects,
    required this.onRestore,
  });

  @override
  State<OrphanProfilesDialog> createState() => _OrphanProfilesDialogState();
}

class _OrphanProfilesDialogState extends State<OrphanProfilesDialog> {
  bool _loading = true;
  List<OrphanProfile> _orphans = [];
  final _restored = <String>{}; // ids déjà restaurés dans cette session de dialogue

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final found = await scanOrphanProfiles(widget.knownProjects);
    if (!mounted) return;
    setState(() { _orphans = found; _loading = false; });
  }

  Future<void> _restore(OrphanProfile orphan) async {
    final temp = Project(
      id: orphan.id, // même id → mêmes cookies/session/stockage local
      name: '',
      homeUrl: 'https://',
      createdAt: orphan.modifiedAt ?? DateTime.now(),
    );

    final result = await showDialog<Project>(
      context: context,
      builder: (_) => ProjectDialog(
        existing: temp,
        titleOverride: 'Restaurer le profil orphelin',
        submitLabelOverride: 'Restaurer',
      ),
    );
    if (result == null) return;

    await widget.onRestore(result);

    if (!mounted) return;
    setState(() => _restored.add(orphan.id));
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return 'Date inconnue';
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year} à $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Profils orphelins'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _orphans.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check_circle_outline, size: 40, color: cs.primary),
                      const SizedBox(height: 12),
                      const Text('Aucun profil orphelin trouvé.',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          'Tous les dossiers de données présents sur le disque '
                          'sont déjà rattachés à un profil de la liste.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ]),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        '${_orphans.length} dossier${_orphans.length > 1 ? 's' : ''} de données '
                        'trouvé${_orphans.length > 1 ? 's' : ''} sans profil associé. '
                        'Restaurez ceux que vous reconnaissez (session, cookies et '
                        'stockage local seront conservés).',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _orphans.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final o = _orphans[i];
                          final done = _restored.contains(o.id);
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              done ? Icons.check_circle : Icons.folder_shared_outlined,
                              color: done ? Colors.green : cs.onSurfaceVariant,
                            ),
                            title: Text(o.id,
                                style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text('Modifié le ${_fmtDate(o.modifiedAt)}',
                                style: const TextStyle(fontSize: 11)),
                            trailing: done
                                ? const Text('Restauré', style: TextStyle(fontSize: 11, color: Colors.green))
                                : FilledButton.tonal(
                                    onPressed: () => _restore(o),
                                    style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(horizontal: 12)),
                                    child: const Text('Restaurer', style: TextStyle(fontSize: 12)),
                                  ),
                          );
                        },
                      ),
                    ),
                  ]),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
