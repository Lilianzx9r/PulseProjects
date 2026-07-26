import 'package:flutter/material.dart';

/// Poignée de glisser-déposer : démarre un drag dès le pan (pas besoin
/// de long-press), pour réordonner les profils sans entrer en conflit
/// avec les boutons d'action (lancer, modifier, supprimer…) qui restent
/// cliquables normalement sur le reste de la tuile.
class DragHandle extends StatelessWidget {
  final int index;
  final Widget icon;

  const DragHandle({super.key, required this.index, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Draggable<int>(
      data: index,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.7, child: icon),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: icon),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: icon,
      ),
    );
  }
}

/// Enrobe une tuile (détaillée, compacte ou mosaïque) pour la rendre
/// "cible de dépôt" lors d'un glisser-déposer : déposer une autre tuile
/// dessus échange leur position dans la liste.
///
/// Le glissement lui-même est déclenché par un [DragHandle] placé À
/// L'INTÉRIEUR de [child] (icône ⠿), pas par toute la tuile — ce qui
/// évite les conflits avec le tap (lancement) et les boutons d'action.
class ReorderDropTarget extends StatelessWidget {
  final int index;
  final Widget child;
  final void Function(int fromIndex, int toIndex) onReorder;
  final BorderRadius borderRadius;

  const ReorderDropTarget({
    super.key,
    required this.index,
    required this.child,
    required this.onReorder,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onReorder(details.data, index),
      builder: (context, candidate, rejected) {
        final highlight = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: highlight
                ? Border.all(color: cs.primary, width: 2)
                : Border.all(color: Colors.transparent, width: 2),
          ),
          child: child,
        );
      },
    );
  }
}
