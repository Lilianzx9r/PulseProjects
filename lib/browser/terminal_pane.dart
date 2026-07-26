import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Terminal intégré utilisant dart:io Process.start() avec pipes stdin/stdout.
///
/// Remplace flutter_pty (ConPTY) qui déclenchait les EDR type SentinelOne.
/// CreatePseudoConsole est l'API utilisée par certains malwares pour
/// l'injection de processus ; les EDR la bloquent par précaution.
///
/// dart:io Process.start() utilise CreateProcess standard avec pipes —
/// aucune API suspecte.
///
/// Fonctionnalités :
///   • Session persistante cmd.exe ou powershell.exe
///   • Sortie stdout+stderr en temps réel (auto-scroll)
///   • Saisie interactive avec envoi au stdin
///   • Historique des commandes (↑/↓), persistant via [initialHistory] /
///     [onHistoryChanged] — l'appelant porte la responsabilité de
///     conserver/recharger l'historique entre deux instances de ce widget
///     (le widget lui-même est recréé à chaque redémarrage ou changement
///     CMD↔PowerShell, donc son propre état interne ne suffit pas seul).
///   • Ctrl+C pour tuer le processus courant
///   • Tab envoyé au stdin (complétion si supportée par le shell)
class TerminalPane extends StatefulWidget {
  final bool    isCmd;
  final String? workDir;

  /// Historique initial (le plus ancien en premier) à charger au démarrage
  /// de ce terminal — typiquement rechargé depuis le parent (lui-même
  /// persisté sur disque), pour survivre aux redémarrages du panneau.
  final List<String> initialHistory;

  /// Appelé à chaque commande envoyée avec l'historique complet à jour,
  /// pour que l'appelant puisse le conserver (état parent + disque).
  final ValueChanged<List<String>>? onHistoryChanged;

  const TerminalPane({
    super.key,
    required this.isCmd,
    this.workDir,
    this.initialHistory = const [],
    this.onHistoryChanged,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final _scrollCtrl = ScrollController();
  final _inputCtrl  = TextEditingController();
  late  FocusNode   _inputFocus;

  Process? _process;
  IOSink?  _stdin;

  String _raw     = '';
  String _display = '';
  bool   _exited  = false;

  final _history = <String>[];
  int   _histIdx = -1;

  static const _maxBuf = 120000;

  // Regex ANSI/VT100 complète
  static final _ansiRx = RegExp(
    r'\x1B[@-Z\\-_]'
    r'|[\x80-\x9F]'
    r'|\x1B\[[0-?]*[ -/]*[@-~]'
    r'|\x1B\][^\x07\x1B]*[\x07]'
    r'|\x1B\][^\x1B]*\x1B\\'
    r'|\x1B[PX^_].*?\x1B\\'
    ,
    multiLine: true,
    dotAll:    true,
  );

  @override
  void initState() {
    super.initState();
    _history.addAll(widget.initialHistory);
    _inputFocus = FocusNode();
    _inputFocus.onKeyEvent = _handleKey;
    _start();
  }

  // ── Démarrage du processus ────────────────────────────────────────────────

  Future<void> _start() async {
    final String exe;
    final List<String> args;

    if (Platform.isWindows) {
      exe  = widget.isCmd ? 'cmd.exe' : 'powershell.exe';
      // cmd /K : exécute la commande de démarrage puis lit stdin en continu
      // chcp 65001 : passe en UTF-8 pour l'encodage des sorties
      // powershell -NoLogo -NoExit : session persistante sans bannière
      args = widget.isCmd
          ? ['/K', 'chcp 65001 >nul 2>&1']
          : ['-NoLogo', '-NoExit'];
    } else if (Platform.isMacOS) {
      // macOS : zsh (shell par défaut depuis Catalina), pas de notion
      // CMD/PowerShell — widget.isCmd est ignoré sur cette plateforme.
      exe  = '/bin/zsh';
      args = ['-i']; // mode interactif : charge .zshrc, alias, prompt
    } else {
      throw UnsupportedError('Unsupported platform');
    }

    // Validation du répertoire de travail
    final wd = _resolveWorkDir();

    try {
      _process = await Process.start(
        exe,
        args,
        workingDirectory:    wd,
        runInShell:          false,
        // Pas de mode spécial : utilise CreateProcess/posix_spawn standard
        // avec pipes (aucune API flaggée par les EDR type SentinelOne)
      );

      _stdin = _process!.stdin;

      // Lecture stdout
      _process!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_onData, onError: (_) {});

      // Lecture stderr
      _process!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_onData, onError: (_) {});

      // Fin du processus
      _process!.exitCode.then((code) {
        _onData('\r\n[Processus terminé (code $code) — cliquez ↺ pour redémarrer]\r\n');
        if (mounted) setState(() => _exited = true);
      });

      if (wd != null) {
        // Afficher le répertoire initial pour repère visuel
        _onData('[Dossier de travail : $wd]\r\n');
      }
    } catch (e) {
      _onData('[Erreur démarrage $exe : $e]\r\n');
      if (mounted) setState(() => _exited = true);
    }
  }

  String? _resolveWorkDir() {
    final d = widget.workDir;
    if (d == null || d.isEmpty) return null;
    try {
      if (Directory(d).existsSync()) return d;
    } catch (_) {}
    return null;
  }

  // ── Réception données stdout/stderr ──────────────────────────────────────

  void _onData(String data) {
    _raw += data;

    if (_raw.length > _maxBuf) {
      _raw = _raw.substring(_raw.length - _maxBuf);
      final nl = _raw.indexOf('\n');
      if (nl >= 0) _raw = _raw.substring(nl + 1);
    }

    final clean = _raw
        .replaceAll(_ansiRx, '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\x00', '');

    if (!mounted) return;
    setState(() => _display = clean);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  // ── Envoi commandes / contrôles ───────────────────────────────────────────

  void _sendLine(String text) {
    if (_process == null || _exited) return;

    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      _history.remove(trimmed);
      _history.add(trimmed);
      if (_history.length > 200) _history.removeAt(0);
      widget.onHistoryChanged?.call(List<String>.from(_history));
    }
    _histIdx = -1;

    try {
      _stdin?.write('$text\n');
      _stdin?.flush();
    } catch (_) {}

    _inputCtrl.clear();
    _inputFocus.requestFocus();
  }

  void _sendCtrlC() {
    if (_process == null) return;
    try {
      // Envoyer \x03 au stdin (certains shells l'interceptent comme Ctrl+C)
      _stdin?.write('\x03');
      _stdin?.flush();
    } catch (_) {}
    // Fallback : tuer le processus si le signal n'est pas géré
    // On ne kill pas immédiatement pour laisser le processus se terminer proprement
    _inputFocus.requestFocus();
  }

  void _killProcess() {
    try { _process?.kill(); } catch (_) {}
  }

  // ── Historique clavier ────────────────────────────────────────────────────

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed) {
      _sendCtrlC();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      try {
        _stdin?.write('\t');
        _stdin?.flush();
      } catch (_) {}
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_history.isEmpty) return KeyEventResult.handled;
      _histIdx = (_histIdx + 1).clamp(0, _history.length - 1);
      _inputCtrl.text = _history[_history.length - 1 - _histIdx];
      _inputCtrl.selection =
          TextSelection.collapsed(offset: _inputCtrl.text.length);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_histIdx <= 0) {
        _histIdx = -1;
        _inputCtrl.clear();
      } else {
        _histIdx--;
        _inputCtrl.text = _history[_history.length - 1 - _histIdx];
        _inputCtrl.selection =
            TextSelection.collapsed(offset: _inputCtrl.text.length);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _killProcess();
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  static const _bg    = Color(0xFF1E1E1E);
  static const _bg2   = Color(0xFF252526);
  static const _fg    = Color(0xFFCCCCCC);
  static const _blue  = Color(0xFF4FC1FF);
  static const _style = TextStyle(
    fontFamily: 'Consolas',
    fontSize:   13.5,
    color:      _fg,
    height:     1.45,
  );

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: Column(children: [
        // ── Zone de sortie ──────────────────────────────────────────────────
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap:    () => _inputFocus.requestFocus(),
            child: SingleChildScrollView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: SizedBox(
                width: double.infinity,
                child: SelectableText(
                  _display,
                  style: _style,
                ),
              ),
            ),
          ),
        ),

        // ── Ligne de saisie ─────────────────────────────────────────────────
        Container(
          color: _bg2,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(children: [
            Text(
              _exited ? '✕ ' : '❯ ',
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize:   14,
                color:      _exited ? Colors.red[400] : _blue,
              ),
            ),
            Expanded(
              child: TextField(
                controller:  _inputCtrl,
                focusNode:   _inputFocus,
                autofocus:   true,
                enabled:     !_exited,
                style:       _style,
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  isDense:        true,
                  border:         InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 2),
                  hintText:       'Saisir une commande…',
                  hintStyle:      TextStyle(color: Color(0xFF555555)),
                ),
                onSubmitted: _exited ? null : _sendLine,
              ),
            ),
            // Ctrl+C / tuer
            Tooltip(
              message: 'Interrompre (Ctrl+C)',
              child: InkWell(
                onTap:        _sendCtrlC,
                onLongPress:  _killProcess,
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child:   Icon(Icons.stop_circle_outlined,
                      size: 18, color: Color(0xFF888888)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
