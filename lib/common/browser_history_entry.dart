/// Une entrée de l'historique de navigation : une page visitée, avec son
/// titre (s'il a pu être lu) et l'horodatage de la visite.
class BrowserHistoryEntry {
  BrowserHistoryEntry({
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  final String url;
  final String title;
  final DateTime visitedAt;

  factory BrowserHistoryEntry.fromJson(Map<String, dynamic> json) {
    return BrowserHistoryEntry(
      url:       json['url'] as String? ?? '',
      title:     json['title'] as String? ?? '',
      visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'url':       url,
        'title':     title,
        'visitedAt': visitedAt.toIso8601String(),
      };
}
