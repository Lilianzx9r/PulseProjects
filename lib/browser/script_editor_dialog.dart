import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../common/default_script.dart';

/// Éditeur de script personnalisé associé à un profil, sous forme de
/// PANNEAU INLINE (pas de Dialog/overlay).
///
/// Sur Windows, `webview_win_floating` affiche WebView2 dans une fenêtre
/// Win32 native FLOTTANTE au-dessus du compositor Flutter : tout overlay
/// Flutter (Dialog, PopupMenu, Tooltip étendu...) qui déborderait sous la
/// barre d'outils se retrouve rendu DERRIÈRE la WebView, invisible. C'est
/// le même problème déjà rencontré avec le menu terminal et la barre
/// "terminal externe" — la solution est la même : un panneau qui fait
/// réellement partie de la mise en page (poussant la WebView), jamais un
/// overlay qui flotte par-dessus.
///
/// Ce panneau est utilisé identiquement sur Windows et macOS (bien que
/// macOS n'ait pas ce problème de Z-order avec WKWebView, qui est un vrai
/// NSView embarqué) pour garder un comportement cohérent entre les deux
/// plateformes.
class ScriptPanel extends StatefulWidget {
  final String projectName;
  final String? initialContent;
  final String? initialFolder;

  /// Enregistre [content]/[folder] sur disque. L'appelant (BrowserView)
  /// est responsable de la persistance réelle via ProjectRepository, car
  /// la fenêtre navigateur tourne dans un process séparé du lanceur.
  final Future<void> Function(String content, String? folder) onSave;

  /// Enregistre puis exécute le script dans une fenêtre terminal visible.
  final Future<void> Function(String content, String? folder) onExecute;

  final VoidCallback onClose;

  const ScriptPanel({
    super.key,
    required this.projectName,
    this.initialContent,
    this.initialFolder,
    required this.onSave,
    required this.onExecute,
    required this.onClose,
  });

  @override
  State<ScriptPanel> createState() => _ScriptPanelState();
}

class _ScriptPanelState extends State<ScriptPanel> {
  late final TextEditingController _contentCtrl;
  late final TextEditingController _folderCtrl;
  bool _usingDefault = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final hasCustom = widget.initialContent != null && widget.initialContent!.isNotEmpty;
    _usingDefault = !hasCustom;
    _contentCtrl = TextEditingController(
      text: hasCustom ? widget.initialContent! : kDefaultProjectScript,
    );
    _folderCtrl = TextEditingController(text: widget.initialFolder ?? '');
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _folderCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: _folderCtrl.text.isNotEmpty ? _folderCtrl.text : null,
        confirmButtonText: 'Sélectionner',
      );
      if (path != null) setState(() => _folderCtrl.text = path);
    } catch (_) {}
  }

  String? get _folder => _folderCtrl.text.trim().isEmpty ? null : _folderCtrl.text.trim();

  Future<void> _save() async {
    setState(() => _busy = true);
    await widget.onSave(_contentCtrl.text, _folder);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _execute() async {
    setState(() => _busy = true);
    await widget.onExecute(_contentCtrl.text, _folder);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 420,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: cs.outlineVariant),
          bottom: BorderSide(color: cs.outlineVariant),
        ),
      ),
      child: Column(children: [
        // ── En-tête ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(children: [
            Icon(Icons.integration_instructions_outlined, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Script — ${widget.projectName}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            if (_usingDefault)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('Contenu par défaut (DevTool.bat)',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Fermer',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
            ),
          ]),
        ),

        // ── Dossier d'exécution ───────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormField(
                controller: _folderCtrl,
                decoration: InputDecoration(
                  labelText: 'Dossier d\'exécution',
                  hintText: Platform.isWindows
                      ? r'C:\MonProjet\...'
                      : '/Users/.../MonProjet',
                  prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Parcourir…',
              icon: const Icon(Icons.folder_open),
              visualDensity: VisualDensity.compact,
              onPressed: _pickFolder,
            ),
          ]),
        ),

        // ── Éditeur ────────────────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ColoredBox(
              color: const Color(0xFF1E1E1E),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: TextField(
                  controller: _contentCtrl,
                  maxLines: null,
                  expands: true,
                  onChanged: (_) {
                    if (_usingDefault) setState(() => _usingDefault = false);
                  },
                  style: const TextStyle(
                    fontFamily: 'Consolas', fontSize: 12,
                    color: Color(0xFFCCCCCC), height: 1.4,
                  ),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(10),
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── Actions ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Enregistrer'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _execute,
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Enregistrer et exécuter'),
            ),
          ]),
        ),
      ]),
    );
  }
}
