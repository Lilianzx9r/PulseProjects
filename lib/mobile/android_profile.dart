/// Profil de navigateur Android, plus simple que [Project] (desktop) :
/// pas de terminal, pas de script, pas de dossier de travail — juste un
/// nom et une URL de démarrage.
///
/// Contrainte Android : un seul profil peut être ACTIF à la fois dans le
/// process courant (voir `android_profile_repository.dart` et
/// `PulseApplication.kt`), car `WebView.setDataDirectorySuffix()` ne peut
/// être appelée qu'une seule fois par process, avant toute création de
/// WebView. Changer de profil nécessite donc un redémarrage complet de
/// l'application.
class AndroidProfile {
  final String id;
  String name;
  String homeUrl;
  final DateTime createdAt;
  DateTime? lastUsedAt;

  AndroidProfile({
    required this.id,
    required this.name,
    required this.homeUrl,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory AndroidProfile.fromJson(Map<String, dynamic> json) {
    return AndroidProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Profil',
      homeUrl: json['homeUrl'] as String? ?? 'https://www.google.com',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastUsedAt: json['lastUsedAt'] != null
          ? DateTime.tryParse(json['lastUsedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'homeUrl': homeUrl,
        'createdAt': createdAt.toIso8601String(),
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
      };
}
