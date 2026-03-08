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

### Attention
Remember to run `./export_all.dart` after changing any file in this library.

### Platform setup
- `flutter_secure_storage` v10 requires consuming Android apps to set `minSdk` or `minSdkVersion` to `23` or higher.
