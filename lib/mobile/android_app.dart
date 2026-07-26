import 'package:flutter/material.dart';

import 'android_browser_screen.dart';
import 'android_profile.dart';
import 'android_profile_picker_screen.dart';
import 'android_profile_repository.dart';

/// Application Android de PulseProjects : contrairement aux versions
/// Windows/macOS (multi-process, multi-fenêtre), Android ne permet qu'un
/// SEUL profil actif à la fois dans le process courant — voir
/// AndroidProfileRepository pour le détail de cette contrainte.
class AndroidApp extends StatelessWidget {
  const AndroidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseProjects',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const _AndroidRoot(),
    );
  }
}

class _AndroidRoot extends StatefulWidget {
  const _AndroidRoot();

  @override
  State<_AndroidRoot> createState() => _AndroidRootState();
}

class _AndroidRootState extends State<_AndroidRoot> {
  final _repo = AndroidProfileRepository();
  bool _loading = true;
  AndroidProfile? _current;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final currentId = await _repo.getCurrentProfileId();
    if (currentId != null) {
      final profiles = await _repo.load();
      final match = profiles.where((p) => p.id == currentId);
      if (match.isNotEmpty) {
        if (!mounted) return;
        setState(() { _current = match.first; _loading = false; });
        return;
      }
    }
    if (!mounted) return;
    setState(() { _current = null; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_current == null) {
      return AndroidProfilePickerScreen(repository: _repo);
    }
    return AndroidBrowserScreen(profile: _current!, repository: _repo);
  }
}
