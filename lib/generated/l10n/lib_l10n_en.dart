// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LibLocalizationsEn extends LibLocalizations {
  LibLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get about => 'About';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1 and then $action2?';
  }

  @override
  String get active => 'Active';

  @override
  String get add => 'Add';

  @override
  String get addr => 'Address';

  @override
  String agoFmt(String time) {
    return '$time ago';
  }

  @override
  String get ai => 'AI';

  @override
  String get all => 'All';

  @override
  String get anonLoseDataTip =>
      'Currently logged in anonymously, continuing operations will result in data loss.';

  @override
  String get apiEndpoint => 'API Endpoint';

  @override
  String get apiKey => 'API Key';

  @override
  String get apiProtocol => 'API protocol';

  @override
  String get app => 'Application';

  @override
  String get ascending => 'Ascending';

  @override
  String get askAiModel => 'Model';

  @override
  String askContinue(Object msg) {
    return '$msg. Continue?';
  }

  @override
  String get attention => 'Attention';

  @override
  String get authRequired => 'Authentication required';

  @override
  String get auto => 'Auto';

  @override
  String get available => 'Available';

  @override
  String get background => 'Background';

  @override
  String get backup => 'Backup';

  @override
  String get battery => 'Battery';

  @override
  String get bioAuth => 'Biometric authentication';

  @override
  String get blurRadius => 'Blur Radius';

  @override
  String get bright => 'Bright';

  @override
  String get browsing => 'Browsing';

  @override
  String get cancel => 'Cancel';

  @override
  String get cancelled => 'Cancelled';

  @override
  String get capacity => 'Capacity';

  @override
  String get checkUpdate => 'Check for updates';

  @override
  String get clear => 'Clear';

  @override
  String get clearHistory => 'Clear history';

  @override
  String get click => 'Click';

  @override
  String get clipboard => 'Clipboard';

  @override
  String get clone => 'Clone';

  @override
  String get close => 'Close';

  @override
  String get cmd => 'Command';

  @override
  String get configured => 'Configured';

  @override
  String get confirm => 'Confirm';

  @override
  String get conn => 'Connection';

  @override
  String get container => 'Container';

  @override
  String get content => 'Content';

  @override
  String get convert => 'Convert';

  @override
  String get copy => 'Copy';

  @override
  String get create => 'Create';

  @override
  String get current => 'Current';

  @override
  String get custom => 'Custom';

  @override
  String get defaultLabel => 'Default';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get cut => 'Cut';

  @override
  String get dark => 'Dark';

  @override
  String get day => 'Days';

  @override
  String get decode => 'Decode';

  @override
  String get decompress => 'Decompress';

  @override
  String delFmt(Object id, Object type) {
    return 'Delete $type($id)?';
  }

  @override
  String get delay => 'Delay';

  @override
  String get delete => 'Delete';

  @override
  String get descending => 'Descending';

  @override
  String get description => 'Description';

  @override
  String get device => 'Device';

  @override
  String get disabled => 'Disabled';

  @override
  String get enabled => 'Enabled';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get disk => 'Disk';

  @override
  String get doc => 'Documentation';

  @override
  String get done => 'Done';

  @override
  String get dontShowAgain => 'Don\'t show again';

  @override
  String get download => 'Download';

  @override
  String get duration => 'Duration';

  @override
  String get edit => 'Edit';

  @override
  String get editor => 'Editor';

  @override
  String get empty => 'Empty';

  @override
  String get emulator => 'Emulator';

  @override
  String get encode => 'Encode';

  @override
  String get error => 'Error';

  @override
  String get example => 'Example';

  @override
  String get execute => 'Execute';

  @override
  String get exit => 'Exit';

  @override
  String get exitConfirmTip => 'Press back again to exit';

  @override
  String get exitDirectly => 'Exit directly';

  @override
  String get experimentalFeature => 'Experimental Feature';

  @override
  String get export => 'Export';

  @override
  String get fail => 'Failure';

  @override
  String get feedback => 'Feedback';

  @override
  String get file => 'File';

  @override
  String get fold => 'Fold';

  @override
  String get folder => 'Folder';

  @override
  String get followSystem => 'Follow system';

  @override
  String get font => 'Font';

  @override
  String get fontSize => 'Font size';

  @override
  String get force => 'Force';

  @override
  String get foregroundService => 'Foreground Service';

  @override
  String get format => 'Format';

  @override
  String get found => 'Found';

  @override
  String get gateway => 'Gateway';

  @override
  String get general => 'General';

  @override
  String get goBackQ => 'Go back?';

  @override
  String get goto => 'Go to';

  @override
  String get hideTitleBar => 'Hide title bar';

  @override
  String get highlight => 'Code highlighting';

  @override
  String get host => 'Host';

  @override
  String get hour => 'Hours';

  @override
  String get image => 'Image';

  @override
  String get import => 'Import';

  @override
  String get inactive => 'Inactive';

  @override
  String get init => 'Initialize';

  @override
  String get inner => 'Inner';

  @override
  String get install => 'Install';

  @override
  String get invalid => 'Invalid';

  @override
  String get invalidUrl => 'Invalid URL';

  @override
  String get justNow => 'Just now';

  @override
  String get key => 'Key';

  @override
  String get language => 'Language';

  @override
  String get license => 'License';

  @override
  String get lkcAccount => 'LKC Cloud account';

  @override
  String lkcBenefitBackupAppBytes(String size) {
    return 'up to $size per app';
  }

  @override
  String get lkcBenefitBackupLatest => 'the latest one per app';

  @override
  String get lkcBenefitBackupNoLimit => 'no size limit';

  @override
  String lkcBenefitBackupRolling(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count rolling backups',
      one: '1 rolling backup',
    );
    return '$_temp0 per app';
  }

  @override
  String get lkcBenefitBackupRollingUnlimited =>
      'unlimited rolling backups per app';

  @override
  String lkcBenefitBackupTotalBytes(String size) {
    return '$size shared by all apps';
  }

  @override
  String lkcBenefitBackups(String kept, String limit) {
    return 'Backups: $kept, $limit';
  }

  @override
  String lkcBenefitRelay(String rate) {
    return 'Monitor relay, tailnet and push notifications: unlimited traffic, relay at $rate, no availability guarantee';
  }

  @override
  String get lkcBenefitRelayUnlimited =>
      'Monitor relay, tailnet and push notifications: unlimited traffic and speed, no availability guarantee';

  @override
  String get lkcBenefitShareLinks => 'Share links with expiry';

  @override
  String lkcBenefitStorage(String size, String file) {
    return 'WebDAV $size, files up to $file each';
  }

  @override
  String lkcBenefitStorageUnlimited(String file) {
    return 'WebDAV without a size limit, files up to $file each';
  }

  @override
  String get lkcBenefitSync =>
      'Real-time sync across devices (end-to-end encrypted)';

  @override
  String lkcBenefitUptime(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: 'minute',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count targets',
      one: '1 target',
    );
    return 'External downtime checks every $_temp0, up to $_temp1';
  }

  @override
  String lkcBenefitUptimeTargets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count targets',
      one: '1 target',
    );
    return 'External downtime checks, up to $_temp0';
  }

  @override
  String get lkcBenefitUptimeTargetsUnlimited =>
      'External downtime checks, unlimited targets';

  @override
  String lkcBenefitUptimeUnlimited(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: 'minute',
    );
    return 'External downtime checks every $_temp0, unlimited targets';
  }

  @override
  String get lkcCurrentPlan => 'Current plan';

  @override
  String get lkcDeleteAccount => 'Delete account';

  @override
  String get lkcDeleteAccountTip =>
      'Your account, your files and your web subscriptions are deleted for good. This can’t be undone.';

  @override
  String lkcEndsOn(String date) {
    return 'Ends on $date';
  }

  @override
  String lkcFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get lkcFiles => 'Files';

  @override
  String get lkcFreeTier => 'Free';

  @override
  String get lkcManageSubscriptions => 'Manage subscriptions';

  @override
  String get lkcPastDue => 'Payment past due';

  @override
  String get lkcPasteToken => 'Paste token';

  @override
  String get lkcPasteTokenTip =>
      'If the app doesn’t open after you sign in, copy the token shown on the page and paste it here.';

  @override
  String get lkcPaused => 'Paused';

  @override
  String lkcPerMonth(String price) {
    return '$price / month';
  }

  @override
  String lkcPerYear(String price) {
    return '$price / year';
  }

  @override
  String get lkcPlans => 'Plans';

  @override
  String get lkcReasonAlreadySubscribed => 'Already subscribed';

  @override
  String get lkcReasonBadPurchaseToken => 'Invalid purchase token';

  @override
  String get lkcReasonBadPushToken => 'Invalid push token';

  @override
  String get lkcReasonBadQuery => 'Invalid query';

  @override
  String get lkcReasonBadSignature => 'Invalid signature';

  @override
  String get lkcReasonBadTransaction => 'Invalid transaction';

  @override
  String get lkcReasonBenefitInvalid =>
      'A benefit is listed twice, of a tier that doesn\'t have it, or of no owner';

  @override
  String get lkcReasonCodeCheckout =>
      'The code can\'t be used with this checkout';

  @override
  String get lkcReasonCodeCurrency =>
      'The code\'s currency doesn\'t match the price';

  @override
  String get lkcReasonCodeCurrencyNeeded => 'A fixed amount needs its currency';

  @override
  String get lkcReasonCodeDiscountPeriods => 'A discount grants no periods';

  @override
  String get lkcReasonCodeDuration => 'Pick which payments the discount covers';

  @override
  String get lkcReasonCodeExpired => 'The code has expired';

  @override
  String get lkcReasonCodeFormat =>
      'A code is 4 to 32 letters, digits or dashes';

  @override
  String get lkcReasonCodeGrantOff => 'A grant has no discount';

  @override
  String get lkcReasonCodeGrantPeriods => 'A grant lasts 1 to 120 periods';

  @override
  String get lkcReasonCodeGrantPlan => 'A grant is of one plan';

  @override
  String get lkcReasonCodeInactive => 'The code is no longer valid';

  @override
  String get lkcReasonCodeIsDiscount =>
      'The code is a discount, enter it when subscribing';

  @override
  String get lkcReasonCodeIsGrant =>
      'The code grants a plan, redeem it instead';

  @override
  String get lkcReasonCodeKind => 'A code\'s kind can\'t change';

  @override
  String get lkcReasonCodeLimit => 'The redemption limit must be positive';

  @override
  String get lkcReasonCodeLineHeld =>
      'You already have a subscription in this line';

  @override
  String get lkcReasonCodeMonths => 'A repeating discount lasts 1 to 36 months';

  @override
  String get lkcReasonCodeNewOnly => 'The code is for new subscribers only';

  @override
  String get lkcReasonCodeNotStarted => 'The code is not valid yet';

  @override
  String get lkcReasonCodeOff =>
      'A discount is a percentage (1 to 100) or a fixed amount';

  @override
  String get lkcReasonCodePlan => 'The code doesn\'t apply to this plan';

  @override
  String get lkcReasonCodePlans => 'Pick the plans the code applies to';

  @override
  String get lkcReasonCodeRedeemed =>
      'The code has been redeemed, deactivate it instead';

  @override
  String get lkcReasonCodeTaken => 'The code exists already';

  @override
  String get lkcReasonCodeTries => 'Too many tries, try again later';

  @override
  String get lkcReasonCodeUnknown => 'No such code';

  @override
  String get lkcReasonCodeUsed => 'You have used this code';

  @override
  String get lkcReasonCodeUsedUp => 'The code has been used up';

  @override
  String get lkcReasonCodeWindow => 'The code must start before it expires';

  @override
  String get lkcReasonDeleteAdmin =>
      'Remove the admin role at the IdP before deleting an admin';

  @override
  String get lkcReasonDeleteSelf =>
      'Delete your own account from the account page';

  @override
  String get lkcReasonFileExists => 'A file of this name exists';

  @override
  String get lkcReasonFileName => 'Not a valid file or directory name';

  @override
  String get lkcReasonFileQuota => 'The files would exceed the storage quota';

  @override
  String get lkcReasonFileTooLarge => 'The file is too large';

  @override
  String get lkcReasonForeignTransaction =>
      'Transaction of another app or environment';

  @override
  String get lkcReasonGrantGone => 'No such live manual subscription';

  @override
  String get lkcReasonGrantHeld =>
      'The user has a manual subscription in this line, change it instead';

  @override
  String get lkcReasonGrantInPast => 'The grant must end in the future';

  @override
  String get lkcReasonManualProvider => 'Manual is not a provider';

  @override
  String get lkcReasonNoCustomer => 'No subscription to manage';

  @override
  String get lkcReasonNoSwitch => 'No web subscription in this line to switch';

  @override
  String get lkcReasonNoUser => 'No such user';

  @override
  String get lkcReasonPriceArchived =>
      'A sold price is archived at its provider';

  @override
  String get lkcReasonPriceMissing =>
      'A sold price doesn\'t exist at its provider';

  @override
  String get lkcReasonPriceNotFixed => 'A sold price has no fixed amount';

  @override
  String get lkcReasonPricePeriod =>
      'A sold price doesn\'t bill its plan\'s period';

  @override
  String get lkcReasonProductId => 'Empty or padded product id';

  @override
  String get lkcReasonProductInUse =>
      'A product of live subscriptions keeps its plan';

  @override
  String get lkcReasonProductPlans => 'A product maps to one plan only';

  @override
  String get lkcReasonPurchaseAccount => 'Purchase belongs to another account';

  @override
  String get lkcReasonPushAccount => 'Unexpected push account';

  @override
  String get lkcReasonSamePlan => 'Already on this plan';

  @override
  String get lkcReasonSoldTwice => 'One sold price per plan and provider';

  @override
  String get lkcReasonSwitchSync =>
      'Saved, but Stripe\'s plan switching couldn\'t be updated; save again';

  @override
  String get lkcReasonTestPurchase => 'Test purchases are not accepted';

  @override
  String get lkcReasonTransactionAccount =>
      'Transaction belongs to another account';

  @override
  String get lkcReasonUnavailable => 'Not available';

  @override
  String get lkcReasonUnknownPackage => 'Unknown package';

  @override
  String get lkcReasonUploadSize =>
      'The uploaded file is missing or not of the announced size';

  @override
  String get lkcReasonUploadUnknown => 'No such upload, or it expired';

  @override
  String get lkcReasonUserGone => 'The user no longer exists';

  @override
  String lkcRenewsOn(String date) {
    return 'Renews on $date';
  }

  @override
  String get lkcSignInBrowser => 'Sign in in the browser';

  @override
  String get lkcSignInTip =>
      'Sign in with your lollipopkit account to see your plans and files.';

  @override
  String get lkcStoreSubscriptionTip =>
      'You have a subscription billed by the App Store or Google Play. Cancel it in the store first: deleting the account doesn’t stop it.';

  @override
  String get lkcSubscribe => 'Subscribe';

  @override
  String lkcUsageOf(String used, String quota) {
    return '$used of $quota';
  }

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => 'Local';

  @override
  String get location => 'Location';

  @override
  String get log => 'Log';

  @override
  String get login => 'Log in';

  @override
  String get loginTip => 'No registration required, free to use.';

  @override
  String get logout => 'Logout';

  @override
  String get logs => 'Logs';

  @override
  String get loss => 'loss';

  @override
  String get manual => 'Manual';

  @override
  String get max => 'Maximum';

  @override
  String get memory => 'Memory';

  @override
  String get menuHelp => 'Help';

  @override
  String get menuInfo => 'Info';

  @override
  String get menuNavigate => 'Navigate';

  @override
  String get menuQuit => 'Quit';

  @override
  String get menuSettings => 'Setting';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get migrateCfg => 'Configuration migration';

  @override
  String get migrateCfgTip => 'To adapt to the required new configuration';

  @override
  String get milliseconds => 'Milliseconds';

  @override
  String get min => 'Minimum';

  @override
  String get minute => 'Minutes';

  @override
  String get mission => 'Mission';

  @override
  String get mode => 'Mode';

  @override
  String get more => 'More';

  @override
  String get moveDown => 'Move Down';

  @override
  String get moveUp => 'Move Up';

  @override
  String get ms => 'ms';

  @override
  String get name => 'Name';

  @override
  String get net => 'Network';

  @override
  String get network => 'Network';

  @override
  String get next => 'Next';

  @override
  String get node => 'Node';

  @override
  String get none => 'None';

  @override
  String get notAvailable => 'Unavailable';

  @override
  String notExistFmt(Object file) {
    return '$file not exist';
  }

  @override
  String get note => 'Note';

  @override
  String get ok => 'Okay';

  @override
  String get opacity => 'Opacity';

  @override
  String get open => 'Open';

  @override
  String get optional => 'Optional';

  @override
  String get paste => 'Paste';

  @override
  String get path => 'Path';

  @override
  String get permission => 'Permission';

  @override
  String get permissionDenied => 'Permission denied.';

  @override
  String get pingAvg => 'Avg:';

  @override
  String get pkg => 'Pkg';

  @override
  String get port => 'Port';

  @override
  String get portForward => 'Port Forward';

  @override
  String get preview => 'Preview';

  @override
  String get previous => 'Previous';

  @override
  String get primaryColorSeed => 'Primary color seed';

  @override
  String get process => 'Process';

  @override
  String get prune => 'Prune';

  @override
  String get pwd => 'Password';

  @override
  String get pwdTip =>
      'Length 6-32, can be English letters, numbers, and punctuation';

  @override
  String get read => 'Read';

  @override
  String get ready => 'Ready';

  @override
  String get reboot => 'Reboot';

  @override
  String get reconnecting => 'Reconnecting...';

  @override
  String get redo => 'Redo';

  @override
  String get refresh => 'Refresh';

  @override
  String get register => 'Sign up';

  @override
  String get remote => 'Remote';

  @override
  String get rename => 'Rename';

  @override
  String get replace => 'Replace';

  @override
  String get replaceAll => 'Replace all';

  @override
  String get reset => 'Reset';

  @override
  String get restart => 'Restart';

  @override
  String get restore => 'Restore';

  @override
  String get result => 'Result';

  @override
  String get retry => 'Retry';

  @override
  String get route => 'Routing';

  @override
  String get run => 'Run';

  @override
  String get running => 'Running';

  @override
  String get save => 'Save';

  @override
  String get saveFailed => 'Save failed';

  @override
  String get saved => 'Saved';

  @override
  String get search => 'Search';

  @override
  String get second => 'Seconds';

  @override
  String get select => 'Select';

  @override
  String get sensors => 'Sensor';

  @override
  String get sequence => 'Sequence';

  @override
  String get server => 'Server';

  @override
  String get servers => 'Servers';

  @override
  String get setting => 'Settings';

  @override
  String get share => 'Share';

  @override
  String get shutdown => 'Shutdown';

  @override
  String get size => 'Size';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'Content too large, displaying only the first $bytes';
  }

  @override
  String get snippet => 'Snippet';

  @override
  String get softWrap => 'Soft wrap';

  @override
  String get sort => 'Sort';

  @override
  String get sortByName => 'By name';

  @override
  String get source => 'Source';

  @override
  String get speed => 'Speed';

  @override
  String get start => 'Start';

  @override
  String get stat => 'Statistics';

  @override
  String get stats => 'Statistics';

  @override
  String get stop => 'Stop';

  @override
  String get stopped => 'Stopped';

  @override
  String get storage => 'Storage';

  @override
  String get success => 'Success';

  @override
  String get sudoPassword => 'sudo password';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => 'Suspend';

  @override
  String get switch_ => 'Switch';

  @override
  String get switcher => 'Switcher';

  @override
  String get sync => 'Synchronize';

  @override
  String get system => 'System';

  @override
  String get tag => 'Tag';

  @override
  String get tapToAuth => 'Click to verify';

  @override
  String get temperature => 'Temperature';

  @override
  String get terminal => 'Terminal';

  @override
  String get test => 'Test';

  @override
  String get textScaler => 'Text scaler';

  @override
  String get theme => 'Theme';

  @override
  String get themeMode => 'Theme mode';

  @override
  String get thinking => 'Thinking';

  @override
  String get time => 'Time';

  @override
  String get timedOut => 'Timed out';

  @override
  String get timeout => 'Timeout';

  @override
  String get times => 'Times';

  @override
  String get total => 'Total';

  @override
  String get totalAttempts => 'Total';

  @override
  String get traffic => 'Traffic';

  @override
  String get ttl => 'TTL';

  @override
  String get type => 'Type';

  @override
  String get undo => 'Undo';

  @override
  String get unknown => 'Unknown';

  @override
  String get unsupported => 'Not supported';

  @override
  String get update => 'Update';

  @override
  String get upload => 'Upload';

  @override
  String get uptime => 'Uptime';

  @override
  String get used => 'Used';

  @override
  String get user => 'User';

  @override
  String get valid => 'Valid';

  @override
  String get value => 'Value';

  @override
  String versionHasUpdate(Object build) {
    return 'Found: v1.0.$build, click to update';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return 'Current: v1.0.$build, click to check updates';
  }

  @override
  String versionUpdated(Object build) {
    return 'Current: v1.0.$build, is up to date';
  }

  @override
  String get view => 'View';

  @override
  String get viewErr => 'See error';

  @override
  String get write => 'Write';

  @override
  String get yesterday => 'Yesterday';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '1 second',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => 'Appearance';

  @override
  String get appearancePreset => 'Theme preset';

  @override
  String get appearanceThemeSchemaRange => 'Supported theme schema';

  @override
  String get appearanceThemeInstall => 'Install theme';

  @override
  String get appearanceThemeStore => 'Theme store';

  @override
  String get appearanceInvalidTheme => 'Invalid theme package or catalog';

  @override
  String get themeStoreRefreshFailed => 'Could not read the theme catalog.';

  @override
  String themeStoreDeleteTheme(String name) {
    return 'Delete “$name”? Its files are removed from this device. If it is the theme in use, the app returns to the default theme.';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return 'updated $ago';
  }

  @override
  String get themeStoreUpdatedJustNow => 'updated just now';

  @override
  String get themeStoreSortInUse => 'In use first';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return 'Want to make your own theme? [How to author one]($doc) — thank you for contributing!';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return 'Needs a newer app: $version';
  }

  @override
  String get appearanceFontFamilies => 'UI font families';

  @override
  String get appearanceFontFamiliesTip =>
      'One name per line; fonts are tried in order.';

  @override
  String get appearanceFontImport => 'Import UI font file';

  @override
  String get appearanceIcons => 'In-app icons';

  @override
  String get appearanceCorners => 'Corners';

  @override
  String get appearanceCardCorners => 'Card corners';

  @override
  String get appearanceTileCorners => 'Tile corners';

  @override
  String get appearanceButtonCorners => 'Button corners';

  @override
  String appearanceThemeModeLocked(String mode) {
    return 'This theme only supports $mode. Select another theme to change the mode.';
  }

  @override
  String get caseSensitive => 'Case sensitive';

  @override
  String get flashlight => 'Flashlight';

  @override
  String get regex => 'Regular expression';

  @override
  String get showPwd => 'Show password';

  @override
  String existsFmt(String name) {
    return '$name already exists';
  }

  @override
  String tooLargeFmt(String size) {
    return 'Larger than $size';
  }

  @override
  String get appearanceIconPack => 'Icon pack';

  @override
  String get appearanceIconPackTheme => 'Theme\'s icons';

  @override
  String get themeStoreThemes => 'Themes';

  @override
  String get themeStoreIconPacks => 'Icon packs';

  @override
  String themeStoreDeleteIconPack(String name) {
    return 'Delete “$name”? Its files are removed from this device. If it is the icon pack in use, the app returns to the theme\'s icons.';
  }
}
