/// Représente un projet Flutter enregistré dans l'outil "Build & Release"
/// de PulseProjects — équivalent du `DevTool ProjectName` du script .bat
/// original, mais piloté depuis l'interface graphique.
class DevProject {
  /// Identifiant unique et stable.
  final String id;

  /// Nom affiché (utilisé aussi comme préfixe des archives : `<name>_<date>.zip`).
  String name;

  /// Chemin du dossier source du projet Flutter (contient pubspec.yaml).
  String sourcePath;

  /// Dossier où déposer les archives de release. Si vide/null, calculé
  /// automatiquement comme `<parent(sourcePath)>/Releases` (comme le script
  /// .bat d'origine, où Releases est un dossier frère du projet).
  String? releasesFolderOverride;

  /// Dossier de DÉPLOIEMENT de l'exécutable desktop (Windows/macOS) après
  /// un build réussi — distinct du dossier Releases (qui contient les
  /// archives zip historisées). Typiquement un dossier "prod" partagé,
  /// un raccourci bureau, un dossier synchronisé, etc.
  String? deployFolder;

  /// Si true, copie automatiquement le build desktop dans [deployFolder]
  /// dès que le build se termine avec succès (sans action manuelle).
  bool deployAfterBuild;

  /// Si true, chaque déploiement va dans un sous-dossier horodaté
  /// `<deployFolder>/<name>_<datetime>/`. Si false (par défaut), le
  /// contenu de [deployFolder] est simplement écrasé par le nouveau build
  /// (déploiement "à plat", pratique pour un raccourci fixe).
  bool deployVersioned;

  final DateTime createdAt;
  DateTime? lastBuiltAt;
  DateTime? lastDeployedAt;

  DevProject({
    required this.id,
    required this.name,
    required this.sourcePath,
    this.releasesFolderOverride,
    this.deployFolder,
    this.deployAfterBuild = false,
    this.deployVersioned = false,
    required this.createdAt,
    this.lastBuiltAt,
    this.lastDeployedAt,
  });

  bool get hasDeployFolder => deployFolder != null && deployFolder!.isNotEmpty;

  factory DevProject.fromJson(Map<String, dynamic> json) {
    return DevProject(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Projet',
      sourcePath: json['sourcePath'] as String? ?? '',
      releasesFolderOverride: json['releasesFolderOverride'] as String?,
      deployFolder: json['deployFolder'] as String?,
      deployAfterBuild: json['deployAfterBuild'] as bool? ?? false,
      deployVersioned: json['deployVersioned'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastBuiltAt: json['lastBuiltAt'] != null
          ? DateTime.tryParse(json['lastBuiltAt'] as String)
          : null,
      lastDeployedAt: json['lastDeployedAt'] != null
          ? DateTime.tryParse(json['lastDeployedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourcePath': sourcePath,
        if (releasesFolderOverride != null)
          'releasesFolderOverride': releasesFolderOverride,
        if (deployFolder != null) 'deployFolder': deployFolder,
        'deployAfterBuild': deployAfterBuild,
        'deployVersioned': deployVersioned,
        'createdAt': createdAt.toIso8601String(),
        'lastBuiltAt': lastBuiltAt?.toIso8601String(),
        'lastDeployedAt': lastDeployedAt?.toIso8601String(),
      };
}
