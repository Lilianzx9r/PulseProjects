import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'data/dir_utils.dart';
import 'models/dev_project.dart';

/// Cibles de build proposées à l'utilisateur.
///   • [desktopOnly] : `flutter build windows` (Windows) ou `flutter build
///     macos` (macOS) — la cible desktop native de la plateforme courante.
///   • [apkOnly]     : `flutter build apk` — fonctionne sur Windows ET
///     macOS tant que le toolchain Android est installé.
///   • [all]         : les deux.
enum BuildTarget { desktopOnly, apkOnly, all }

extension BuildTargetLabel on BuildTarget {
  String label(bool isMac) {
    final desktop = isMac ? 'macOS' : 'Windows';
    switch (this) {
      case BuildTarget.desktopOnly: return desktop;
      case BuildTarget.apkOnly:     return 'APK (Android)';
      case BuildTarget.all:         return 'Tout ($desktop + APK)';
    }
  }
}

/// Jeton d'annulation partagé entre l'UI et [BuildService]. Permet de tuer
/// le process `flutter build` en cours si l'utilisateur clique "Annuler".
class BuildCancelToken {
  Process? _current;
  bool cancelled = false;

  void _attach(Process process) => _current = process;

  void cancel() {
    cancelled = true;
    try { _current?.kill(); } catch (_) {}
  }
}

/// Résultat d'une opération de build + export (+ déploiement éventuel).
class BuildResult {
  final bool success;
  final String? zipPath;
  final String? apkPath;

  /// Chemin où le build desktop a été déployé, si [DevProject.deployAfterBuild]
  /// était activé et que le déploiement a réussi.
  final String? deployedPath;

  final String? error;

  const BuildResult({
    required this.success,
    this.zipPath,
    this.apkPath,
    this.deployedPath,
    this.error,
  });
}

/// Dossiers exclus de la copie propre des sources — reproduit exactement
/// la liste `/XD build .dart_tool .idea .vscode ephemeral .gradle` du
/// script .bat d'origine.
const _kExcludedSourceDirs = {
  'build', '.dart_tool', '.idea', '.vscode', 'ephemeral', '.gradle',
};

/// Orchestre le pipeline complet build → export → historique → déploiement
/// pour un [DevProject], équivalent du script `DevTool.bat` original,
/// enrichi d'une étape de publication de l'exécutable desktop :
///
///   1. `flutter build <cible> --release` (streaming des logs)
///   2. Rotation des anciennes archives (Releases → ReleasesOld)
///   3. Assemblage d'un dossier temporaire (build desktop + APK + sources)
///   4. Compression en `<name>_<datetime>.zip` dans le dossier Releases
///   5. Si [DevProject.deployAfterBuild] : copie du build desktop vers
///      [DevProject.deployFolder] (à plat ou horodaté selon
///      [DevProject.deployVersioned])
class BuildService {
  final DevProject project;
  final String releasesFolder;
  final String oldReleasesFolder;
  final void Function(String line) onLog;

  BuildService({
    required this.project,
    required this.releasesFolder,
    required this.oldReleasesFolder,
    required this.onLog,
  });

  /// Chemin du dossier de sortie du build desktop pour la plateforme
  /// courante (avant tout déplacement/copie).
  String get _desktopBuildOutputDir => Platform.isMacOS
      ? p.join(project.sourcePath, 'build', 'macos', 'Build', 'Products', 'Release')
      : p.join(project.sourcePath, 'build', 'windows', 'x64', 'runner', 'Release');

  String get _desktopCmd => Platform.isMacOS ? 'macos' : 'windows';

  Future<BuildResult> run(BuildTarget target, BuildCancelToken cancelToken) async {
    try {
      // ── 1. Build(s) ──────────────────────────────────────────────────────
      if (target == BuildTarget.desktopOnly || target == BuildTarget.all) {
        onLog('');
        onLog('===== BUILD ${_desktopCmd.toUpperCase()} =====');
        final ok = await _runFlutterBuild(_desktopCmd, cancelToken);
        if (!ok) return _failure(cancelToken, 'Le build $_desktopCmd a échoué.');
      }

      if (target == BuildTarget.apkOnly || target == BuildTarget.all) {
        onLog('');
        onLog('===== BUILD APK =====');
        final ok = await _runFlutterBuild('apk', cancelToken);
        if (!ok) return _failure(cancelToken, 'Le build APK a échoué.');
      }

      // ── 2. Export ────────────────────────────────────────────────────────
      onLog('');
      onLog('===== EXPORT RELEASE =====');
      final exportResult = await _export(target);

      // ── 3. Déploiement (si activé et build desktop effectué) ──────────────
      String? deployedPath;
      if (project.deployAfterBuild &&
          (target == BuildTarget.desktopOnly || target == BuildTarget.all)) {
        onLog('');
        onLog('===== DÉPLOIEMENT =====');
        final deployResult = await _deploy();
        if (deployResult != null) {
          deployedPath = deployResult;
        }
      }

      return BuildResult(
        success: true,
        zipPath: exportResult.zipPath,
        apkPath: exportResult.apkPath,
        deployedPath: deployedPath,
      );
    } catch (e) {
      return BuildResult(success: false, error: e.toString());
    }
  }

  /// Redéploie le DERNIER build desktop existant sur disque, sans relancer
  /// `flutter build`. Utile pour republier rapidement sans reconstruire.
  Future<BuildResult> redeployOnly() async {
    if (!project.hasDeployFolder) {
      return const BuildResult(
        success: false,
        error: 'Aucun dossier de déploiement configuré pour ce projet.',
      );
    }
    if (!await Directory(_desktopBuildOutputDir).exists()) {
      return BuildResult(
        success: false,
        error: 'Aucun build $_desktopCmd trouvé sur le disque. '
            'Lancez un build avant de déployer.',
      );
    }

    onLog('Redéploiement du dernier build $_desktopCmd…');
    final dest = await _deploy();
    if (dest == null) {
      return const BuildResult(success: false, error: 'Le déploiement a échoué.');
    }
    return BuildResult(success: true, deployedPath: dest);
  }

  BuildResult _failure(BuildCancelToken token, String message) {
    if (token.cancelled) {
      onLog('');
      onLog('[Annulé par l\'utilisateur]');
      return const BuildResult(success: false, error: 'Annulé par l\'utilisateur.');
    }
    onLog('');
    onLog('[ÉCHEC] $message');
    return BuildResult(success: false, error: message);
  }

  /// Lance `flutter build <target> --release` dans le dossier source du
  /// projet, en streamant stdout/stderr ligne par ligne vers [onLog].
  /// Retourne `true` si le process se termine avec un code de sortie 0.
  Future<bool> _runFlutterBuild(String target, BuildCancelToken cancelToken) async {
    final process = await Process.start(
      'flutter',
      ['build', target, '--release'],
      workingDirectory: project.sourcePath,
      runInShell: true,
    );
    cancelToken._attach(process);

    process.stdout.transform(utf8.decoder).transform(const LineSplitter())
        .listen(onLog, onError: (_) {});
    process.stderr.transform(utf8.decoder).transform(const LineSplitter())
        .listen(onLog, onError: (_) {});

    final code = await process.exitCode;
    if (cancelToken.cancelled) return false;
    return code == 0;
  }

  /// Copie le build desktop vers [DevProject.deployFolder]. Retourne le
  /// chemin de destination effectif, ou null en cas d'échec / configuration
  /// absente.
  Future<String?> _deploy() async {
    if (!project.hasDeployFolder) {
      onLog('(aucun dossier de déploiement configuré — ignoré)');
      return null;
    }
    if (!await Directory(_desktopBuildOutputDir).exists()) {
      onLog('(build $_desktopCmd introuvable — déploiement ignoré)');
      return null;
    }

    final dest = project.deployVersioned
        ? p.join(project.deployFolder!, '${project.name}_${_datetimeStamp()}')
        : project.deployFolder!;

    try {
      await Directory(dest).create(recursive: true);
      onLog('Copie vers $dest…');
      await copyDirectoryAll(sourceDir: _desktopBuildOutputDir, destDir: dest);
      onLog('Déployé : $dest');
      return dest;
    } catch (e) {
      onLog('[ÉCHEC déploiement] $e');
      return null;
    }
  }

  /// Reproduit la section EXPORT du script .bat : rotation des anciennes
  /// archives, assemblage du dossier temporaire, copie des builds et des
  /// sources, écriture de info.txt, compression finale.
  Future<({String? zipPath, String? apkPath})> _export(BuildTarget target) async {
    await Directory(releasesFolder).create(recursive: true);
    await Directory(oldReleasesFolder).create(recursive: true);

    // Rotation : les archives existantes portant le nom de ce projet sont
    // déplacées vers ReleasesOld AVANT de générer la nouvelle.
    onLog('Archivage des anciennes releases…');
    await moveMatchingFiles(
      sourceDir: releasesFolder, destDir: oldReleasesFolder,
      namePrefix: project.name, extension: '.zip',
    );
    await moveMatchingFiles(
      sourceDir: releasesFolder, destDir: oldReleasesFolder,
      namePrefix: project.name, extension: '.apk',
    );

    final datetime = _datetimeStamp();

    final tmpRoot = p.join(
      Directory.systemTemp.path, '${project.name}_release',
    );
    await deleteIfExists(tmpRoot);

    final tmpProject      = p.join(tmpRoot, project.name);
    final tmpDesktop      = p.join(tmpProject, _desktopCmd);
    final tmpAndroid      = p.join(tmpProject, 'android');
    final tmpSourcesClean = p.join(tmpProject, project.name);

    await Directory(tmpDesktop).create(recursive: true);
    await Directory(tmpAndroid).create(recursive: true);

    // ── Copie du build desktop (si la cible a été construite) ─────────────
    if (target == BuildTarget.desktopOnly || target == BuildTarget.all) {
      if (await Directory(_desktopBuildOutputDir).exists()) {
        onLog('Copie du build $_desktopCmd…');
        await copyDirectoryAll(sourceDir: _desktopBuildOutputDir, destDir: tmpDesktop);
      } else {
        onLog('(build $_desktopCmd introuvable — ignoré)');
      }
    }

    // ── Copie de l'APK (si la cible a été construite) ──────────────────────
    String? apkFinalPath;
    if (target == BuildTarget.apkOnly || target == BuildTarget.all) {
      final apkSrc = p.join(
        project.sourcePath, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk',
      );
      if (await File(apkSrc).exists()) {
        onLog('Copie de l\'APK…');
        await File(apkSrc).copy(p.join(tmpAndroid, 'app-release.apk'));

        apkFinalPath = p.join(releasesFolder, '${project.name}_$datetime.apk');
        await File(apkSrc).copy(apkFinalPath);
      } else {
        onLog('(APK introuvable — ignoré)');
      }
    }

    // ── Copie propre des sources (exclusions comme le .bat) ────────────────
    onLog('Copie des sources (hors build/.dart_tool/.idea/.vscode/ephemeral/.gradle)…');
    await copyDirectoryExcluding(
      sourceDir: project.sourcePath,
      destDir: tmpSourcesClean,
      excludeDirNames: _kExcludedSourceDirs,
    );

    // ── info.txt ─────────────────────────────────────────────────────────
    final infoFile = File(p.join(tmpProject, 'info.txt'));
    await infoFile.writeAsString(
      'Project: ${project.name}\nDate: $datetime\n',
    );

    // ── Compression finale ───────────────────────────────────────────────
    final zipPath = p.join(releasesFolder, '${project.name}_$datetime.zip');
    onLog('Compression de l\'archive…');
    await zipDirectoryContents(sourceDir: tmpProject, destZipPath: zipPath);

    await deleteIfExists(tmpRoot);

    onLog('');
    onLog('===== RELEASE OK =====');
    onLog(zipPath);

    return (zipPath: zipPath, apkPath: apkFinalPath);
  }

  static String _2(int n) => n.toString().padLeft(2, '0');

  static String _datetimeStamp() {
    final now = DateTime.now();
    return '${now.year}${_2(now.month)}${_2(now.day)}_'
        '${_2(now.hour)}${_2(now.minute)}${_2(now.second)}';
  }
}
