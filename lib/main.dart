import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'browser/browser_app.dart';
import 'browser/browser_view_macos.dart';
import 'launcher/data/project_repository.dart';
import 'launcher/launcher_app.dart';
import 'mobile/android_app.dart';

/// PulseProjects — comportement différent selon la plateforme :
///
///  • Windows / macOS : deux modes selon les arguments de ligne de
///    commande — lanceur (aucun argument) / navigateur isolé
///    (`--project=<id>`), multi-fenêtre, multi-process.
///
///  • Android : un seul profil actif à la fois dans le process courant
///    (voir lib/mobile/ — contrainte de l'API WebView.setDataDirectorySuffix()).
///
/// Isolation des sessions :
///   • Windows : WindowsWebViewControllerCreationParams (userDataFolder +
///     profileName) dans browser_view.dart (webview_win_floating / WebView2)
///   • macOS   : WKWebsiteDataStore.dataStore(forIdentifier:) dans le
///     plugin Swift custom (macos/Runner/PulseWebViewPlugin.swift),
///     piloté par browser_view_macos.dart — disponible depuis macOS 14+
///     (Sonoma), garanti présent sur macOS Tahoe 26.
///   • Android : WebView.setDataDirectorySuffix(profileId), appliquée par
///     PulseApplication.kt AVANT le démarrage du moteur Flutter — un seul
///     profil actif par process, changer de profil redémarre l'app
///     (voir lib/mobile/android_app_control.dart).
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Android : aucune des API window_manager (desktop-only) ci-dessous
  // n'est disponible sur cette plateforme — on bifurque avant tout appel.
  if (Platform.isAndroid) {
    runApp(const AndroidApp());
    return;
  }

  await windowManager.ensureInitialized();

  final repository = ProjectRepository();
  final projectId  = _extractProjectId(args);

  // ── Mode lanceur ──────────────────────────────────────────────────────────
  if (projectId == null) {
    await _setupWindow(title: 'PulseProjects', size: const Size(960, 640));
    runApp(LauncherApp(repository: repository));
    return;
  }

  // ── Mode navigateur isolé ─────────────────────────────────────────────────
  final project = await repository.getProject(projectId);
  if (project == null) {
    await _setupWindow(title: 'PulseProjects', size: const Size(480, 240));
    runApp(_NotFoundApp(id: projectId));
    return;
  }

  await _setupWindow(title: project.name, size: const Size(1280, 800));

  if (Platform.isMacOS) {
    // macOS : l'isolation passe par WKWebsiteDataStore(forIdentifier:),
    // identifié directement par project.id (UUID) côté Swift — pas besoin
    // de dossier de données séparé comme sur Windows.
    runApp(MaterialApp(
      title: project.name,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: BrowserViewMacOS(project: project),
    ));
    return;
  }

  // Windows : dossier de données dédié à ce profil, passé à
  // WindowsWebViewControllerCreationParams.
  final dataDir = await repository.profileDataDir(project.id);
  runApp(BrowserApp(project: project, dataDir: dataDir));
}

String? _extractProjectId(List<String> args) {
  for (final a in args) {
    if (a.startsWith('--project=')) {
      final id = a.substring('--project='.length).trim();
      return id.isEmpty ? null : id;
    }
  }
  return null;
}

Future<void> _setupWindow({required String title, required Size size}) async {
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size:        size,
      minimumSize: const Size(480, 320),
      center:      true,
      title:       title,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

class _NotFoundApp extends StatelessWidget {
  final String id;
  const _NotFoundApp({required this.id});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseProjects',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Text(
            'Profil introuvable (id : $id).\n\n'
            'Il a peut-être été supprimé depuis PulseProjects.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
