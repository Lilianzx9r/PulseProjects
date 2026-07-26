import 'dart:io';

import 'package:flutter/material.dart';

import '../common/app_settings.dart';
import '../common/file_launcher.dart';
import 'downloads_watcher.dart';

/// Panneau de notification affiché en bas du navigateur quand un nouveau
/// fichier est détecté dans le dossier Téléchargements de l'OS.
///
/// Mode [DownloadBehavior.automatic] : déplacement silencieux déjà fait,
///   on affiche juste une confirmation avec bouton "Ouvrir l'app".
///
/// Mode [DownloadBehavior.confirm] : demande confirmation avant de déplacer.
class DownloadNotificationPanel extends StatelessWidget {
  final List<_DownloadNotif> notifications;
  final VoidCallback onDismissAll;

  const DownloadNotificationPanel({
    super.key,
    required this.notifications,
    required this.onDismissAll,
  });

  @override
  Widget build(BuildContext context) {
    if (notifications.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            const Icon(Icons.download, size: 16),
            const SizedBox(width: 8),
            Text('Fichiers détectés', style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            TextButton.icon(
              onPressed: onDismissAll,
              icon: const Icon(Icons.clear_all, size: 16),
              label: const Text('Tout effacer'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ]),
        ),
        const Divider(height: 1),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: notifications.length,
            itemBuilder: (_, i) => _NotifTile(notif: notifications[i]),
          ),
        ),
      ]),
    );
  }
}

/// Entrée interne d'une notification (état mutable pour la progression).
class _DownloadNotif extends ChangeNotifier {
  final DownloadDetected detected;
  final DownloadBehavior behavior;
  final String? targetFolder;
  final VoidCallback? openFileManager;
  final VoidCallback onDismiss;

  String? movedPath;
  bool    moving  = false;
  bool    done    = false;
  String? error;

  _DownloadNotif({
    required this.detected,
    required this.behavior,
    required this.targetFolder,
    required this.onDismiss,
    this.openFileManager,
  });

  Future<void> doMove() async {
    if (moving || done || targetFolder == null) return;
    moving = true;
    notifyListeners();

    final result = await moveToFolder(
      sourcePath:  detected.sourcePath,
      destFolder:  targetFolder!,
    );
    if (result.success) {
      movedPath = result.destPath;
      done      = true;
    } else {
      error = result.error;
    }
    moving = false;
    notifyListeners();

    if (done) openFileManager?.call();
  }
}

class _NotifTile extends StatelessWidget {
  final _DownloadNotif notif;

  const _NotifTile({super.key, required this.notif});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: notif,
      builder: (_, __) {
        Widget leading;
        if (notif.moving) {
          leading = const SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        } else if (notif.done) {
          leading = const Icon(Icons.check_circle, color: Colors.green, size: 20);
        } else if (notif.error != null) {
          leading = const Icon(Icons.error_outline, color: Colors.red, size: 20);
        } else {
          leading = Icon(Icons.file_present_outlined, color: cs.primary, size: 20);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(notif.detected.fileName,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                if (notif.done && notif.movedPath != null)
                  Text('→ ${notif.movedPath!}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                if (notif.error != null)
                  Text('Erreur : ${notif.error}',
                      style: const TextStyle(fontSize: 11, color: Colors.red)),
                if (!notif.done && notif.error == null && notif.targetFolder != null)
                  Text('→ ${notif.targetFolder}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            // Actions
            if (!notif.done && notif.error == null && notif.targetFolder != null &&
                notif.behavior == DownloadBehavior.confirm)
              FilledButton.tonal(
                onPressed: notif.doMove,
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
                child: const Text('Déplacer', style: TextStyle(fontSize: 12)),
              ),
            if (notif.done)
              IconButton(
                tooltip: 'Ouvrir le fichier',
                icon: const Icon(Icons.open_in_new, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => openFile(notif.movedPath ?? notif.detected.sourcePath),
              ),
            IconButton(
              tooltip: 'Ignorer',
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: notif.onDismiss,
            ),
          ]),
        );
      },
    );
  }
}

/// Mixin réutilisable par [_BrowserViewState] (Windows) et
/// [_BrowserViewMacOSState] (macOS) pour gérer le watcher + les notifications.
mixin DownloadWatcherMixin<T extends StatefulWidget> on State<T> {
  final List<_DownloadNotif> _notifs = [];
  DownloadsWatcher? _watcher;
  bool _showNotifs = false;

  /// À appeler dans initState() avec les settings courants.
  Future<void> startWatcher(AppSettings settings) async {
    _watcher?.stop();
    if (settings.downloadBehavior == DownloadBehavior.disabled) return;
    if (!settings.hasDownloadFolder) return;

    _watcher = DownloadsWatcher(
      settings:  settings,
      onNewFile: (event) => _onNewFile(event, settings),
    );
    await _watcher!.start();
  }

  void stopWatcher() {
    _watcher?.stop();
    _watcher = null;
  }

  void _onNewFile(DownloadDetected event, AppSettings settings) {
    if (!mounted) return;

    final notif = _DownloadNotif(
      detected:       event,
      behavior:       settings.downloadBehavior,
      targetFolder:   settings.downloadFolder,
      openFileManager: settings.openFileManagerAfterDownload && settings.hasFileManager
          ? () => _launchFileManager(settings.fileManagerExe!)
          : null,
      onDismiss: () {
        if (!mounted) return;
        setState(() {
          _notifs.removeWhere((n) => n.detected.sourcePath == event.sourcePath);
          if (_notifs.isEmpty) _showNotifs = false;
        });
      },
    );

    setState(() {
      _notifs.add(notif);
      _showNotifs = true;
    });

    // En mode automatique : lancer le déplacement immédiatement
    if (settings.downloadBehavior == DownloadBehavior.automatic) {
      notif.doMove();
    }
  }

  void _launchFileManager(String exe) {
    try {
      Process.start(exe, [], mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  void dismissAllNotifs() {
    if (!mounted) return;
    setState(() {
      _notifs.clear();
      _showNotifs = false;
    });
  }

  Widget buildNotifPanel() {
    if (!_showNotifs || _notifs.isEmpty) return const SizedBox.shrink();
    return DownloadNotificationPanel(
      notifications: List.unmodifiable(_notifs),
      onDismissAll: dismissAllNotifs,
    );
  }

  int get notifCount => _notifs.length;
  bool get hasNotifs  => _notifs.isNotEmpty;
}
