import 'package:flutter/material.dart';

import '../models/project.dart';
import 'reorderable_tile.dart';

/// Ligne compacte (1 ligne par profil) : avatar, nom, URL, statut,
/// actions réduites. Utilisée en mode d'affichage « condensé ».
class ProjectRowCompact extends StatelessWidget {
  final int index;
  final Project project;
  final bool isRunning;
  final VoidCallback onLaunch;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;
  final VoidCallback onResetData;
  final VoidCallback onExport;
  final VoidCallback onMoveToFlutter;

  const ProjectRowCompact({
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

  @override
  Widget build(BuildContext context) {
    final cs      = Theme.of(context).colorScheme;
    final initial = project.name.isNotEmpty ? project.name[0].toUpperCase() : '?';

    return Material(
      color: isRunning ? cs.primaryContainer.withOpacity(0.25) : cs.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onLaunch,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isRunning ? cs.primary : cs.outlineVariant.withOpacity(0.5),
              width: isRunning ? 1.5 : 1,
            ),
          ),
          child: Row(children: [
            // Poignée de drag
            DragHandle(
              index: index,
              icon: Icon(Icons.drag_indicator, size: 16, color: cs.outline),
            ),
            const SizedBox(width: 8),

            // Avatar + pastille
            SizedBox(
              width: 28, height: 28,
              child: Stack(clipBehavior: Clip.none, children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: isRunning ? cs.primary : cs.surfaceContainerHighest,
                  foregroundColor: isRunning ? cs.onPrimary : cs.onSurfaceVariant,
                  child: Text(initial, style: const TextStyle(fontSize: 11)),
                ),
                if (isRunning)
                  Positioned(
                    bottom: -1, right: -1,
                    child: Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 1),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 10),

            // Nom
            SizedBox(
              width: 170,
              child: Text(
                project.name,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),

            // URL
            Expanded(
              child: Text(
                project.homeUrl,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // Actions
            IconButton(
              tooltip: 'Modifier',
              icon: const Icon(Icons.edit_outlined, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Dossier de données',
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onOpenFolder,
            ),
            IconButton(
              tooltip: 'Exporter ce profil',
              icon: const Icon(Icons.ios_share, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onExport,
            ),
            IconButton(
              tooltip: 'Déplacer vers Projets Flutter',
              icon: const Icon(Icons.flutter_dash, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onMoveToFlutter,
            ),
            IconButton(
              tooltip: 'Réinitialiser',
              icon: const Icon(Icons.restart_alt, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onResetData,
            ),
            IconButton(
              tooltip: 'Supprimer',
              icon: const Icon(Icons.delete_outline, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            ),
          ]),
        ),
      ),
    );
  }
}
