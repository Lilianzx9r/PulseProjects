import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Windows FFI (chargement paresseux)
typedef _ShellExN = IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Int32);
typedef _ShellExD = int    Function(int,    Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int);

DynamicLibrary? __shell32;
DynamicLibrary get _shell32 => __shell32 ??= DynamicLibrary.open('shell32.dll');
_ShellExD? __shellEx;
_ShellExD get _shellExFn =>
    __shellEx ??= _shell32.lookupFunction<_ShellExN, _ShellExD>('ShellExecuteW');

bool _shellExecuteW(String verb, String file, [String params = '']) {
  final v = verb.toNativeUtf16();
  final f = file.toNativeUtf16();
  final p = params.isNotEmpty ? params.toNativeUtf16() : nullptr.cast<Utf16>();
  try {
    return _shellExFn(0, v, f, p, nullptr.cast<Utf16>(), 10 /*SW_SHOWDEFAULT*/) > 32;
  } finally {
    calloc.free(v);
    calloc.free(f);
    if (params.isNotEmpty) calloc.free(p);
  }
}

/// Ouvre [path] avec l'application associée.
bool openFile(String path) {
  if (Platform.isWindows) return _shellExecuteW('open', path);
  if (Platform.isMacOS)   { Process.run('open', [path]); return true; }
  throw UnsupportedError('Unsupported platform');
}

/// Ouvre l'explorateur / Finder sur le dossier contenant [filePath], en
/// tentant de le sélectionner dans la liste (comportement natif Windows/
/// macOS). Si [customExplorerExe] est fourni, l'explorateur personnalisé
/// est lancé sur le DOSSIER contenant [filePath] à la place (la plupart
/// des gestionnaires de fichiers tiers n'ont pas de syntaxe standard pour
/// "sélectionner un fichier précis", seulement "ouvrir un dossier").
bool revealInExplorer(String filePath, {String? customExplorerExe}) {
  if (customExplorerExe != null && customExplorerExe.isNotEmpty) {
    final folder = File(filePath).parent.path;
    return _launchCustomExplorer(customExplorerExe, folder);
  }
  if (Platform.isWindows) return _shellExecuteW('open', 'explorer.exe', '/select,"$filePath"');
  if (Platform.isMacOS)   { Process.run('open', ['-R', filePath]); return true; }
  throw UnsupportedError('Unsupported platform');
}

/// Ouvre le dossier [path] avec l'explorateur configuré globalement
/// ([customExplorerExe]), ou l'explorateur natif de l'OS si non configuré
/// (Explorateur Windows / Finder macOS).
///
/// Utilisé partout où PulseProjects doit ouvrir un dossier sur le disque :
/// dossier de données d'un profil, dossier source ou releases d'un projet
/// Flutter, etc. — pour que le paramètre global "Explorateur de fichiers"
/// s'applique uniformément.
bool openFolder(String path, {String? customExplorerExe}) {
  if (customExplorerExe != null && customExplorerExe.isNotEmpty) {
    return _launchCustomExplorer(customExplorerExe, path);
  }
  if (Platform.isWindows) { Process.start('explorer', [path]); return true; }
  if (Platform.isMacOS)   { Process.start('open', [path]);     return true; }
  throw UnsupportedError('Unsupported platform');
}

bool _launchCustomExplorer(String exe, String path) {
  try {
    Process.start(exe, [path], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  }
}
