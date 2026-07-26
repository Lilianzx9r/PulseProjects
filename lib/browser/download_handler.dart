import 'dart:io';

import '../common/app_settings.dart';
import '../common/file_launcher.dart';

/// Résout le chemin de destination d'un fichier à télécharger selon
/// les paramètres globaux [AppSettings], et gère l'ouverture de
/// l'application de gestion de fichiers après téléchargement.
class DownloadHandler {
  final AppSettings settings;

  const DownloadHandler(this.settings);

  /// Dossier effectif vers lequel sauvegarder les téléchargements.
  /// Si [AppSettings.hasDownloadFolder] et le comportement n'est pas
  /// [DownloadBehavior.disabled], on redirige vers le dossier de l'app.
  /// Sinon on retourne null (comportement par défaut de l'OS).
  String? get targetFolder {
    if (settings.downloadBehavior == DownloadBehavior.disabled) return null;
    if (!settings.hasDownloadFolder) return null;
    return settings.downloadFolder;
  }

  /// Indique si le téléchargement doit se faire automatiquement sans
  /// dialogue "Enregistrer sous".
  bool get isAutomatic =>
      settings.downloadBehavior == DownloadBehavior.automatic &&
      settings.hasDownloadFolder;

  /// Indique si le dialogue "Enregistrer sous" doit s'afficher pré-positionné
  /// sur le dossier de l'app (mode "confirm").
  bool get isConfirm =>
      settings.downloadBehavior == DownloadBehavior.confirm &&
      settings.hasDownloadFolder;

  /// Chemin de destination automatique pour [fileName] en mode [isAutomatic].
  /// Retourne null si le mode n'est pas automatique.
  String? automaticSavePath(String fileName) {
    if (!isAutomatic) return null;
    final folder = settings.downloadFolder!;
    // Crée le dossier si nécessaire
    try { Directory(folder).createSync(recursive: true); } catch (_) {}
    final sep = Platform.pathSeparator;
    return '$folder$sep$fileName';
  }

  /// Dossier initial à proposer dans le dialogue "Enregistrer sous".
  /// Priorité : dossier de l'app → dossier Téléchargements de l'OS.
  String get initialSaveFolder => settings.effectiveDownloadFolder;

  /// Ouvre l'application de gestion de fichiers si [openFileManagerAfterDownload]
  /// est activé et qu'un exécutable est configuré. [savedPath] est le chemin
  /// du fichier téléchargé (ignoré ici, l'app gère son propre dossier).
  Future<void> notifyFileManager(String savedPath) async {
    if (!settings.openFileManagerAfterDownload) return;
    if (!settings.hasFileManager) return;
    try {
      await Process.start(
        settings.fileManagerExe!,
        [], // Arguments vides : l'app ouvre son propre dossier par défaut
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // En dernier recours, on tente d'ouvrir le fichier avec l'app associée
      openFile(savedPath);
    }
  }
}
