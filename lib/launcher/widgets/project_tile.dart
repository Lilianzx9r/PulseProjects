import 'package:flutter/material.dart';

import '../models/project.dart';
import 'reorderable_tile.dart';

/// Tuile détaillée (mode d'affichage par défaut) : avatar, nom, URL,
/// dossier de travail, date du dernier lancement, actions complètes.
class ProjectTile extends StatelessWidget {
  final int          index;
  final Project      project;
  final bool         isRunning;
  final VoidCallback onLaunch;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;
  final VoidCallback onResetData;
  final VoidCallback onExport;
  final VoidCallback onMoveToFlutter;

  const ProjectTile({
    super.key,
    required this.index,
    required this.project,
    required this.isRunning,
    required this.onLaunch,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenFolder,
    required this.onResetData,
    required this.onExport,
    required this.onMoveToFlutter,
  });

  String _fmt(DateTime d) {
    final dd  = d.day.toString().padLeft(2, '0');
    final mm  = d.month.toString().padLeft(2, '0');
    final hh  = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year} à $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final cs      = Theme.of(context).colorScheme;
    final initial = project.name.isNotEmpty ? project.name[0].toUpperCase() : '?';
    final last    = project.lastLaunchedAt;
    final hasFolder = project.workFolder?.isNotEmpty == true;

    return Card(
      color: isRunning ? cs.primaryContainer.withOpacity(0.25) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isRunning ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
      ),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Poignée de drag
            DragHandle(
              index: index,
              icon: Icon(Icons.drag_indicator, size: 18, color: cs.outline),
            ),
            const SizedBox(width: 6),
            // Avatar + pastille
            Stack(clipBehavior: Clip.none, children: [
              CircleAvatar(
                backgroundColor: isRunning ? cs.primary : null,
                foregroundColor: isRunning ? cs.onPrimary : null,
                child: Text(initial),
              ),
              if (isRunning)
                Positioned(
                  bottom: -2, right: -2,
                  child: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color:  Colors.green,
                      shape:  BoxShape.circle,
                      border: Border.all(color: Theme.of(context).cardColor, width: 1.5),
                    ),
                  ),
                ),
            ]),
          ],
        ),
        title: Row(children: [
          Text(project.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (isRunning) ...[
            const SizedBox(width: 8),
            Chip(
              label: const Text('Ouvert', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              backgroundColor: Colors.green.shade100,
              side: BorderSide(color: Colors.green.shade400),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(project.homeUrl, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            if (hasFolder)
              Row(children: [
                const Icon(Icons.folder_outlined, size: 12, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    project.workFolder!,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            Text('Dernier lancement : ${last != null ? _fmt(last) : 'jamais'}',
                style: const TextStyle(fontSize: 11)),
          ],
        ),
        isThreeLine: true,
        onTap: onLaunch,
        trailing: Wrap(spacing: 0, children: [
          IconButton(
            tooltip: isRunning ? 'Mettre au premier plan' : 'Lancer',
            icon: Icon(isRunning ? Icons.open_in_new : Icons.play_circle_fill,
                color: isRunning ? cs.primary : null),
            onPressed: onLaunch,
          ),
          IconButton(tooltip: 'Modifier', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
          IconButton(tooltip: 'Ouvrir le dossier de données', icon: const Icon(Icons.folder_open_outlined), onPressed: onOpenFolder),
          IconButton(tooltip: 'Exporter ce profil', icon: const Icon(Icons.ios_share), onPressed: onExport),
          IconButton(
            tooltip: 'Déplacer vers Projets Flutter',
            icon: const Icon(Icons.flutter_dash),
            onPressed: onMoveToFlutter,
          ),
          IconButton(tooltip: 'Réinitialiser les données', icon: const Icon(Icons.restart_alt), onPressed: onResetData),
          IconButton(tooltip: 'Supprimer', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ]),
      ),
    );
  }
}
