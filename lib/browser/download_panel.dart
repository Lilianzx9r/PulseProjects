import 'package:flutter/material.dart';

import '../common/file_launcher.dart';
import 'download_manager.dart';

/// Panneau de téléchargements en bas du navigateur.
/// Affiché uniquement quand la liste est non vide.
class DownloadPanel extends StatelessWidget {
  final DownloadManager manager;

  const DownloadPanel({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    final items = manager.items;
    if (items.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // En-tête
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.download, size: 16),
                const SizedBox(width: 8),
                Text('Téléchargements',
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                TextButton.icon(
                  onPressed: manager.removeCompleted,
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Effacer terminés'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Liste
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (_, i) => _DownloadTile(
                item: items[i],
                onRemove: () => manager.remove(items[i].id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  final VoidCallback onRemove;

  const _DownloadTile({required this.item, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final done = item.status == DownloadStatus.done;
    final error = item.status == DownloadStatus.error;
    final active = item.status == DownloadStatus.downloading;

    final Widget leading = SizedBox(
      width: 22,
      height: 22,
      child: active
          ? CircularProgressIndicator(value: item.progress, strokeWidth: 2.5)
          : done
              ? const Icon(Icons.check_circle, color: Colors.green, size: 22)
              : const Icon(Icons.error_outline, color: Colors.red, size: 22),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.fileName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                if (active) ...[
                  Text(item.progressText,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: item.progress,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
                if (done)
                  Text(
                    item.totalBytes > 0
                        ? item.progressText.split('/').last.trim()
                        : 'Terminé',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                if (error)
                  Text(item.errorMessage ?? 'Erreur',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.red)),
              ],
            ),
          ),
          // Actions
          if (done) ...[
            IconButton(
              tooltip: 'Ouvrir',
              icon: const Icon(Icons.open_in_new, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: () => openFile(item.savePath),
            ),
            IconButton(
              tooltip: 'Afficher dans l\'Explorateur',
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: () => revealInExplorer(item.savePath),
            ),
          ],
          IconButton(
            tooltip: done || error ? 'Supprimer de la liste' : 'Annuler',
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
