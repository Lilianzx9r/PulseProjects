import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_settings.dart';

/// Événement émis quand un nouveau fichier apparaît dans le dossier surveillé.
class DownloadDetected {
  final String sourcePath;   // chemin du fichier détecté dans le dossier OS
  final String fileName;
  final DateTime detectedAt;

  DownloadDetected({
    required this.sourcePath,
    required this.fileName,
    required this.detectedAt,
  });
}

/// Surveille le dossier Téléchargements de l'OS pour détecter les nouveaux
/// fichiers déposés par WebView2 (qui gère ses téléchargements nativement
/// sans passer par Dart/Flutter).
///
/// Quand un nouveau fichier est détecté et que [AppSettings] configure un
/// dossier de l'app, il est automatiquement déplacé (mode automatique) ou
/// l'UI est notifiée pour proposer le déplacement (mode confirmation).
///
/// L'approche watcher est préférable à l'interception pré-download car
/// `webview_win_floating` ne fournit pas d'API Dart pour intercepter les
/// téléchargements WebView2 : ils tombent directement dans le dossier de
/// l'OS.
class DownloadsWatcher {
  final AppSettings settings;
  final void Function(DownloadDetected event) onNewFile;

  StreamSubscription<FileSystemEvent>? _sub;
  final _seen = <String>{};  // chemins déjà notifiés dans cette session

  DownloadsWatcher({required this.settings, required this.onNewFile});

  /// Commence la surveillance. Silencieux si le système de fichiers watcher
  /// n'est pas disponible ou si le comportement est "disabled".
  Future<void> start() async {
    if (settings.downloadBehavior == DownloadBehavior.disabled) return;
    if (!settings.hasDownloadFolder) return;

    final watchDir = Directory(_osDownloadsFolder());
    if (!await watchDir.exists()) return;

    try {
      _sub = watchDir
          .watch(events: FileSystemEvent.create | FileSystemEvent.modify)
          .where((e) => e is FileSystemCreateEvent || e is FileSystemModifyEvent)
          .listen(_onEvent, onError: (_) {});
    } catch (_) {
      // FileSystemWatcher non disponible (ex: réseau, permissions) → no-op
    }
  }

  void _onEvent(FileSystemEvent event) {
    final path = event.path;
    if (_seen.contains(path)) return;

    // Ignorer les fichiers partiels (.crdownload = Chrome en cours de DL)
    final name = p.basename(path);
    if (name.endsWith('.crdownload') || name.endsWith('.tmp') ||
        name.endsWith('.part') || name.startsWith('.')) return;

    // Attendre que le fichier soit complet (taille stable)
    _waitAndEmit(path, name);
  }

  Future<void> _waitAndEmit(String path, String name) async {
    // On attend jusqu'à 30 s que le fichier ne grandisse plus
    int? lastSize;
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        final size = await File(path).length();
        if (size == lastSize && size > 0) break; // stable
        lastSize = size;
      } catch (_) {
        return; // fichier disparu
      }
    }

    if (_seen.contains(path)) return;
    _seen.add(path);

    onNewFile(DownloadDetected(
      sourcePath:  path,
      fileName:    name,
      detectedAt:  DateTime.now(),
    ));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  static String _osDownloadsFolder() {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ??
          '${Platform.environment['HOMEDRIVE'] ?? 'C:'}${Platform.environment['HOMEPATH'] ?? r'\Users\Default'}';
      return '$profile\\Downloads';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/Downloads';
    }
    return '.';
  }
}

/// Résultat d'un déplacement de fichier.
class MoveResult {
  final String sourcePath;
  final String destPath;
  final bool   success;
  final String? error;

  const MoveResult({
    required this.sourcePath,
    required this.destPath,
    required this.success,
    this.error,
  });
}

/// Déplace [sourcePath] vers [destFolder]/[fileName].
/// Retourne [MoveResult] avec le chemin de destination effectif.
Future<MoveResult> moveToFolder({
  required String sourcePath,
  required String destFolder,
}) async {
  final name     = p.basename(sourcePath);
  var destPath   = p.join(destFolder, name);

  try {
    await Directory(destFolder).create(recursive: true);

    // Résolution de collision de noms
    if (File(destPath).existsSync()) {
      final ext  = p.extension(name);
      final base = p.basenameWithoutExtension(name);
      var i = 1;
      while (File(destPath).existsSync()) {
        destPath = p.join(destFolder, '$base ($i)$ext');
        i++;
      }
    }

    await File(sourcePath).rename(destPath);
    return MoveResult(sourcePath: sourcePath, destPath: destPath, success: true);
  } catch (e) {
    // rename peut échouer cross-device → copie + suppression
    try {
      await File(sourcePath).copy(destPath);
      await File(sourcePath).delete();
      return MoveResult(sourcePath: sourcePath, destPath: destPath, success: true);
    } catch (e2) {
      return MoveResult(
        sourcePath: sourcePath, destPath: destPath,
        success: false, error: e2.toString(),
      );
    }
  }
}
