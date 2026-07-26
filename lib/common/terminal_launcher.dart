import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ── Types FFI Windows (chargement paresseux) ─────────────────────────────────

typedef _ShellExN = IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Int32);
typedef _ShellExD = int    Function(int,    Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int);

DynamicLibrary? __s32;
DynamicLibrary get _s32 => __s32 ??= DynamicLibrary.open('shell32.dll');
_ShellExD? __fn;
_ShellExD get _fn => __fn ??= _s32.lookupFunction<_ShellExN, _ShellExD>('ShellExecuteW');

bool _winShell(String verb, String file, String params, String? dir) {
  final v  = verb.toNativeUtf16();
  final f  = file.toNativeUtf16();
  final p  = params.isNotEmpty ? params.toNativeUtf16() : nullptr.cast<Utf16>();
  final d  = (dir != null && dir.isNotEmpty) ? dir.toNativeUtf16() : nullptr.cast<Utf16>();
  try {
    return _fn(0, v, f, p, d, 10) > 32;
  } finally {
    calloc.free(v); calloc.free(f);
    if (params.isNotEmpty) calloc.free(p);
    if (dir != null && dir.isNotEmpty) calloc.free(d);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

enum TerminalKind { cmd, powershell }

/// Lance un terminal (CMD ou PowerShell sur Windows ; Terminal.app sur macOS)
/// dans le répertoire [workFolder]. [asAdmin] déclenche UAC sur Windows ;
/// sur macOS, utilise 'sudo' dans le terminal (concept différent de l'UAC).
bool launchTerminal({
  required TerminalKind kind,
  required bool asAdmin,
  String? workFolder,
}) {
  if (Platform.isWindows) {
    final verb   = asAdmin ? 'runas' : 'open';
    final exe    = kind == TerminalKind.cmd ? 'cmd.exe' : 'pwsh.exe';
    final params = kind == TerminalKind.cmd ? '' : '-NoExit';
    return _winShell(verb, exe, params, workFolder);
  }

  if (Platform.isMacOS) {
    return _macLaunchTerminal(kind, asAdmin, workFolder);
  }

  throw UnsupportedError('Unsupported platform');
}

/// Variante PowerShell : essaie pwsh (PS 7+) puis powershell (PS 5.x)
/// sur Windows ; pwsh/zsh via Terminal.app sur macOS.
bool launchPowerShell({required bool asAdmin, String? workFolder}) {
  if (Platform.isWindows) {
    final verb = asAdmin ? 'runas' : 'open';
    if (_winShell(verb, 'pwsh.exe', '-NoExit', workFolder)) return true;
    return _winShell(verb, 'powershell.exe', '-NoExit', workFolder);
  }
  if (Platform.isMacOS) {
    return _macLaunchTerminal(TerminalKind.powershell, asAdmin, workFolder);
  }
  throw UnsupportedError('Unsupported platform');
}

// ── macOS : ouvre Terminal.app sur le dossier du projet ──────────────────────
//
// La commande AppleScript ouvre une fenêtre Terminal.app (application par
// défaut de macOS) avec le bon répertoire courant. Le shell utilisé est
// celui configuré dans les préférences Terminal (zsh par défaut depuis
// macOS Catalina). Pour 'sudo', on préfixe la commande initiale.

bool _macLaunchTerminal(TerminalKind kind, bool asAdmin, String? workFolder) {
  final String shellCmd;
  if (kind == TerminalKind.powershell) {
    shellCmd = asAdmin
        ? 'sudo pwsh 2>/dev/null || sudo zsh'
        : 'pwsh 2>/dev/null || exec zsh';
  } else {
    shellCmd = asAdmin ? 'sudo -s' : '';
  }

  final dir    = (workFolder != null && workFolder.isNotEmpty) ? workFolder : r'~';
  final cdCmd  = 'cd "$dir"';
  final runCmd = shellCmd.isNotEmpty ? '$cdCmd && $shellCmd' : cdCmd;

  final script = '''
tell application "Terminal"
  activate
  do script "$runCmd"
end tell
''';

  final result = Process.runSync('osascript', ['-e', script]);
  return result.exitCode == 0;
}

// ── Exécution d'un fichier script dans une fenêtre terminal visible ─────────
//
// Utilisé par le bouton "Script" des fenêtres navigateur : le script est
// écrit sur disque (voir ScriptStore) puis lancé ici, dans le [workFolder]
// choisi par l'utilisateur, avec la fenêtre laissée ouverte pour voir la
// sortie/les erreurs (équivalent du `pause` final du script .bat d'origine
// sur Windows).

/// Lance le fichier [scriptPath] (.bat sur Windows, .sh sur macOS) dans
/// une fenêtre de terminal visible, avec [workFolder] comme répertoire
/// de travail (cwd) au démarrage.
bool runScriptFile({required String scriptPath, String? workFolder}) {
  if (Platform.isWindows) {
    // /K garde la fenêtre CMD ouverte après exécution, pour voir la sortie
    // même si le script ne se termine pas par un `pause`.
    // Le double jeu de guillemets ("" ... "") est un contournement connu
    // du parsing particulier de `cmd.exe /K` avec un chemin contenant des
    // espaces — sans cela, cmd.exe peut retirer les guillemets englobants
    // et casser le chemin. Ce n'est pas une erreur de frappe.
    return _winShell('open', 'cmd.exe', '/K ""$scriptPath""', workFolder);
  }

  if (Platform.isMacOS) {
    final dir = (workFolder != null && workFolder.isNotEmpty) ? workFolder : r'~';
    // La fenêtre Terminal reste ouverte après exécution (comportement par
    // défaut de `do script`), pour voir la sortie/les erreurs.
    final script = '''
tell application "Terminal"
  activate
  do script "cd \\"$dir\\" && bash \\"$scriptPath\\""
end tell
''';
    final result = Process.runSync('osascript', ['-e', script]);
    return result.exitCode == 0;
  }

  throw UnsupportedError('Unsupported platform');
}
