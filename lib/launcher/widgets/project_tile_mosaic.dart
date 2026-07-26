import 'package:flutter/material.dart';

import '../models/project.dart';
import 'reorderable_tile.dart';

/// Tuile mosaïque (style "tuile de lanceur") : icône centrale, nom,
/// indicateur d'exécution, menu d'actions discret. Utilisée en mode
/// d'affichage « mosaïque ».
class ProjectTileMosaic extends StatelessWidget {
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

  const ProjectTileMosaic({
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

    return SizedBox(
      width: 168,
      height: 148,
      child: Material(
        color: isRunning ? cs.primaryContainer.withOpacity(0.3) : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onLaunch,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isRunning ? cs.primary : cs.outlineVariant.withOpacity(0.5),
                width: isRunning ? 2 : 1,
              ),
            ),
            child: Stack(children: [
              // Contenu principal centré
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Stack(clipBehavior: Clip.none, children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: isRunning ? cs.primary : cs.surfaceContainerHighest,
                        foregroundColor: isRunning ? cs.onPrimary : cs.onSurfaceVariant,
                        child: Text(initial, style: const TextStyle(fontSize: 18)),
                      ),
                      if (isRunning)
                        Positioned(
                          bottom: -2, right: -2,
                          child: Container(
                            width: 14, height: 14,
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border: Border.all(color: cs.surface, width: 2),
                            ),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 10),
                    Text(
                      project.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    if (isRunning) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Ouvert',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Poignée de drag (coin haut-gauche)
              Positioned(
                top: 4, left: 4,
                child: DragHandle(
                  index: index,
                  icon: Icon(Icons.drag_indicator, size: 16, color: cs.outline),
                ),
              ),

              // Menu d'actions (coin haut-droit)
              Positioned(
                top: 0, right: 0,
                child: PopupMenuButton<_Action>(
                  icon: Icon(Icons.more_vert, size: 16, color: cs.outline),
                  tooltip: 'Actions',
                  padding: EdgeInsets.zero,
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: _Action.edit,   child: Row(children: [
                      Icon(Icons.edit_outlined, size: 16), SizedBox(width: 8), Text('Modifier'),
                    ])),
                    PopupMenuItem(value: _Action.folder, child: Row(children: [
                      Icon(Icons.folder_open_outlined, size: 16), SizedBox(width: 8), Text('Dossier de données'),
                    ])),
                    PopupMenuItem(value: _Action.export, child: Row(children: [
                      Icon(Icons.ios_share, size: 16), SizedBox(width: 8), Text('Exporter'),
                    ])),
                    PopupMenuItem(value: _Action.moveToFlutter, child: Row(children: [
                      Icon(Icons.flutter_dash, size: 16), SizedBox(width: 8), Text('Déplacer vers Projets Flutter'),
                    ])),
                    PopupMenuItem(value: _Action.reset,  child: Row(children: [
                      Icon(Icons.restart_alt, size: 16), SizedBox(width: 8), Text('Réinitialiser'),
                    ])),
                    PopupMenuDivider(),
                    PopupMenuItem(value: _Action.delete, child: Row(children: [
                      Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8),
                      Text('Supprimer', style: TextStyle(color: Colors.red)),
                    ])),
                  ],
                  onSelected: (a) {
                    switch (a) {
                      case _Action.edit:          onEdit();          break;
                      case _Action.folder:        onOpenFolder();    break;
                      case _Action.export:        onExport();        break;
                      case _Action.moveToFlutter: onMoveToFlutter(); break;
                      case _Action.reset:         onResetData();     break;
                      case _Action.delete:        onDelete();        break;
                    }
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

enum _Action { edit, folder, export, moveToFlutter, reset, delete }
