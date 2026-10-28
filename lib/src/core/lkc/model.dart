/// What LKC Cloud (homebase) answers with.
library;

import 'dart:math' as math;

/// A product line: a user holds at most one effective plan in each.
enum LkcLine {
  basic,
  storage,
  conduit,

  /// A line this build doesn't know.
  unknown;

  /// The line of a plan id: `basic`, `storage.plus`, `conduit.pro`, …
  // TODO: rm once no homebase older than its `line` field is served.
  static LkcLine ofPlan(String plan) =>
      _byName(values, plan.split('.').first) ?? unknown;
}

/// Where a subscription is billed.
enum LkcSource {
  stripe,
  paddle,
  apple,
  google,

  /// Granted by an admin or a code.
  manual,
  unknown;

  /// Billed by an app store: only the store can cancel it, not LKC Cloud.
  bool get isStore => this == apple || this == google;
}

enum LkcStatus {
  active,
  pastDue,
  paused,

  /// Ended, grants nothing.
  canceled,
  unknown;

  /// Whether the subscription grants its plan.
  bool get grants => this == active || this == pastDue;
}

enum LkcPeriod { month, year, unknown }

final class LkcUser {
  final String id;
  final String name;

  /// `user`, `admin`, `bot`, …
  final String group;
  final String? avatar;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LkcUser({
    required this.id,
    required this.name,
    required this.group,
    required this.createdAt,
    required this.updatedAt,
    this.avatar,
  });

  factory LkcUser.fromJson(Map<String, dynamic> json) => LkcUser(
    id: json['id'] as String,
    name: json['name'] as String,
    group: json['group'] as String,
    avatar: json['avatar'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

/// A subscription of the user.
final class LkcEntitlement {
  /// The plan id, such as `storage.plus`.
  final String plan;
  final LkcSource source;
  final LkcStatus status;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  /// It ends at [periodEnd] instead of renewing.
  final bool cancelScheduled;
  final LkcLine line;

  const LkcEntitlement({
    required this.plan,
    required this.line,
    required this.source,
    required this.status,
    required this.cancelScheduled,
    this.periodStart,
    this.periodEnd,
  });

  factory LkcEntitlement.fromJson(Map<String, dynamic> json) => LkcEntitlement(
    plan: json['plan'] as String,
    line: json.containsKey('line')
        ? _byName(LkcLine.values, json['line']) ?? LkcLine.unknown
        : LkcLine.ofPlan(json['plan'] as String),
    source: _byName(LkcSource.values, json['source']) ?? LkcSource.unknown,
    status: _byName(LkcStatus.values, json['status']) ?? LkcStatus.unknown,
    periodStart: _date(json['period_start']),
    periodEnd: _date(json['period_end']),
    cancelScheduled: json['cancel_scheduled'] as bool? ?? false,
  );
}

/// A web checkout price of a plan.
final class LkcPrice {
  final LkcSource source;

  /// In the currency's minor unit, tax excluded.
  final int amount;

  /// ISO 4217, lower case as the provider gives it.
  final String currency;

  const LkcPrice({
    required this.source,
    required this.amount,
    required this.currency,
  });

  factory LkcPrice.fromJson(Map<String, dynamic> json) => LkcPrice(
    source: _byName(LkcSource.values, json['source']) ?? LkcSource.unknown,
    amount: (json['amount'] as num).toInt(),
    currency: json['currency'] as String,
  );
}

/// What a Conduit plan grants.
final class LkcConduitLimits {
  /// How often the credit is granted: `monthly`, `weekly`, or one this build doesn't know.
  final String period;

  /// Credit per [period], in billionths of a US dollar.
  final int creditNanoUsd;

  /// Requests in flight across all of a subscriber's keys, null when uncapped.
  final int? concurrency;

  const LkcConduitLimits({
    required this.period,
    required this.creditNanoUsd,
    this.concurrency,
  });

  factory LkcConduitLimits.fromJson(Map<String, dynamic> json) =>
      LkcConduitLimits(
        period: json['period'] as String,
        creditNanoUsd: (json['credit_nano_usd'] as num).toInt(),
        concurrency: (json['concurrency'] as num?)?.toInt(),
      );
}

/// A plan of the catalog.
final class LkcPlan {
  final String id;
  final LkcLine line;
  final LkcPeriod period;

  /// Web checkouts available for the plan, in order of preference.
  final List<LkcPrice> web;

  /// Absent for plans of other lines, or while Conduit hasn't told.
  final LkcConduitLimits? limits;

  const LkcPlan({
    required this.id,
    required this.line,
    required this.period,
    required this.web,
    this.limits,
  });

  /// The Stripe price, the one [LkcClient.openCheckout] sells.
  LkcPrice? get stripe =>
      web.where((p) => p.source == LkcSource.stripe).firstOrNull;

  factory LkcPlan.fromJson(Map<String, dynamic> json) => LkcPlan(
    id: json['id'] as String,
    line: _byName(LkcLine.values, json['line']) ?? LkcLine.unknown,
    period: _byName(LkcPeriod.values, json['period']) ?? LkcPeriod.unknown,
    web: [
      for (final p in json['web'] as List? ?? const [])
        LkcPrice.fromJson(p as Map<String, dynamic>),
    ],
    limits: switch (json['limits']) {
      final Map<String, dynamic> l => LkcConduitLimits.fromJson(l),
      _ => null,
    },
  );
}

/// The largest file one upload sends: the object store's limit, no plan's.
const lkcStoreMaxFileBytes = 5000000000;

/// Something a plan grants an amount of.
enum LkcBenefit {
  /// Bytes of files a directory holds.
  fileBytes('file.bytes'),

  /// Files a directory holds.
  fileCount('file.count'),

  /// Bytes of one file, at most [lkcStoreMaxFileBytes].
  fileMaxBytes('file.max_bytes'),

  /// Backups kept per app.
  backupCount('backup.count'),

  /// Bytes of one app's backups.
  backupAppBytes('backup.app_bytes'),

  /// Bytes of all apps' backups.
  backupTotalBytes('backup.total_bytes'),

  /// Targets checked from outside.
  uptimeTargets('uptime.targets'),

  /// Seconds between two checks of a target.
  uptimeIntervalSecs('uptime.interval_secs'),

  /// Relay bandwidth, bytes per second.
  relayBytesPerSec('relay.bytes_per_sec'),

  /// Real-time sync across devices: 1 on, 0 off.
  sync('sync');

  /// How homebase names it.
  final String key;

  const LkcBenefit(this.key);

  /// The line whose plan grants it.
  LkcLine get line => switch (this) {
    fileBytes || fileCount || fileMaxBytes => LkcLine.storage,
    _ => LkcLine.basic,
  };

  static LkcBenefit? of(String key) =>
      values.where((b) => b.key == key).firstOrNull;
}

/// What every plan grants, and having none: GET /v2/billing/benefits.
final class LkcBenefits {
  /// The tier of a line without a plan.
  static const free = 'free';

  /// Amounts by tier (`free` or a plan id), null being unlimited.
  final Map<String, Map<LkcBenefit, int?>> _tiers;

  const LkcBenefits(this._tiers);

  factory LkcBenefits.fromJson(List<dynamic> json) {
    final tiers = <String, Map<LkcBenefit, int?>>{};
    for (final row in json.cast<Map<String, dynamic>>()) {
      // One this build doesn't know grants nothing it can tell of.
      final benefit = LkcBenefit.of(row['benefit'] as String);
      if (benefit == null) continue;
      tiers.putIfAbsent(row['tier'] as String, () => {})[benefit] =
          (row['value'] as num?)?.toInt();
    }
    return LkcBenefits(tiers);
  }

  /// What [tier] grants of [benefit]: null is unlimited, 0 is not granted.
  int? amount(String tier, LkcBenefit benefit) {
    final amounts = _tiers[tier];
    if (amounts == null || !amounts.containsKey(benefit)) return 0;
    return amounts[benefit];
  }
}

/// The largest file of a `file.max_bytes` amount: the store caps it.
int lkcMaxFileBytes(int? amount) => amount == null
    ? lkcStoreMaxFileBytes
    : math.min(amount, lkcStoreMaxFileBytes);

/// What a directory's files take, and what it may hold: GET /file/usage.
final class LkcUsage {
  final int files;
  final int bytes;

  /// Null is unlimited.
  final int? quotaFiles;
  final int? quotaBytes;

  /// Bytes of one file, null being [lkcStoreMaxFileBytes].
  final int? quotaMaxFileBytes;

  const LkcUsage({
    required this.files,
    required this.bytes,
    this.quotaFiles,
    this.quotaBytes,
    this.quotaMaxFileBytes,
  });

  /// The largest file the directory takes.
  int get maxFileBytes => lkcMaxFileBytes(quotaMaxFileBytes);

  factory LkcUsage.fromJson(Map<String, dynamic> json) {
    final quota = json['quota'] as Map<String, dynamic>? ?? const {};
    return LkcUsage(
      files: (json['files'] as num).toInt(),
      bytes: (json['bytes'] as num).toInt(),
      quotaFiles: (quota['files'] as num?)?.toInt(),
      quotaBytes: (quota['bytes'] as num?)?.toInt(),
      quotaMaxFileBytes: (quota['max_file_bytes'] as num?)?.toInt(),
    );
  }
}

/// A stored file.
final class LkcFile {
  /// The stored name, which requests address the file by.
  final String name;

  /// The name the user uploaded it as.
  final String? originalName;
  final String? mime;
  final int size;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LkcFile({
    required this.name,
    required this.size,
    required this.createdAt,
    required this.updatedAt,
    this.originalName,
    this.mime,
  });

  /// The name to show.
  String get displayName => originalName ?? name;

  factory LkcFile.fromJson(Map<String, dynamic> json) => LkcFile(
    name: json['name'] as String,
    originalName: json['original_name'] as String?,
    mime: json['mime'] as String?,
    size: (json['size'] as num).toInt(),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

/// A presigned URL. It authorizes whoever holds it: keep it out of logs.
final class LkcLink {
  final Uri url;
  final DateTime expiresAt;

  const LkcLink({required this.url, required this.expiresAt});

  factory LkcLink.fromJson(Map<String, dynamic> json) => LkcLink(
    url: Uri.parse(json['url'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
  );
}

/// An upload the server holds a name and the quota for.
final class LkcUpload {
  final String id;

  /// The name the file will be stored as.
  final String name;

  /// PUT exactly the announced size here, starting within 15 minutes.
  final Uri url;
  final DateTime expiresAt;

  const LkcUpload({
    required this.id,
    required this.name,
    required this.url,
    required this.expiresAt,
  });

  factory LkcUpload.fromJson(Map<String, dynamic> json) => LkcUpload(
    id: json['id'] as String,
    name: json['name'] as String,
    url: Uri.parse(json['url'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
  );
}

DateTime? _date(Object? v) => v is String ? DateTime.parse(v) : null;

/// The value named [name] in snake_case.
T? _byName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  final camel = name.replaceAllMapped(
    RegExp(r'_(\w)'),
    (m) => m[1]!.toUpperCase(),
  );
  return values.where((v) => v.name == camel).firstOrNull;
}
