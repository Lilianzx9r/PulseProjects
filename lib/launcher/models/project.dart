/// Représente un "profil" PulseProjects : une configuration de navigateur
/// intégré (URL de démarrage, dossier de travail) associée à un dossier
/// de données isolé et persistant.
class Project {
  /// Identifiant unique et stable du profil.
  final String id;

  /// Nom affiché du profil (libre, choisi par l'utilisateur).
  String name;

  /// URL chargée automatiquement à l'ouverture du profil.
  String homeUrl;

  /// Dossier de travail associé au profil (optionnel).
  /// Utilisé comme répertoire courant des terminaux (CMD / PowerShell)
  /// ouverts depuis la fenêtre navigateur de ce profil.
  String? workFolder;

  /// Contenu du script personnalisé associé à ce profil (optionnel).
  /// Éditable depuis la fenêtre navigateur (bouton Script, à côté des
  /// boutons terminal). Si jamais renseigné, l'éditeur propose un contenu
  /// par défaut (voir kDefaultProjectScript) sans le persister tant que
  /// l'utilisateur ne l'a pas explicitement enregistré.
  String? scriptContent;

  /// Dossier d'exécution du script personnalisé (répertoire de travail
  /// utilisé au lancement). Si vide, retombe sur [workFolder].
  String? scriptFolder;

  /// Ligne de commande utilisée pour lancer le script dans le TERMINAL
  /// INTÉGRÉ (à pipes, celui affiché dans le panneau de la fenêtre
  /// navigateur — distinct du terminal externe qui lance directement le
  /// fichier). Le jeton `{script}` est remplacé par le chemin complet du
  /// fichier script au moment de l'exécution. Si vide, une valeur par
  /// défaut adaptée à la plateforme est utilisée (voir ScriptPanel).
  String? scriptCommandLine;

  /// Date de création du profil.
  final DateTime createdAt;

  /// Date du dernier lancement (informative, affichée dans la liste).
  DateTime? lastLaunchedAt;

  Project({
    required this.id,
    required this.name,
    required this.homeUrl,
    required this.createdAt,
    this.workFolder,
    this.scriptContent,
    this.scriptFolder,
    this.scriptCommandLine,
    this.lastLaunchedAt,
  });

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Sans nom',
      homeUrl: json['homeUrl'] as String? ?? 'https://www.google.com',
      workFolder: json['workFolder'] as String?,
      scriptContent: json['scriptContent'] as String?,
      scriptFolder: json['scriptFolder'] as String?,
      scriptCommandLine: json['scriptCommandLine'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
              DateTime.now(),
      lastLaunchedAt: json['lastLaunchedAt'] != null
          ? DateTime.tryParse(json['lastLaunchedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'homeUrl': homeUrl,
      if (workFolder != null) 'workFolder': workFolder,
      if (scriptContent != null) 'scriptContent': scriptContent,
      if (scriptFolder != null) 'scriptFolder': scriptFolder,
      if (scriptCommandLine != null) 'scriptCommandLine': scriptCommandLine,
      'createdAt': createdAt.toIso8601String(),
      'lastLaunchedAt': lastLaunchedAt?.toIso8601String(),
    };
  }
}
