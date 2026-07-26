import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// FFI — Windows (kernel32 / user32). Symboles chargés paresseusement :
// jamais initialisés sur macOS car toujours gardés par Platform.isWindows.
// ─────────────────────────────────────────────────────────────────────────────

typedef _OpenProcessN = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessD = int    Function(int,   int,   int);
typedef _CloseHandleN = Int32 Function(IntPtr);
typedef _CloseHandleD = int   Function(int);
typedef _GetCurPidN   = Uint32 Function();
typedef _GetCurPidD   = int    Function();
typedef _FindWndExN   = IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWndExD   = int    Function(int,    int,    Pointer<Utf16>, Pointer<Utf16>);
typedef _GetWndPidN   = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetWndPidD   = int    Function(int,    Pointer<Uint32>);
typedef _SetFgWndN    = Int32 Function(IntPtr);
typedef _SetFgWndD    = int   Function(int);
typedef _ShowWndN     = Int32 Function(IntPtr, Int32);
typedef _ShowWndD     = int   Function(int,   int);

// ─────────────────────────────────────────────────────────────────────────────
// FFI — macOS / POSIX (libSystem.B.dylib)
// ─────────────────────────────────────────────────────────────────────────────

typedef _GetpidN = Int32 Function();
typedef _GetpidD = int   Function();
typedef _KillN   = Int32 Function(Int32, Int32);
typedef _KillD   = int   Function(int,   int);

// ─────────────────────────────────────────────────────────────────────────────
// ProcessTracker — cross-platform (Windows + macOS)
// ─────────────────────────────────────────────────────────────────────────────

class ProcessTracker {
  ProcessTracker._();

  // ── Chargement paresseux Windows ─────────────────────────────────────────

  static DynamicLibrary? __k32, __u32;
  static DynamicLibrary get _k32 => __k32 ??= DynamicLibrary.open('kernel32.dll');
  static DynamicLibrary get _u32 => __u32 ??= DynamicLibrary.open('user32.dll');

  static _OpenProcessD? __openProcess;
  static _OpenProcessD get _openProcess =>
      __openProcess ??= _k32.lookupFunction<_OpenProcessN, _OpenProcessD>('OpenProcess');

  static _CloseHandleD? __closeHandle;
  static _CloseHandleD get _closeHandle =>
      __closeHandle ??= _k32.lookupFunction<_CloseHandleN, _CloseHandleD>('CloseHandle');

  static _GetCurPidD? __getCurPid;
  static _GetCurPidD get _getCurPid =>
      __getCurPid ??= _k32.lookupFunction<_GetCurPidN, _GetCurPidD>('GetCurrentProcessId');

  static _FindWndExD? __findWndEx;
  static _FindWndExD get _findWndEx =>
      __findWndEx ??= _u32.lookupFunction<_FindWndExN, _FindWndExD>('FindWindowExW');

  static _GetWndPidD? __getWndPid;
  static _GetWndPidD get _getWndPid =>
      __getWndPid ??= _u32.lookupFunction<_GetWndPidN, _GetWndPidD>('GetWindowThreadProcessId');

  static _SetFgWndD? __setFgWnd;
  static _SetFgWndD get _setFgWnd =>
      __setFgWnd ??= _u32.lookupFunction<_SetFgWndN, _SetFgWndD>('SetForegroundWindow');

  static _ShowWndD? __showWnd;
  static _ShowWndD get _showWnd =>
      __showWnd ??= _u32.lookupFunction<_ShowWndN, _ShowWndD>('ShowWindow');

  // ── Chargement paresseux macOS ────────────────────────────────────────────

  static DynamicLibrary? __libSystem;
  static DynamicLibrary get _libSystem =>
      __libSystem ??= DynamicLibrary.open('/usr/lib/libSystem.B.dylib');

  static _GetpidD? __getpid;
  static _GetpidD get _getpid =>
      __getpid ??= _libSystem.lookupFunction<_GetpidN, _GetpidD>('getpid');

  static _KillD? __kill;
  static _KillD get _kill =>
      __kill ??= _libSystem.lookupFunction<_KillN, _KillD>('kill');

  // ── API publique ──────────────────────────────────────────────────────────

  static int getCurrentPid() {
    if (Platform.isWindows) return _getCurPid();
    if (Platform.isMacOS)   return _getpid();
    throw UnsupportedError('Unsupported platform');
  }

  /// Vérifie si le processus [pid] est toujours en vie.
  static bool isPidAlive(int pid) {
    if (Platform.isWindows) {
      const kSynchronize = 0x00100000;
      final h = _openProcess(kSynchronize, 0, pid);
      if (h == 0) return false;
      _closeHandle(h);
      return true;
    }
    if (Platform.isMacOS) {
      // kill(pid, 0) : retourne 0 si le processus existe, -1 sinon
      return _kill(pid, 0) == 0;
    }
    throw UnsupportedError('Unsupported platform');
  }

  /// Cherche la fenêtre du processus [targetPid] et la met au premier plan.
  static bool bringToFront(int targetPid) {
    if (Platform.isWindows) {
      final cls    = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final pidPtr = calloc<Uint32>();
      try {
        int hwnd = 0;
        while (true) {
          hwnd = _findWndEx(0, hwnd, cls, nullptr.cast());
          if (hwnd == 0) break;
          _getWndPid(hwnd, pidPtr);
          if (pidPtr.value == targetPid) {
            _showWnd(hwnd, 9 /*SW_RESTORE*/);
            _setFgWnd(hwnd);
            return true;
          }
        }
        return false;
      } finally {
        calloc.free(cls);
        calloc.free(pidPtr);
      }
    }
    if (Platform.isMacOS) {
      // AppleScript : aucun plugin natif nécessaire
      Process.run('osascript', [
        '-e',
        'tell application "System Events" to set frontmost of '
        '(first process whose unix id is $targetPid) to true',
      ]);
      return true; // optimiste : on ne bloque pas
    }
    throw UnsupportedError('Unsupported platform');
  }

  // ── Fichiers .lock (cross-platform) ───────────────────────────────────────

  static Directory _runningDir() {
    final appData = Platform.isWindows
        ? (Platform.environment['APPDATA'] ??
            p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Roaming'))
        : (Platform.environment['HOME'] ?? '.');
    final base = Platform.isWindows ? 'PulseProjects' : '.pulseprojects';
    return Directory(p.join(appData, base, 'running'));
  }

  static File _lockFile(String projectId) =>
      File(p.join(_runningDir().path, '$projectId.lock'));

  static Future<void> writePid(String projectId) async {
    final dir = _runningDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await _lockFile(projectId).writeAsString(getCurrentPid().toString());
  }

  static Future<void> deletePid(String projectId) async {
    try { await _lockFile(projectId).delete(); } catch (_) {}
  }

  static Future<Map<String, int>> runningProjects() async {
    final dir = _runningDir();
    if (!dir.existsSync()) return {};
    final result = <String, int>{};
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.lock')) continue;
      try {
        final pid = int.parse(await f.readAsString());
        if (isPidAlive(pid)) {
          result[p.basenameWithoutExtension(f.path)] = pid;
        } else {
          await f.delete();
        }
      } catch (_) {}
    }
    return result;
  }

  static Future<void> killAll(Map<String, int> running) async {
    for (final pid in running.values) {
      try { Process.killPid(pid); } catch (_) {}
    }
    for (final id in running.keys) {
      await deletePid(id);
    }
  }
}
