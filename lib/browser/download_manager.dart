import 'dart:io';

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Statuts possibles d'un téléchargement
// ─────────────────────────────────────────────────────────────────────────────

enum DownloadStatus { downloading, done, error, cancelled }

// ─────────────────────────────────────────────────────────────────────────────
// Modèle d'un téléchargement
// ─────────────────────────────────────────────────────────────────────────────

class DownloadItem {
  final String id;

  /// Chemin absolu de destination sur le disque.
  final String savePath;

  /// Nom de fichier déduit du chemin (pour l'affichage).
  String get fileName => savePath.split(r'\').last.split('/').last;

  int bytesReceived;
  int totalBytes; // -1 = inconnu
  DownloadStatus status;
  String? errorMessage;

  DownloadItem({
    required this.id,
    required this.savePath,
    this.bytesReceived = 0,
    this.totalBytes = -1,
    this.status = DownloadStatus.downloading,
  });

  double? get progress =>
      totalBytes > 0 ? (bytesReceived / totalBytes).clamp(0.0, 1.0) : null;

  String get progressText {
    String fmt(int b) {
      if (b < 1024) return '$b o';
      if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} Ko';
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} Mo';
    }
    if (totalBytes > 0) return '${fmt(bytesReceived)} / ${fmt(totalBytes)}';
    if (bytesReceived > 0) return fmt(bytesReceived);
    return 'En cours…';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gestionnaire (ChangeNotifier → widgets réactifs via ListenableBuilder)
// ─────────────────────────────────────────────────────────────────────────────

class DownloadManager extends ChangeNotifier {
  final _items = <String, DownloadItem>{};

  List<DownloadItem> get items => _items.values.toList(growable: false)
    ..sort((a, b) => a.id.compareTo(b.id));

  bool get hasItems => _items.isNotEmpty;

  // ── Mutations ────────────────────────────────────────────────────────────

  /// Crée une entrée pour un nouveau téléchargement (état : downloading).
  void start(String id, String savePath, {int totalBytes = -1}) {
    _items[id] = DownloadItem(
      id: id,
      savePath: savePath,
      totalBytes: totalBytes,
      status: DownloadStatus.downloading,
    );
    notifyListeners();
  }

  /// Met à jour la progression.
  void progress(String id, int received, {int? total}) {
    final item = _items[id];
    if (item == null) return;
    item.bytesReceived = received;
    if (total != null) item.totalBytes = total;
    notifyListeners();
  }

  /// Marque un téléchargement comme terminé avec succès.
  void complete(String id) {
    final item = _items[id];
    if (item == null) return;
    item.status = DownloadStatus.done;
    // bytesReceived = totalBytes pour la barre pleine
    if (item.totalBytes > 0) item.bytesReceived = item.totalBytes;
    notifyListeners();
  }

  /// Marque un téléchargement comme en erreur.
  void fail(String id, String message) {
    final item = _items[id];
    if (item == null) return;
    item.status = DownloadStatus.error;
    item.errorMessage = message;
    notifyListeners();
  }

  /// Supprime une entrée (terminée ou en erreur).
  void remove(String id) {
    _items.remove(id);
    notifyListeners();
  }

  /// Supprime toutes les entrées terminées/en erreur.
  void removeCompleted() {
    _items.removeWhere((_, v) => v.status != DownloadStatus.downloading);
    notifyListeners();
  }

  // ── Utilitaires ──────────────────────────────────────────────────────────

  /// Dossier Téléchargements de l'utilisateur Windows courant.
  static String defaultDownloadsFolder() {
    final profile = Platform.environment['USERPROFILE'] ??
        '${Platform.environment['HOMEDRIVE'] ?? 'C:'}${Platform.environment['HOMEPATH'] ?? r'\Users\Default'}';
    return '$profile\\Downloads';
  }
}
