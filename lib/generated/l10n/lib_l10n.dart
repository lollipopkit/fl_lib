import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'lib_l10n_az.dart';
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
    Locale('az'),
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

  /// Label for about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// Message template for action and action.
  ///
  /// In en, this message translates to:
  /// **'{action1} and then {action2}?'**
  String actionAndAction(Object action1, Object action2);

  /// Label for active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// Label for add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// Label for addr.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get addr;

  /// Message template for ago fmt.
  ///
  /// In en, this message translates to:
  /// **'{time} ago'**
  String agoFmt(String time);

  /// Abbreviated text for ai.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get ai;

  /// Label for all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// Message shown for anon lose data tip.
  ///
  /// In en, this message translates to:
  /// **'Currently logged in anonymously, continuing operations will result in data loss.'**
  String get anonLoseDataTip;

  /// Label for api endpoint.
  ///
  /// In en, this message translates to:
  /// **'API Endpoint'**
  String get apiEndpoint;

  /// Label for api key.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// Label for api protocol.
  ///
  /// In en, this message translates to:
  /// **'API protocol'**
  String get apiProtocol;

  /// Label for app.
  ///
  /// In en, this message translates to:
  /// **'Application'**
  String get app;

  /// Label for ascending.
  ///
  /// In en, this message translates to:
  /// **'Ascending'**
  String get ascending;

  /// Label for ask ai model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get askAiModel;

  /// Message template for ask continue.
  ///
  /// In en, this message translates to:
  /// **'{msg}. Continue?'**
  String askContinue(Object msg);

  /// Label for attention.
  ///
  /// In en, this message translates to:
  /// **'Attention'**
  String get attention;

  /// Label for auth required.
  ///
  /// In en, this message translates to:
  /// **'Authentication required'**
  String get authRequired;

  /// Label for auto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get auto;

  /// Label for available.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get available;

  /// Label for background.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get background;

  /// Label for backup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backup;

  /// Label for battery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get battery;

  /// Label for bio auth.
  ///
  /// In en, this message translates to:
  /// **'Biometric authentication'**
  String get bioAuth;

  /// Label for blur radius.
  ///
  /// In en, this message translates to:
  /// **'Blur Radius'**
  String get blurRadius;

  /// Label for bright.
  ///
  /// In en, this message translates to:
  /// **'Bright'**
  String get bright;

  /// Label for browsing.
  ///
  /// In en, this message translates to:
  /// **'Browsing'**
  String get browsing;

  /// Label for cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Label for cancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get cancelled;

  /// Label for capacity.
  ///
  /// In en, this message translates to:
  /// **'Capacity'**
  String get capacity;

  /// Label for check update.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkUpdate;

  /// Label for clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// Label for clear history.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get clearHistory;

  /// Label for click.
  ///
  /// In en, this message translates to:
  /// **'Click'**
  String get click;

  /// Label for clipboard.
  ///
  /// In en, this message translates to:
  /// **'Clipboard'**
  String get clipboard;

  /// Label for close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// Label for cmd.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get cmd;

  /// Label for configured.
  ///
  /// In en, this message translates to:
  /// **'Configured'**
  String get configured;

  /// Label for confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// Label for conn.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get conn;

  /// Label for container.
  ///
  /// In en, this message translates to:
  /// **'Container'**
  String get container;

  /// Label for content.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get content;

  /// Label for convert.
  ///
  /// In en, this message translates to:
  /// **'Convert'**
  String get convert;

  /// Label for copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Action: create something new.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// Label for current.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get current;

  /// Label for custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get custom;

  /// URL for custom cmd doc url.
  ///
  /// In en, this message translates to:
  /// **'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands'**
  String get customCmdDocUrl;

  /// Label for cut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get cut;

  /// Label for dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// Label for day.
  ///
  /// In en, this message translates to:
  /// **'Days'**
  String get day;

  /// Label for decode.
  ///
  /// In en, this message translates to:
  /// **'Decode'**
  String get decode;

  /// Label for decompress.
  ///
  /// In en, this message translates to:
  /// **'Decompress'**
  String get decompress;

  /// Message template for del fmt.
  ///
  /// In en, this message translates to:
  /// **'Delete {type}({id})?'**
  String delFmt(Object id, Object type);

  /// Label for delay.
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get delay;

  /// Label for delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Label for descending.
  ///
  /// In en, this message translates to:
  /// **'Descending'**
  String get descending;

  /// Label for description.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// Label for device.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get device;

  /// Label for disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// Label for a setting that is on: the counterpart of disabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get enabled;

  /// Label for disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// Label for disk.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get disk;

  /// Label for doc.
  ///
  /// In en, this message translates to:
  /// **'Documentation'**
  String get doc;

  /// Label for done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// Label for dont show again.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show again'**
  String get dontShowAgain;

  /// Label for download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// Label for duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// Label for edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// Label for editor.
  ///
  /// In en, this message translates to:
  /// **'Editor'**
  String get editor;

  /// Label for empty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get empty;

  /// Label for emulator.
  ///
  /// In en, this message translates to:
  /// **'Emulator'**
  String get emulator;

  /// Label for encode.
  ///
  /// In en, this message translates to:
  /// **'Encode'**
  String get encode;

  /// Label for error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// Label for example.
  ///
  /// In en, this message translates to:
  /// **'Example'**
  String get example;

  /// Label for execute.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get execute;

  /// Label for exit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get exit;

  /// Label for exit confirm tip.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get exitConfirmTip;

  /// Label for exit directly.
  ///
  /// In en, this message translates to:
  /// **'Exit directly'**
  String get exitDirectly;

  /// Label for experimental feature.
  ///
  /// In en, this message translates to:
  /// **'Experimental Feature'**
  String get experimentalFeature;

  /// Label for export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// Label for fail.
  ///
  /// In en, this message translates to:
  /// **'Failure'**
  String get fail;

  /// Label for feedback.
  ///
  /// In en, this message translates to:
  /// **'Feedback'**
  String get feedback;

  /// Label for file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// Label for fold.
  ///
  /// In en, this message translates to:
  /// **'Fold'**
  String get fold;

  /// Label for folder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get folder;

  /// Label for follow system.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get followSystem;

  /// Label for font.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get font;

  /// Label for font size.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get fontSize;

  /// Label for force.
  ///
  /// In en, this message translates to:
  /// **'Force'**
  String get force;

  /// Label for foreground service.
  ///
  /// In en, this message translates to:
  /// **'Foreground Service'**
  String get foregroundService;

  /// Label for format.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get format;

  /// Label for found.
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get found;

  /// Label for gateway.
  ///
  /// In en, this message translates to:
  /// **'Gateway'**
  String get gateway;

  /// Label for general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// Message shown for go back q.
  ///
  /// In en, this message translates to:
  /// **'Go back?'**
  String get goBackQ;

  /// Label for goto.
  ///
  /// In en, this message translates to:
  /// **'Go to'**
  String get goto;

  /// Label for hide title bar.
  ///
  /// In en, this message translates to:
  /// **'Hide title bar'**
  String get hideTitleBar;

  /// Label for highlight.
  ///
  /// In en, this message translates to:
  /// **'Code highlighting'**
  String get highlight;

  /// Label for host.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get host;

  /// Label for hour.
  ///
  /// In en, this message translates to:
  /// **'Hours'**
  String get hour;

  /// Label for image.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get image;

  /// Label for import.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get import;

  /// Label for inactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get inactive;

  /// Label for init.
  ///
  /// In en, this message translates to:
  /// **'Initialize'**
  String get init;

  /// Label for inner.
  ///
  /// In en, this message translates to:
  /// **'Inner'**
  String get inner;

  /// Label for install.
  ///
  /// In en, this message translates to:
  /// **'install'**
  String get install;

  /// Label for invalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid'**
  String get invalid;

  /// Label for invalid url.
  ///
  /// In en, this message translates to:
  /// **'Invalid URL'**
  String get invalidUrl;

  /// Label for just now.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get justNow;

  /// Label for key.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get key;

  /// Label for language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Label for license.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get license;

  /// Abbreviated text for loading ellipsis.
  ///
  /// In en, this message translates to:
  /// **'...'**
  String get loadingEllipsis;

  /// Label for local.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get local;

  /// Label for location.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get location;

  /// Label for log.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get log;

  /// Label for login.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get login;

  /// Message shown for login tip.
  ///
  /// In en, this message translates to:
  /// **'No registration required, free to use.'**
  String get loginTip;

  /// Label for logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// Label for logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// Label for loss.
  ///
  /// In en, this message translates to:
  /// **'loss'**
  String get loss;

  /// Label for manual.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get manual;

  /// Label for max.
  ///
  /// In en, this message translates to:
  /// **'Maximum'**
  String get max;

  /// Label for memory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get memory;

  /// Label for menu help.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get menuHelp;

  /// Label for menu info.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get menuInfo;

  /// Label for menu navigate.
  ///
  /// In en, this message translates to:
  /// **'Navigate'**
  String get menuNavigate;

  /// Label for menu quit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get menuQuit;

  /// Label for menu settings.
  ///
  /// In en, this message translates to:
  /// **'Setting'**
  String get menuSettings;

  /// Label for menu wiki.
  ///
  /// In en, this message translates to:
  /// **'Wiki'**
  String get menuWiki;

  /// Label for migrate cfg.
  ///
  /// In en, this message translates to:
  /// **'Configuration migration'**
  String get migrateCfg;

  /// Label for migrate cfg tip.
  ///
  /// In en, this message translates to:
  /// **'To adapt to the required new configuration'**
  String get migrateCfgTip;

  /// Label for milliseconds.
  ///
  /// In en, this message translates to:
  /// **'Milliseconds'**
  String get milliseconds;

  /// Label for min.
  ///
  /// In en, this message translates to:
  /// **'Minimum'**
  String get min;

  /// Label for minute.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get minute;

  /// Label for mission.
  ///
  /// In en, this message translates to:
  /// **'Mission'**
  String get mission;

  /// Label for mode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get mode;

  /// Label for more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// Label for move down.
  ///
  /// In en, this message translates to:
  /// **'Move Down'**
  String get moveDown;

  /// Label for move up.
  ///
  /// In en, this message translates to:
  /// **'Move Up'**
  String get moveUp;

  /// Abbreviated text for ms.
  ///
  /// In en, this message translates to:
  /// **'ms'**
  String get ms;

  /// Label for name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// Label for net.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get net;

  /// Label for network.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get network;

  /// Label for next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// Label for node.
  ///
  /// In en, this message translates to:
  /// **'Node'**
  String get node;

  /// Choice meaning nothing of the kind.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// Label for not available.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get notAvailable;

  /// Message template for not exist fmt.
  ///
  /// In en, this message translates to:
  /// **'{file} not exist'**
  String notExistFmt(Object file);

  /// Label for note.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get note;

  /// Label for ok.
  ///
  /// In en, this message translates to:
  /// **'Okay'**
  String get ok;

  /// Label for opacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get opacity;

  /// Label for open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// Marks a field that may be left empty.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get optional;

  /// Label for paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// Label for path.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get path;

  /// Label for permission.
  ///
  /// In en, this message translates to:
  /// **'Permission'**
  String get permission;

  /// Message shown for permission denied.
  ///
  /// In en, this message translates to:
  /// **'Permission denied.'**
  String get permissionDenied;

  /// Label for ping avg.
  ///
  /// In en, this message translates to:
  /// **'Avg:'**
  String get pingAvg;

  /// Abbreviated text for pkg.
  ///
  /// In en, this message translates to:
  /// **'Pkg'**
  String get pkg;

  /// Label for port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// Label for port forward.
  ///
  /// In en, this message translates to:
  /// **'Port Forward'**
  String get portForward;

  /// Label for preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// Label for previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// Label for primary color seed.
  ///
  /// In en, this message translates to:
  /// **'Primary color seed'**
  String get primaryColorSeed;

  /// Label for process.
  ///
  /// In en, this message translates to:
  /// **'Process'**
  String get process;

  /// Label for prune.
  ///
  /// In en, this message translates to:
  /// **'Prune'**
  String get prune;

  /// Label for pwd.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get pwd;

  /// Label for pwd tip.
  ///
  /// In en, this message translates to:
  /// **'Length 6-32, can be English letters, numbers, and punctuation'**
  String get pwdTip;

  /// Label for read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// Label for ready.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get ready;

  /// Label for reboot.
  ///
  /// In en, this message translates to:
  /// **'Reboot'**
  String get reboot;

  /// Message shown for reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting...'**
  String get reconnecting;

  /// Label for redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// Label for refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// Label for register.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get register;

  /// Label for remote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get remote;

  /// Label for rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// Label for replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// Label for replace all.
  ///
  /// In en, this message translates to:
  /// **'Replace all'**
  String get replaceAll;

  /// Label for reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// Label for restart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get restart;

  /// Label for restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// Label for result.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get result;

  /// Label for retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Label for route.
  ///
  /// In en, this message translates to:
  /// **'Routing'**
  String get route;

  /// Label for run.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get run;

  /// Label for running.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get running;

  /// Label for save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Label for save failed.
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get saveFailed;

  /// Label for saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// Label for search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Label for second.
  ///
  /// In en, this message translates to:
  /// **'Seconds'**
  String get second;

  /// Label for select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// Label for sensors.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get sensors;

  /// Label for sequence.
  ///
  /// In en, this message translates to:
  /// **'Sequence'**
  String get sequence;

  /// Label for server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// Label for servers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get servers;

  /// Label for setting.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get setting;

  /// Label for share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// Label for shutdown.
  ///
  /// In en, this message translates to:
  /// **'Shutdown'**
  String get shutdown;

  /// Label for size.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get size;

  /// Message template for size too large only prefix.
  ///
  /// In en, this message translates to:
  /// **'Content too large, displaying only the first {bytes}'**
  String sizeTooLargeOnlyPrefix(Object bytes);

  /// Label for snippet.
  ///
  /// In en, this message translates to:
  /// **'Snippet'**
  String get snippet;

  /// Label for soft wrap.
  ///
  /// In en, this message translates to:
  /// **'Soft wrap'**
  String get softWrap;

  /// Label for sort.
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get sort;

  /// Label for sort by name.
  ///
  /// In en, this message translates to:
  /// **'By name'**
  String get sortByName;

  /// Label for source.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get source;

  /// Label for speed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get speed;

  /// Label for start.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get start;

  /// Label for stat.
  ///
  /// In en, this message translates to:
  /// **'Statistics'**
  String get stat;

  /// Label for stats.
  ///
  /// In en, this message translates to:
  /// **'Statistics'**
  String get stats;

  /// Label for stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// Label for stopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get stopped;

  /// Label for storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// Label for success.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get success;

  /// Label for sudo password.
  ///
  /// In en, this message translates to:
  /// **'sudo password'**
  String get sudoPassword;

  /// Message template for sudo pwd title.
  ///
  /// In en, this message translates to:
  /// **'sudo {pwd}'**
  String sudoPwdTitle(Object pwd);

  /// Label for suspend.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get suspend;

  /// Label for switch .
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get switch_;

  /// Label for switcher.
  ///
  /// In en, this message translates to:
  /// **'Switcher'**
  String get switcher;

  /// Label for sync.
  ///
  /// In en, this message translates to:
  /// **'Synchronize'**
  String get sync;

  /// Label for system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// Label for tag.
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get tag;

  /// Label for tap to auth.
  ///
  /// In en, this message translates to:
  /// **'Click to verify'**
  String get tapToAuth;

  /// Label for temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get temperature;

  /// Label for terminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get terminal;

  /// Label for test.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get test;

  /// Label for text scaler.
  ///
  /// In en, this message translates to:
  /// **'Text scaler'**
  String get textScaler;

  /// Label for theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// Label for theme mode.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get themeMode;

  /// Label for thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinking;

  /// Label for time.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get time;

  /// Label for timed out.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get timedOut;

  /// Label for timeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get timeout;

  /// Label for times.
  ///
  /// In en, this message translates to:
  /// **'Times'**
  String get times;

  /// Label for total.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get total;

  /// Label for total attempts.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get totalAttempts;

  /// Label for traffic.
  ///
  /// In en, this message translates to:
  /// **'Traffic'**
  String get traffic;

  /// Abbreviated text for ttl.
  ///
  /// In en, this message translates to:
  /// **'TTL'**
  String get ttl;

  /// Label for type.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get type;

  /// Label for undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// Label for unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// Label for unsupported.
  ///
  /// In en, this message translates to:
  /// **'Not supported'**
  String get unsupported;

  /// Label for update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// Label for upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// Label for uptime.
  ///
  /// In en, this message translates to:
  /// **'Uptime'**
  String get uptime;

  /// Label for used.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get used;

  /// Label for user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// Label for valid.
  ///
  /// In en, this message translates to:
  /// **'Valid'**
  String get valid;

  /// Label for value.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get value;

  /// Message template for version has update.
  ///
  /// In en, this message translates to:
  /// **'Found: v1.0.{build}, click to update'**
  String versionHasUpdate(Object build);

  /// Message template for version unknown update.
  ///
  /// In en, this message translates to:
  /// **'Current: v1.0.{build}, click to check updates'**
  String versionUnknownUpdate(Object build);

  /// Message template for version updated.
  ///
  /// In en, this message translates to:
  /// **'Current: v1.0.{build}, is up to date'**
  String versionUpdated(Object build);

  /// Label for view.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get view;

  /// Label for view err.
  ///
  /// In en, this message translates to:
  /// **'See error'**
  String get viewErr;

  /// Label for write.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get write;

  /// Label for yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// A length of time in whole days.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 day} other{{count} days}}'**
  String durationDays(int count);

  /// A length of time in whole hours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 hour} other{{count} hours}}'**
  String durationHours(int count);

  /// A length of time in whole minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 minute} other{{count} minutes}}'**
  String durationMinutes(int count);

  /// A length of time in whole seconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 second} other{{count} seconds}}'**
  String durationSeconds(int count);
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
    'az',
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
    case 'az':
      return LibLocalizationsAz();
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
