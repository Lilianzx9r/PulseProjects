import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Nom de la variable d'environnement reconnue par le runtime
/// Microsoft Edge WebView2 pour choisir l'emplacement de son dossier
/// de profil (cookies, cache, stockage local, IndexedDB, etc.).
const _kWebView2UserDataFolderEnvVar = 'WEBVIEW2_USER_DATA_FOLDER';

typedef _SetEnvironmentVariableWNative = Int32 Function(
  Pointer<Utf16> lpName,
  Pointer<Utf16> lpValue,
);
typedef _SetEnvironmentVariableWDart = int Function(
  Pointer<Utf16> lpName,
  Pointer<Utf16> lpValue,
);

/// Force le contrôleur WebView2 de **ce process** à utiliser [path] comme
/// dossier de données (profil).
///
/// Cela DOIT être appelé avant toute initialisation d'un
/// [WebviewController], car le runtime WebView2 lit cette variable
/// d'environnement au moment de la création de son "Environment".
///
/// Comme PulseProjects lance chaque profil dans son propre process
/// Windows indépendant, fixer cette variable au sein d'un process donné
/// n'affecte ni les autres processes déjà démarrés, ni les futures
/// instances : chacune définit sa propre valeur au démarrage.
void setWebView2UserDataFolder(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setEnvironmentVariableW = kernel32.lookupFunction<
      _SetEnvironmentVariableWNative,
      _SetEnvironmentVariableWDart>('SetEnvironmentVariableW');

  final namePtr = _kWebView2UserDataFolderEnvVar.toNativeUtf16();
  final valuePtr = path.toNativeUtf16();
  try {
    setEnvironmentVariableW(namePtr, valuePtr);
  } finally {
    calloc.free(namePtr);
    calloc.free(valuePtr);
  }
}
