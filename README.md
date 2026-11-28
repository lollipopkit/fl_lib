## fl_lib
Common library for the my Flutter projects.

### Usage
1. First, add dep.
   ```yaml
   dependencies:
     fl_lib:
       git:
         url: https://github.com/lppcg/fl_lib.git
         ref: main
   ```

2. Set `localizationsDelegates`
   ```dart
   MaterialApp(
     localizationsDelegates: const [
       LibLocalizations.delegate,
       ...AppLocalizations.localizationsDelegates,
     ],
     supportedLocales: AppLocalizations.supportedLocales,
   )
   ```

3. Update lib l10n
   ```dart
   void didChangeDependencies() {
     super.didChangeDependencies();
     context.setLibL10n();
   }
   ```

4. Init `Paths`
   ```dart
   void main() async {
     await Paths.init();
     runApp(MyApp());
   }
   ```

### Optional sub-packages

#### `fl_lib_scan` (`packages/fl_lib_scan`)
Provides `BarcodeScannerPage` (depends on `qr_code_dart_scan` / `camera`). Kept separate so apps that do not scan codes do not link camera plugins or inherit camera permission requirements.

With `fl_lib` as a git submodule:
```yaml
dependencies:
  fl_lib:
    path: packages/fl_lib
  fl_lib_scan:
    path: packages/fl_lib/packages/fl_lib_scan
```

If consumed via `git:` instead of a submodule, pin both `fl_lib` and `fl_lib_scan` to the same full 40-character commit SHA (or add a `dependency_overrides` entry for `fl_lib`), because `fl_lib_scan` references `fl_lib` via `path: ../..`.

### Attention
Remember to run `./export_all.dart` after changing any file in this library.
