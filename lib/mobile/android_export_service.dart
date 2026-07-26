import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'android_app_control.dart';
import 'android_profile.dart';

/// Export/Import de profils Android.
///
/// PROBLÈME MÉMOIRE RÉSOLU : ZipDecoder().decodeBytes(bytes) chargeait la
/// totalité de l'archive en RAM avant toute lecture — fatal sur Android
/// pour un zip Windows réel (50-300 Mo), où la limite mémoire par app
/// est souvent 192-512 Mo. Remplacé par ZipDecoder.openInputStream() qui
/// parcourt le zip en STREAMING, entrée par entrée, sans jamais tout
/// charger d'un coup.
///
/// COMPATIBILITÉ DES CONTEXTES : les dossiers WebView2 (Windows) /
/// WKWebView (macOS) sont des formats Chromium BINAIRES incompatibles avec
/// le moteur WebView Android. Un import depuis le desktop ne copie donc
/// JAMAIS de données de profil — uniquement nom + URL de démarrage.
class AndroidExportService {
  /// Exporte [profile] vers l'archive [destZipPath].
  Future<void> exportProfile(AndroidProfile profile, String destZipPath) async {
    final dataDir = await AndroidAppControl.getDataDir();
    if (dataDir == null) {
      throw Exception('Impossible de récupérer le dossier de données.');
    }
    final profileDir = '$dataDir/app_webview_${profile.id}';

    // Utilise ZipFileEncoder (streaming vers disque) pour ne jamais avoir
    // tout l'archive en RAM en même temps.
    final encoder = ZipFileEncoder();
    encoder.create(destZipPath);

    final metadata = {
      'schemaVersion': 1,
      'app': 'PulseProjects',
      'platform': 'android',
      'exportedAt': DateTime.now().toIso8601String(),
      'profile': {
        'name': profile.name,
        'homeUrl': profile.homeUrl,
        'sourceCreatedAt': profile.createdAt.toIso8601String(),
      },
    };
    final metaBytes = utf8.encode(jsonEncode(metadata));
    encoder.addArchiveFile(ArchiveFile(
      'metadata.json', metaBytes.length, metaBytes,
    ));

    final dir = Directory(profileDir);
    if (await dir.exists()) {
      await _walkAndEncode(dir, profileDir, 'profile/', encoder);
    }

    encoder.close();
  }

  /// Importe [zipPath] en STREAMING — lit entrée par entrée sans charger
  /// tout le zip en mémoire, quelle que soit la taille de l'archive.
  ///
  /// Détecte automatiquement la provenance :
  ///   • Android natif    → contexte WebView copié (nom + URL + données)
  ///   • Desktop (simple) → nom + URL uniquement (jamais le contexte)
  ///   • Desktop (bundle) → nom + URL pour chaque profil du bundle
  Future<List<AndroidProfile>> importAny(String zipPath) async {
    // Passe 1 : lire UNIQUEMENT metadata.json ou manifest.json
    // On parcourt le zip une première fois en streaming pour trouver
    // ces petits fichiers JSON (~quelques Ko), sans jamais décompresser
    // les gros fichiers de données WebView.
    Map<String, dynamic>? metadata;
    Map<String, dynamic>? manifest;

    final inputStream1 = InputFileStream(zipPath);
    try {
      final archive1 = ZipDecoder().decodeBuffer(inputStream1);
      for (final file in archive1) {
        if (!file.isFile) continue;
        if (file.name == 'metadata.json') {
          metadata = jsonDecode(
            utf8.decode(file.content as List<int>),
          ) as Map<String, dynamic>;
        } else if (file.name == 'manifest.json') {
          manifest = jsonDecode(
            utf8.decode(file.content as List<int>),
          ) as Map<String, dynamic>;
        }
        // On ignore TOUS les autres fichiers à ce stade (données WebView,
        // assets...) — ils restent sur disque dans le zip, non décompressés
        if (metadata != null || manifest != null) break;
      }
    } finally {
      inputStream1.close();
    }

    // ── Archive groupée desktop : settings-only ─────────────────────────
    if (manifest != null) {
      return _importBundleSettingsOnly(manifest);
    }

    if (metadata == null) {
      throw Exception(
        'Archive invalide : metadata.json introuvable.\n'
        'Ce fichier n\'a peut-être pas été exporté par PulseProjects.',
      );
    }

    final isAndroidNative = metadata['platform'] == 'android';

    // ── Export desktop : nom + URL uniquement ────────────────────────────
    if (!isAndroidNative) {
      return [_profileFromDesktopMetadata(metadata)];
    }

    // ── Export Android natif : extraction complète en streaming ──────────
    // Passe 2 : maintenant qu'on sait que c'est un export Android, on
    // extrait les fichiers profile/ — toujours en streaming, fichier par
    // fichier, pour ne jamais tout charger en RAM.
    return [await _importAndroidNative(metadata, zipPath)];
  }

  // ── Import Android natif ─────────────────────────────────────────────────

  Future<AndroidProfile> _importAndroidNative(
    Map<String, dynamic> metadata,
    String zipPath,
  ) async {
    final dataDir = await AndroidAppControl.getDataDir();
    if (dataDir == null) {
      throw Exception('Impossible de récupérer le dossier de données.');
    }

    final newId = const Uuid().v4();
    final destDir = '$dataDir/app_webview_$newId';

    // Streaming : extraction fichier par fichier, jamais tout en mémoire
    final inputStream = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeBuffer(inputStream);
      for (final file in archive) {
        if (!file.isFile) continue;
        if (!file.name.startsWith('profile/')) continue;
        final rel = file.name.substring('profile/'.length);
        if (rel.isEmpty) continue;

        try {
          final outFile = File(p.join(destDir, rel));
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>, flush: true);
        } catch (_) {
          // Fichier inaccessible → ignoré, le reste continue
        }
      }
    } finally {
      inputStream.close();
    }

    final profMeta = Map<String, dynamic>.from(
      (metadata['profile'] as Map?) ?? const {},
    );
    return _buildProfile(newId, profMeta);
  }

  // ── Import desktop (paramètres uniquement) ────────────────────────────────

  AndroidProfile _profileFromDesktopMetadata(Map<String, dynamic> metadata) {
    final projMeta = Map<String, dynamic>.from(
      (metadata['project'] as Map?) ?? const {},
    );
    return _buildProfile(const Uuid().v4(), projMeta);
  }

  List<AndroidProfile> _importBundleSettingsOnly(Map<String, dynamic> manifest) {
    final projects = (manifest['projects'] as List?) ?? const [];
    return projects.map((raw) {
      final meta = Map<String, dynamic>.from(raw as Map);
      return _buildProfile(const Uuid().v4(), meta);
    }).toList();
  }

  AndroidProfile _buildProfile(String id, Map<String, dynamic> meta) {
    final name = (meta['name'] as String?)?.trim();
    return AndroidProfile(
      id: id,
      name: (name != null && name.isNotEmpty) ? name : 'Profil importé',
      homeUrl: meta['homeUrl'] as String? ?? 'https://www.google.com',
      createdAt: DateTime.now(),
    );
  }

  // ── Export : parcours résilient dossier par dossier ───────────────────────

  Future<void> _walkAndEncode(
    Directory dir,
    String sourceDir,
    String entryPrefix,
    ZipFileEncoder encoder,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    for (final entity in entities) {
      if (entity is Directory) {
        await _walkAndEncode(entity, sourceDir, entryPrefix, encoder);
        continue;
      }
      if (entity is! File) continue;

      final rel = p.relative(entity.path, from: sourceDir).replaceAll('\\', '/');
      try {
        final bytes = await entity.readAsBytes();
        encoder.addArchiveFile(ArchiveFile(
          '$entryPrefix$rel', bytes.length, bytes,
        ));
      } catch (_) {
        // Fichier verrouillé/inaccessible → ignoré silencieusement
      }
    }
  }
}
