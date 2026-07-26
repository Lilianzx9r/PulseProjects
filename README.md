# PulseProjects

Lanceur de profils de navigateur web isolés et persistants, avec terminal
intégré, pour **Windows** et **macOS** (Tahoe 26+).

## Architecture cross-platform

PulseProjects fonctionne en deux modes :
- **Lanceur** (sans argument) : liste les profils, CRUD, export/import
- **Navigateur isolé** (`--project=<id>`) : fenêtre dédiée à un profil

| Composant | Windows | macOS |
|---|---|---|
| Moteur web | WebView2 (`webview_win_floating`) | WKWebView (plugin Swift custom) |
| Isolation de session | `WindowsWebViewControllerCreationParams` (userDataFolder + profileName) | `WKWebsiteDataStore.dataStore(forIdentifier:)` (macOS 14+) |
| Données stockées | `%APPDATA%\PulseProjects\profiles\<id>` | `~/Library/WebKit/WebsiteDataStores/<id>` |
| Sélecteur de fichiers | `file_selector` (cross-platform) | `file_selector` (cross-platform) |
| Terminal intégré | `cmd.exe` / `powershell.exe` | `/bin/zsh` |
| Terminal externe | console Windows (`ShellExecuteW`) | Terminal.app (AppleScript) |
| Ouvrir un fichier/dossier | `explorer.exe` | `open` |
| Suivi de process / bring-to-front | `kernel32`/`user32` FFI | `getpid`/`kill` FFI + `osascript` |
| Export/Import | `archive` (zip cross-platform) | `archive` (zip cross-platform) |

Le code Dart partagé (modèles, repository, export, historique terminal,
widgets de liste) est commun aux deux plateformes, avec des branches
`Platform.isWindows` / `Platform.isMacOS` aux points de divergence.
Les deux UI navigateur sont des widgets séparés :
`lib/browser/browser_view.dart` (Windows) et
`lib/browser/browser_view_macos.dart` (macOS) — car les contraintes
de rendu diffèrent fondamentalement entre les deux plateformes (voir
ci-dessous).

## Particularité macOS : pas de problème de Z-order

Sur Windows, `webview_win_floating` affiche WebView2 dans une **fenêtre
Win32 native flottante** au-dessus du compositor Flutter, ce qui masque
tout popup/dialog Flutter qui déborderait sous la barre d'outils — d'où
les barres "inline" pour le terminal et le menu dans la version Windows.

Sur macOS, `WKWebView` est un **vrai NSView embarqué** dans la hiérarchie
Flutter : les `PopupMenuButton`, `Tooltip`, `Dialog` s'affichent
normalement par-dessus. L'UI macOS (`browser_view_macos.dart`) utilise
donc des menus popup classiques, plus simples que l'équivalent Windows.

## Mise en route — macOS

1. Générer les fichiers de plateforme :
   ```bash
   flutter create . --platforms=macos
   ```
   (conservez vos fichiers existants si une confirmation d'écrasement
   apparaît — seul le dossier `macos/` généré par défaut doit fusionner
   avec `macos/Runner/AppDelegate.swift` et
   `macos/Runner/PulseWebViewPlugin.swift` déjà fournis dans ce zip)

2. Dans `macos/Runner/Info.plist`, vérifiez/ajoutez le droit
   App Sandbox approprié si vous distribuez via le Mac App Store
   (hors sujet pour un usage local/dev).

3. Récupérer les dépendances :
   ```bash
   flutter pub get
   ```

4. Lancer :
   ```bash
   flutter run -d macos
   ```

### Pourquoi `AppDelegate.swift` doit enregistrer le plugin manuellement

`PulseWebViewPlugin` n'est pas un package pub.dev classique (c'est un
fichier Swift local au projet), donc il n'apparaît pas dans
`GeneratedPluginRegistrant.swift`. Son enregistrement est fait
explicitement dans `applicationDidFinishLaunching` de `AppDelegate.swift`.

## Mise en route — Windows

Inchangé par rapport aux versions précédentes :
```powershell
flutter create . --platforms=windows
flutter pub get
flutter run -d windows
```

## Limites connues du port macOS

- **Terminal externe "PowerShell"** : sur macOS, ouvre `pwsh` s'il est
  installé (Homebrew), sinon retombe sur `zsh` — PowerShell n'est pas
  préinstallé sur macOS.
- **Mode admin terminal** : sur Windows, déclenche un vrai prompt UAC
  (`runas`). Sur macOS, lance `sudo` dans le terminal ouvert — l'utilisateur
  doit saisir son mot de passe dans le terminal lui-même, ce n'est pas une
  élévation de privilège au sens Windows.
- **Réinitialisation des données** : sur macOS, supprime directement le
  dossier `~/Library/WebKit/WebsiteDataStores/<id>` — le profil ne doit
  pas être ouvert au moment de l'opération (WebKit le recrée proprement
  au prochain lancement).

## Mise en route — Android

Architecture différente des versions desktop : Android n'autorise **qu'un
seul profil actif à la fois** dans le process en cours (contrainte de
l'API `WebView.setDataDirectorySuffix()`, qui ne peut être appelée
qu'une seule fois par process, avant toute création de WebView). Changer
de profil redémarre donc complètement l'application — voir
`lib/mobile/` pour le détail de cette architecture.

### 1 — Générer les fichiers de plateforme

```bash
flutter create . --platforms=android --org com.pulseprojects
```

Cette commande génère le dossier `android/` avec le nom de package
`com.pulseprojects.pulse_projects` (org + nom du projet), qui doit
correspondre exactement au `package` déclaré dans les deux fichiers
Kotlin déjà fournis dans ce zip
(`android/app/src/main/kotlin/com/pulseprojects/pulse_projects/`).

> Si Flutter demande de confirmer l'écrasement de fichiers déjà présents
> (`pubspec.yaml`, `lib/`), répondez **non** — conservez ceux fournis
> dans ce zip. Seul le nouveau dossier `android/` généré doit être
> fusionné : les deux fichiers `PulseApplication.kt` et `MainActivity.kt`
> déjà présents dans ce zip remplacent ceux générés par défaut au même
> emplacement.

### 2 — Déclarer `PulseApplication` dans le manifeste

Ouvrez `android/app/src/main/AndroidManifest.xml` généré et modifiez la
balise `<application>` pour y ajouter `android:name=".PulseApplication"` :

```xml
<application
    android:name=".PulseApplication"
    android:label="PulseProjects"
    ...>
```

Vérifiez aussi la présence de la permission Internet (généralement déjà
ajoutée par défaut par `flutter create`) :

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

### 3 — Récupérer les dépendances et lancer

```bash
flutter pub get
flutter run -d <id-appareil-ou-emulateur>
```

### Fonctionnement

1. Au premier lancement, aucun profil n'est actif : l'écran de sélection
   s'affiche directement (liste vide).
2. **Nouveau profil** → nom + URL de démarrage.
3. Toucher un profil dans la liste → redémarre l'application pour
   appliquer son suffixe `WebView.setDataDirectorySuffix()`, puis ouvre
   le navigateur plein écran pour ce profil.
4. Bouton **⇄ Changer de profil** dans le navigateur → retour à l'écran
   de sélection. Choisir un profil différent redémarre à nouveau
   l'application ; revenir au même profil ou faire marche arrière sans
   rien choisir ne redémarre rien.
5. **Export/Import** : bouton ⬆ dans l'AppBar pour importer un `.zip` ;
   menu ⋮ sur chaque profil pour l'exporter.
   - **Import d'un `.zip` Android** → contexte complet restauré (cookies,
     stockage local…), voir ci-dessous.
   - **Import d'un `.zip` Windows/macOS** (simple ou groupé) → seuls le
     nom et l'URL de démarrage sont repris, le profil créé démarre avec
     un contexte de navigation entièrement vierge. Le contexte
     WebView2/WKWebView n'est **jamais** copié : ce sont des formats
     Chromium binaires incompatibles avec le moteur WebView Android,
     leur copie provoquerait un plantage natif à l'ouverture du profil.

### Limites du port Android

- **Un seul profil actif à la fois** : impossible d'avoir deux profils
  ouverts simultanément dans des fenêtres séparées, contrairement à
  Windows/macOS (multi-process). C'est une limitation assumée, conforme à
  la demande initiale.
- **Pas de terminal intégré, pas de script personnalisé, pas d'outils
  Flutter (build & release)** : ces fonctionnalités n'ont de sens que sur
  desktop (accès à un shell, à `flutter build`, à un système de fichiers
  ouvert) et ne sont pas portées sur Android.
- **Import Windows/macOS → paramètres uniquement** : nom et URL de
  démarrage sont repris tels quels, mais le contexte de navigation
  (cookies, session, stockage local…) ne l'est jamais — voir ci-dessus.
  Seul un `.zip` exporté par un autre appareil **Android** restaure le
  contexte complet.
- **Exporter le profil actuellement actif** : possible, mais certaines
  données très récentes peuvent être verrouillées par le moteur WebView
  (actif dès le démarrage du process, même sans fenêtre navigateur
  affichée) — un avertissement s'affiche avant de continuer. Les
  fichiers verrouillés sont simplement ignorés, l'export du reste
  continue normalement.
- **Changement de profil = redémarrage de l'app** : attendu et
  documenté, pas un bug — c'est la contrainte de l'API Android elle-même
  qui l'impose.

# PulseProjects
# PulseProjects
