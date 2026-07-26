import 'dart:io';

import 'package:flutter/material.dart';

import '../build_service.dart';
import '../models/dev_project.dart';

/// Dialogue plein écran : choix de la cible de build, puis console de logs
/// en direct pendant l'exécution de `flutter build` + export de la release.
class BuildConsoleDialog extends StatefulWidget {
  final DevProject project;
  final String releasesFolder;
  final String oldReleasesFolder;

  const BuildConsoleDialog({
    super.key,
    required this.project,
    required this.releasesFolder,
    required this.oldReleasesFolder,
  });

  @override
  State<BuildConsoleDialog> createState() => _BuildConsoleDialogState();
}

enum _Phase { chooseTarget, running, done }

class _BuildConsoleDialogState extends State<BuildConsoleDialog> {
  _Phase _phase = _Phase.chooseTarget;
  BuildTarget _target = BuildTarget.desktopOnly;
  final _lines = <String>[];
  final _scrollCtrl = ScrollController();
  BuildCancelToken? _cancelToken;
  BuildResult? _result;

  bool get _isMac => Platform.isMacOS;

  void _log(String line) {
    if (!mounted) return;
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _start() async {
    setState(() => _phase = _Phase.running);
    _cancelToken = BuildCancelToken();

    final service = BuildService(
      project: widget.project,
      releasesFolder: widget.releasesFolder,
      oldReleasesFolder: widget.oldReleasesFolder,
      onLog: _log,
    );

    final result = await service.run(_target, _cancelToken!);
    if (!mounted) return;
    setState(() {
      _result = result;
      _phase  = _Phase.done;
    });
  }

  void _cancel() {
    _cancelToken?.cancel();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 720,
        height: 560,
        child: Column(children: [
          _Header(project: widget.project, phase: _phase),
          const Divider(height: 1),
          Expanded(
            child: _phase == _Phase.chooseTarget
                ? _TargetChooser(
                    isMac: _isMac,
                    selected: _target,
                    onChanged: (t) => setState(() => _target = t),
                  )
                : _Console(lines: _lines, scrollCtrl: _scrollCtrl),
          ),
          const Divider(height: 1),
          _Footer(
            phase: _phase,
            result: _result,
            onStart: _start,
            onCancel: _cancel,
            onClose: () => Navigator.of(context).pop(_result),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final DevProject project;
  final _Phase phase;

  const _Header({required this.project, required this.phase});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    IconData icon;
    Color color;
    switch (phase) {
      case _Phase.chooseTarget: icon = Icons.build_outlined; color = cs.primary; break;
      case _Phase.running:      icon = Icons.autorenew;       color = cs.primary; break;
      case _Phase.done:         icon = Icons.check_circle_outline; color = Colors.green; break;
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Build & Release — ${project.name}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            Text(project.sourcePath,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _TargetChooser extends StatelessWidget {
  final bool isMac;
  final BuildTarget selected;
  final ValueChanged<BuildTarget> onChanged;

  const _TargetChooser({required this.isMac, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Choisissez la cible de build :', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _TargetTile(
          icon: isMac ? Icons.desktop_mac_outlined : Icons.desktop_windows_outlined,
          value: BuildTarget.desktopOnly, selected: selected, onTap: onChanged,
          isMac: isMac,
        ),
        _TargetTile(
          icon: Icons.android_outlined,
          value: BuildTarget.apkOnly, selected: selected, onTap: onChanged,
          isMac: isMac,
        ),
        _TargetTile(
          icon: Icons.all_inclusive,
          value: BuildTarget.all, selected: selected, onTap: onChanged,
          isMac: isMac,
        ),
      ]),
    );
  }
}

class _TargetTile extends StatelessWidget {
  final IconData icon;
  final BuildTarget value, selected;
  final ValueChanged<BuildTarget> onTap;
  final bool isMac;

  const _TargetTile({
    required this.icon, required this.value, required this.selected,
    required this.onTap, required this.isMac,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = value == selected;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isSelected ? cs.primaryContainer.withOpacity(0.35) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected ? BorderSide(color: cs.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onTap(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(icon, color: isSelected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(child: Text(value.label(isMac))),
            if (isSelected) Icon(Icons.check_circle, color: cs.primary, size: 20),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Console extends StatelessWidget {
  final List<String> lines;
  final ScrollController scrollCtrl;

  const _Console({required this.lines, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1E1E1E),
      child: SingleChildScrollView(
        controller: scrollCtrl,
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          lines.join('\n'),
          style: const TextStyle(
            fontFamily: 'Consolas', fontSize: 12.5,
            color: Color(0xFFCCCCCC), height: 1.4,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final _Phase phase;
  final BuildResult? result;
  final VoidCallback onStart, onCancel, onClose;

  const _Footer({
    required this.phase, required this.result,
    required this.onStart, required this.onCancel, required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case _Phase.chooseTarget:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: onClose, child: const Text('Annuler')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Lancer le build'),
            ),
          ]),
        );

      case _Phase.running:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            const Expanded(child: Text('Build en cours…')),
            OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Annuler'),
            ),
          ]),
        );

      case _Phase.done:
        final ok = result?.success == true;
        final deployed = result?.deployedPath;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline,
                color: ok ? Colors.green : Colors.red),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ok ? 'Release créée avec succès.' : (result?.error ?? 'Échec du build.'),
                    style: TextStyle(color: ok ? Colors.green[700] : Colors.red[700]),
                  ),
                  if (ok && deployed != null)
                    Text('Déployé : $deployed',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            FilledButton(onPressed: onClose, child: const Text('Fermer')),
          ]),
        );
    }
  }
}
