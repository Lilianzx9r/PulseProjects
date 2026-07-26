import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// Comportement lors d'un téléchargement
// ─────────────────────────────────────────────────────────────────────────────

enum DownloadBehavior {
  /// Comportement par défaut de PulseProjects :
  /// dialogue "Enregistrer sous" natif, dossier Téléchargements de l'OS.
  disabled,

  /// Téléchargement automatique et silencieux dans [AppSettings.downloadFolder],
  /// puis ouverture optionnelle de [AppSettings.fileManagerExe] si configurée.
  automatic,

  /// Pré-remplit le dialogue "Enregistrer sous" sur [AppSettings.downloadFolder]
  /// (et [AppSettings.fileManagerExe] si configurée), mais laisse l'utilisateur
  /// confirmer / modifier l'emplacement.
  confirm,
}

extension DownloadBehaviorExt on DownloadBehavior {
  String get label {
    switch (this) {
      case DownloadBehavior.disabled:  return 'Comportement par défaut (dossier Téléchargements OS)';
      case DownloadBehavior.automatic: return 'Automatique — enregistrement direct sans dialogue';
      case DownloadBehavior.confirm:   return 'Sur confirmation — dialogue pré-positionné sur le dossier';
    }
  }

  String get storageName => name;

  static DownloadBehavior fromStorage(String? s) =>
      DownloadBehavior.values.firstWhere(
        (v) => v.name == s,
        orElse: () => DownloadBehavior.disabled,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèle des paramètres globaux
// ─────────────────────────────────────────────────────────────────────────────

class AppSettings {
  /// Chemin vers l'exécutable de l'application de gestion de fichiers.
  /// Optionnel : si renseigné, PulseProjects pourra l'ouvrir après un
  /// téléchargement (ou sur demande via un bouton).
  final String? fileManagerExe;

  /// Dossier de téléchargement utilisé par l'application externe.
  /// Si vide, PulseProjects utilise le dossier Téléchargements de l'OS.
  final String? downloadFolder;

  /// Comportement à adopter lors d'un téléchargement dans le navigateur.
  final DownloadBehavior downloadBehavior;

  /// Si true et [fileManagerExe] est renseigné, ouvre l'application de
  /// gestion de fichiers après chaque téléchargement terminé avec succès.
  final bool openFileManagerAfterDownload;

  /// Chemin vers l'exécutable d'un explorateur de fichiers personnalisé
  /// (ex: un gestionnaire de fichiers tiers). Utilisé partout où
  /// PulseProjects a besoin d'ouvrir un dossier sur le disque (dossier de
  /// données d'un profil, dossier source/releases d'un projet Flutter…).
  /// Si vide, l'explorateur natif de l'OS est utilisé (Explorateur Windows
  /// / Finder macOS).
  final String? explorerExe;

  const AppSettings({
    this.fileManagerExe,
    this.downloadFolder,
    this.downloadBehavior = DownloadBehavior.disabled,
    this.openFileManagerAfterDownload = false,
    this.explorerExe,
  });

  static const AppSettings defaults = AppSettings();

  bool get hasFileManager =>
      fileManagerExe != null && fileManagerExe!.isNotEmpty;

  bool get hasDownloadFolder =>
      downloadFolder != null && downloadFolder!.isNotEmpty;

  bool get hasExplorer =>
      explorerExe != null && explorerExe!.isNotEmpty;

  /// Dossier effectif pour les téléchargements :
  /// [downloadFolder] si configuré, sinon dossier Téléchargements de l'OS.
  String get effectiveDownloadFolder {
    if (hasDownloadFolder) return downloadFolder!;
    return _osDownloadsFolder();
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

  AppSettings copyWith({
    String? fileManagerExe,
    String? downloadFolder,
    DownloadBehavior? downloadBehavior,
    bool? openFileManagerAfterDownload,
    String? explorerExe,
    bool clearFileManagerExe = false,
    bool clearDownloadFolder  = false,
    bool clearExplorerExe     = false,
  }) {
    return AppSettings(
      fileManagerExe: clearFileManagerExe
          ? null
          : (fileManagerExe ?? this.fileManagerExe),
      downloadFolder: clearDownloadFolder
          ? null
          : (downloadFolder ?? this.downloadFolder),
      downloadBehavior: downloadBehavior ?? this.downloadBehavior,
      openFileManagerAfterDownload:
          openFileManagerAfterDownload ?? this.openFileManagerAfterDownload,
      explorerExe: clearExplorerExe
          ? null
          : (explorerExe ?? this.explorerExe),
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      fileManagerExe: json['fileManagerExe'] as String?,
      downloadFolder: json['downloadFolder'] as String?,
      downloadBehavior: DownloadBehaviorExt.fromStorage(
          json['downloadBehavior'] as String?),
      openFileManagerAfterDownload:
          json['openFileManagerAfterDownload'] as bool? ?? false,
      explorerExe: json['explorerExe'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (fileManagerExe != null) 'fileManagerExe': fileManagerExe,
        if (downloadFolder != null)  'downloadFolder': downloadFolder,
        'downloadBehavior': downloadBehavior.storageName,
        'openFileManagerAfterDownload': openFileManagerAfterDownload,
        if (explorerExe != null) 'explorerExe': explorerExe,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Store — lecture/écriture sur disque
// ─────────────────────────────────────────────────────────────────────────────

class AppSettingsStore {
  AppSettingsStore._();

  static Future<File> _file() async {
    final Directory base;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
      base = Directory(p.join(appData, 'PulseProjects'));
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      base = Directory(p.join(home, 'Library', 'Application Support', 'PulseProjects'));
    } else {
      throw UnsupportedError('Unsupported platform');
    }
    if (!await base.exists()) await base.create(recursive: true);
    return File(p.join(base.path, 'settings.json'));
  }

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return AppSettings.defaults;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return AppSettings.defaults;
      return AppSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings.defaults;
    }
  }

  static Future<void> save(AppSettings settings) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {}
  }
}
