import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'lib_l10n_de.dart';
import 'lib_l10n_en.dart';
import 'lib_l10n_es.dart';
import 'lib_l10n_fr.dart';
import 'lib_l10n_id.dart';
import 'lib_l10n_it.dart';
import 'lib_l10n_ja.dart';
import 'lib_l10n_ko.dart';
import 'lib_l10n_nl.dart';
import 'lib_l10n_pt.dart';
import 'lib_l10n_ru.dart';
import 'lib_l10n_tr.dart';
import 'lib_l10n_uk.dart';
import 'lib_l10n_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of LibLocalizations
/// returned by `LibLocalizations.of(context)`.
///
/// Applications need to include `LibLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/lib_l10n.dart';
///
/// return MaterialApp(
///   localizationsDelegates: LibLocalizations.localizationsDelegates,
///   supportedLocales: LibLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the LibLocalizations.supportedLocales
/// property.
abstract class LibLocalizations {
  LibLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static LibLocalizations? of(BuildContext context) {
    return Localizations.of<LibLocalizations>(context, LibLocalizations);
  }

  static const LocalizationsDelegate<LibLocalizations> delegate =
      _LibLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('id'),
    Locale('it'),
    Locale('ja'),
    Locale('ko'),
    Locale('nl'),
    Locale('pt'),
    Locale('ru'),
    Locale('tr'),
    Locale('uk'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @actionAndAction.
  ///
  /// In en, this message translates to:
  /// **'{action1} and then {action2}?'**
  String actionAndAction(Object action1, Object action2);

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @anonLoseDataTip.
  ///
  /// In en, this message translates to:
  /// **'Currently logged in anonymously, continuing operations will result in data loss.'**
  String get anonLoseDataTip;

  /// No description provided for @app.
  ///
  /// In en, this message translates to:
  /// **'Application'**
  String get app;

  /// No description provided for @askContinue.
  ///
  /// In en, this message translates to:
  /// **'{msg}. Continue?'**
  String askContinue(Object msg);

  /// No description provided for @attention.
  ///
  /// In en, this message translates to:
  /// **'Attention'**
  String get attention;

  /// No description provided for @authRequired.
  ///
  /// In en, this message translates to:
  /// **'Authentication required'**
  String get authRequired;

  /// No description provided for @auto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get auto;

  /// No description provided for @background.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get background;

  /// No description provided for @backup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backup;

  /// No description provided for @bioAuth.
  ///
  /// In en, this message translates to:
  /// **'Biometric authentication'**
  String get bioAuth;

  /// No description provided for @blurRadius.
  ///
  /// In en, this message translates to:
  /// **'Blur Radius'**
  String get blurRadius;

  /// No description provided for @bright.
  ///
  /// In en, this message translates to:
  /// **'Bright'**
  String get bright;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @checkUpdate.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkUpdate;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @click.
  ///
  /// In en, this message translates to:
  /// **'Click'**
  String get click;

  /// No description provided for @clipboard.
  ///
  /// In en, this message translates to:
  /// **'Clipboard'**
  String get clipboard;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @content.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get content;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get custom;

  /// No description provided for @cut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get cut;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @day.
  ///
  /// In en, this message translates to:
  /// **'Days'**
  String get day;

  /// No description provided for @delFmt.
  ///
  /// In en, this message translates to:
  /// **'Delete {type}({id})?'**
  String delFmt(Object id, Object type);

  /// No description provided for @delay.
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get delay;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @device.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get device;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// No description provided for @doc.
  ///
  /// In en, this message translates to:
  /// **'Documentation'**
  String get doc;

  /// No description provided for @dontShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show again'**
  String get dontShowAgain;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @editor.
  ///
  /// In en, this message translates to:
  /// **'Editor'**
  String get editor;

  /// No description provided for @empty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get empty;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @example.
  ///
  /// In en, this message translates to:
  /// **'Example'**
  String get example;

  /// No description provided for @execute.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get execute;

  /// No description provided for @exit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get exit;

  /// No description provided for @exitConfirmTip.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get exitConfirmTip;

  /// No description provided for @exitDirectly.
  ///
  /// In en, this message translates to:
  /// **'Exit directly'**
  String get exitDirectly;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @fail.
  ///
  /// In en, this message translates to:
  /// **'Failure'**
  String get fail;

  /// No description provided for @feedback.
  ///
  /// In en, this message translates to:
  /// **'Feedback'**
  String get feedback;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @fold.
  ///
  /// In en, this message translates to:
  /// **'Fold'**
  String get fold;

  /// No description provided for @folder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get folder;

  /// No description provided for @font.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get font;

  /// No description provided for @found.
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get found;

  /// No description provided for @hideTitleBar.
  ///
  /// In en, this message translates to:
  /// **'Hide title bar'**
  String get hideTitleBar;

  /// No description provided for @hour.
  ///
  /// In en, this message translates to:
  /// **'Hours'**
  String get hour;

  /// No description provided for @image.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get image;

  /// No description provided for @import.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get import;

  /// No description provided for @init.
  ///
  /// In en, this message translates to:
  /// **'Initialize'**
  String get init;

  /// No description provided for @key.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get key;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @license.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get license;

  /// No description provided for @log.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get log;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get login;

  /// No description provided for @loginTip.
  ///
  /// In en, this message translates to:
  /// **'No registration required, free to use.'**
  String get loginTip;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// No description provided for @manual.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get manual;

  /// No description provided for @migrateCfg.
  ///
  /// In en, this message translates to:
  /// **'Configuration migration'**
  String get migrateCfg;

  /// No description provided for @migrateCfgTip.
  ///
  /// In en, this message translates to:
  /// **'To adapt to the required new configuration'**
  String get migrateCfgTip;

  /// No description provided for @minute.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get minute;

  /// No description provided for @moveDown.
  ///
  /// In en, this message translates to:
  /// **'Move Down'**
  String get moveDown;

  /// No description provided for @moveUp.
  ///
  /// In en, this message translates to:
  /// **'Move Up'**
  String get moveUp;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get network;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @notExistFmt.
  ///
  /// In en, this message translates to:
  /// **'{file} not exist'**
  String notExistFmt(Object file);

  /// No description provided for @note.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get note;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'Okay'**
  String get ok;

  /// No description provided for @opacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get opacity;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @path.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get path;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @primaryColorSeed.
  ///
  /// In en, this message translates to:
  /// **'Primary color seed'**
  String get primaryColorSeed;

  /// No description provided for @pwd.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get pwd;

  /// No description provided for @pwdTip.
  ///
  /// In en, this message translates to:
  /// **'Length 6-32, can be English letters, numbers, and punctuation'**
  String get pwdTip;

  /// No description provided for @redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get register;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// No description provided for @replaceAll.
  ///
  /// In en, this message translates to:
  /// **'Replace all'**
  String get replaceAll;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @result.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get result;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @second.
  ///
  /// In en, this message translates to:
  /// **'Seconds'**
  String get second;

  /// No description provided for @select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// No description provided for @setting.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get setting;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @size.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get size;

  /// No description provided for @sizeTooLargeOnlyPrefix.
  ///
  /// In en, this message translates to:
  /// **'Content too large, displaying only the first {bytes}'**
  String sizeTooLargeOnlyPrefix(Object bytes);

  /// No description provided for @start.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get start;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @success.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get success;

  /// No description provided for @switch_.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get switch_;

  /// No description provided for @switcher.
  ///
  /// In en, this message translates to:
  /// **'Switcher'**
  String get switcher;

  /// No description provided for @sync.
  ///
  /// In en, this message translates to:
  /// **'Synchronize'**
  String get sync;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @tag.
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get tag;

  /// No description provided for @tapToAuth.
  ///
  /// In en, this message translates to:
  /// **'Click to verify'**
  String get tapToAuth;

  /// No description provided for @themeMode.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get themeMode;

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinking;

  /// No description provided for @timeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get timeout;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @unsupported.
  ///
  /// In en, this message translates to:
  /// **'Not supported'**
  String get unsupported;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @value.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get value;

  /// No description provided for @versionHasUpdate.
  ///
  /// In en, this message translates to:
  /// **'Found: v1.0.{build}, click to update'**
  String versionHasUpdate(Object build);

  /// No description provided for @versionUnknownUpdate.
  ///
  /// In en, this message translates to:
  /// **'Current: v1.0.{build}, click to check updates'**
  String versionUnknownUpdate(Object build);

  /// No description provided for @versionUpdated.
  ///
  /// In en, this message translates to:
  /// **'Current: v1.0.{build}, is up to date'**
  String versionUpdated(Object build);

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @addr.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get addr;

  /// No description provided for @available.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get available;

  /// No description provided for @convert.
  ///
  /// In en, this message translates to:
  /// **'Convert'**
  String get convert;

  /// No description provided for @experimentalFeature.
  ///
  /// In en, this message translates to:
  /// **'Experimental Feature'**
  String get experimentalFeature;

  /// No description provided for @foregroundService.
  ///
  /// In en, this message translates to:
  /// **'Foreground Service'**
  String get foregroundService;

  /// No description provided for @goto.
  ///
  /// In en, this message translates to:
  /// **'Go to'**
  String get goto;

  /// No description provided for @invalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid'**
  String get invalid;

  /// No description provided for @valid.
  ///
  /// In en, this message translates to:
  /// **'Valid'**
  String get valid;

  /// No description provided for @max.
  ///
  /// In en, this message translates to:
  /// **'Maximum'**
  String get max;

  /// No description provided for @min.
  ///
  /// In en, this message translates to:
  /// **'Minimum'**
  String get min;

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @milliseconds.
  ///
  /// In en, this message translates to:
  /// **'Milliseconds'**
  String get milliseconds;

  /// No description provided for @permission.
  ///
  /// In en, this message translates to:
  /// **'Permission'**
  String get permission;

  /// No description provided for @read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// No description provided for @write.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get write;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @speed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get speed;

  /// No description provided for @stat.
  ///
  /// In en, this message translates to:
  /// **'Statistics'**
  String get stat;

  /// No description provided for @time.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get time;

  /// No description provided for @times.
  ///
  /// In en, this message translates to:
  /// **'Times'**
  String get times;

  /// No description provided for @used.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get used;

  /// No description provided for @view.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get view;

  /// No description provided for @askAiModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get askAiModel;

  /// No description provided for @battery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get battery;

  /// No description provided for @cmd.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get cmd;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @conn.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get conn;

  /// No description provided for @container.
  ///
  /// In en, this message translates to:
  /// **'Container'**
  String get container;

  /// No description provided for @customCmdDocUrl.
  ///
  /// In en, this message translates to:
  /// **'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands'**
  String get customCmdDocUrl;

  /// No description provided for @decode.
  ///
  /// In en, this message translates to:
  /// **'Decode'**
  String get decode;

  /// No description provided for @decompress.
  ///
  /// In en, this message translates to:
  /// **'Decompress'**
  String get decompress;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @disk.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get disk;

  /// No description provided for @emulator.
  ///
  /// In en, this message translates to:
  /// **'Emulator'**
  String get emulator;

  /// No description provided for @encode.
  ///
  /// In en, this message translates to:
  /// **'Encode'**
  String get encode;

  /// No description provided for @force.
  ///
  /// In en, this message translates to:
  /// **'Force'**
  String get force;

  /// No description provided for @host.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get host;

  /// No description provided for @inner.
  ///
  /// In en, this message translates to:
  /// **'Inner'**
  String get inner;

  /// No description provided for @install.
  ///
  /// In en, this message translates to:
  /// **'install'**
  String get install;

  /// No description provided for @location.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get location;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// No description provided for @loss.
  ///
  /// In en, this message translates to:
  /// **'loss'**
  String get loss;

  /// No description provided for @menuHelp.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get menuHelp;

  /// No description provided for @menuInfo.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get menuInfo;

  /// No description provided for @menuNavigate.
  ///
  /// In en, this message translates to:
  /// **'Navigate'**
  String get menuNavigate;

  /// No description provided for @menuQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get menuQuit;

  /// No description provided for @menuSettings.
  ///
  /// In en, this message translates to:
  /// **'Setting'**
  String get menuSettings;

  /// No description provided for @menuWiki.
  ///
  /// In en, this message translates to:
  /// **'Wiki'**
  String get menuWiki;

  /// No description provided for @mission.
  ///
  /// In en, this message translates to:
  /// **'Mission'**
  String get mission;

  /// No description provided for @ms.
  ///
  /// In en, this message translates to:
  /// **'ms'**
  String get ms;

  /// No description provided for @net.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get net;

  /// No description provided for @node.
  ///
  /// In en, this message translates to:
  /// **'Node'**
  String get node;

  /// No description provided for @notAvailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get notAvailable;

  /// No description provided for @pingAvg.
  ///
  /// In en, this message translates to:
  /// **'Avg:'**
  String get pingAvg;

  /// No description provided for @pkg.
  ///
  /// In en, this message translates to:
  /// **'Pkg'**
  String get pkg;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @process.
  ///
  /// In en, this message translates to:
  /// **'Process'**
  String get process;

  /// No description provided for @prune.
  ///
  /// In en, this message translates to:
  /// **'Prune'**
  String get prune;

  /// No description provided for @reboot.
  ///
  /// In en, this message translates to:
  /// **'Reboot'**
  String get reboot;

  /// No description provided for @restart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get restart;

  /// No description provided for @route.
  ///
  /// In en, this message translates to:
  /// **'Routing'**
  String get route;

  /// No description provided for @run.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get run;

  /// No description provided for @running.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get running;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @sensors.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get sensors;

  /// No description provided for @sequence.
  ///
  /// In en, this message translates to:
  /// **'Sequence'**
  String get sequence;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @servers.
  ///
  /// In en, this message translates to:
  /// **'servers'**
  String get servers;

  /// No description provided for @shutdown.
  ///
  /// In en, this message translates to:
  /// **'Shutdown'**
  String get shutdown;

  /// No description provided for @snippet.
  ///
  /// In en, this message translates to:
  /// **'Snippet'**
  String get snippet;

  /// No description provided for @stats.
  ///
  /// In en, this message translates to:
  /// **'Statistics'**
  String get stats;

  /// No description provided for @stopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get stopped;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @suspend.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get suspend;

  /// No description provided for @temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get temperature;

  /// No description provided for @terminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get terminal;

  /// No description provided for @test.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get test;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @total.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get total;

  /// No description provided for @totalAttempts.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get totalAttempts;

  /// No description provided for @traffic.
  ///
  /// In en, this message translates to:
  /// **'Traffic'**
  String get traffic;

  /// No description provided for @ttl.
  ///
  /// In en, this message translates to:
  /// **'TTL'**
  String get ttl;

  /// No description provided for @uptime.
  ///
  /// In en, this message translates to:
  /// **'Uptime'**
  String get uptime;
}

class _LibLocalizationsDelegate
    extends LocalizationsDelegate<LibLocalizations> {
  const _LibLocalizationsDelegate();

  @override
  Future<LibLocalizations> load(Locale locale) {
    return SynchronousFuture<LibLocalizations>(lookupLibLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'id',
    'it',
    'ja',
    'ko',
    'nl',
    'pt',
    'ru',
    'tr',
    'uk',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_LibLocalizationsDelegate old) => false;
}

LibLocalizations lookupLibLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return LibLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return LibLocalizationsDe();
    case 'en':
      return LibLocalizationsEn();
    case 'es':
      return LibLocalizationsEs();
    case 'fr':
      return LibLocalizationsFr();
    case 'id':
      return LibLocalizationsId();
    case 'it':
      return LibLocalizationsIt();
    case 'ja':
      return LibLocalizationsJa();
    case 'ko':
      return LibLocalizationsKo();
    case 'nl':
      return LibLocalizationsNl();
    case 'pt':
      return LibLocalizationsPt();
    case 'ru':
      return LibLocalizationsRu();
    case 'tr':
      return LibLocalizationsTr();
    case 'uk':
      return LibLocalizationsUk();
    case 'zh':
      return LibLocalizationsZh();
  }

  throw FlutterError(
    'LibLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
