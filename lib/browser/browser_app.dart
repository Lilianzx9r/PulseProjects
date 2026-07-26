import 'package:flutter/material.dart';

import '../launcher/models/project.dart';
import 'browser_view.dart';

class BrowserApp extends StatelessWidget {
  final Project project;
  final String  dataDir;   // dossier WebView2 isolé pour ce profil

  const BrowserApp({super.key, required this.project, required this.dataDir});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: project.name,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: BrowserView(project: project, dataDir: dataDir),
    );
  }
}
