/// What LK Cloud (homebase) answers with.
library;

import 'dart:math' as math;

/// A product line: a user holds at most one effective plan in each.
enum LkcLine {
  basic,
  storage,
  conduit,
  team,

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

  /// Billed by an app store: only the store can cancel it, not LK Cloud.
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

/// A plan of the catalog.
final class LkcPlan {
  final String id;
  final LkcLine line;

  /// Its place among the plans of [line], the higher the more it grants.
  final int rank;
  final LkcPeriod period;

  /// A brand name, shown untranslated.
  final String? name;

  /// Web checkouts available for the plan, in order of preference.
  final List<LkcPrice> web;

  const LkcPlan({
    required this.id,
    required this.line,
    this.rank = 0,
    required this.period,
    this.name,
    required this.web,
  });

  /// The Stripe price, the one [LkcClient.openCheckout] sells.
  LkcPrice? get stripe =>
      web.where((p) => p.source == LkcSource.stripe).firstOrNull;

  factory LkcPlan.fromJson(Map<String, dynamic> json) => LkcPlan(
    id: json['id'] as String,
    line: _byName(LkcLine.values, json['line']) ?? LkcLine.unknown,
    rank: (json['rank'] as num?)?.toInt() ?? 0,
    period: _byName(LkcPeriod.values, json['period']) ?? LkcPeriod.unknown,
    name: json['name'] as String?,
    web: [
      for (final p in json['web'] as List? ?? const [])
        LkcPrice.fromJson(p as Map<String, dynamic>),
    ],
  );
}

/// The plans on sale and the names of the lines: GET /v2/billing/plans.
final class LkcCatalog {
  /// In display order.
  final List<LkcPlan> plans;

  /// Brand names by line id, in display order.
  final Map<String, String> lines;

  /// The name of having no plan.
  final String? freeName;

  const LkcCatalog({required this.plans, this.lines = const {}, this.freeName});

  factory LkcCatalog.fromJson(Object? json) => switch (json) {
    // TODO: rm once no homebase answering a bare plan list is served.
    final List<Object?> plans => LkcCatalog(plans: _plans(plans)),
    final Map<String, dynamic> json => LkcCatalog(
      plans: _plans(json['plans'] as List? ?? const []),
      lines: {
        for (final l in json['lines'] as List? ?? const [])
          (l as Map<String, dynamic>)['id'] as String: l['name'] as String,
      },
      freeName: (json['free'] as Map<String, dynamic>?)?['name'] as String?,
    ),
    _ => throw FormatException('Not a catalog: ${json.runtimeType}'),
  };

  static List<LkcPlan> _plans(List<Object?> list) => [
    for (final p in list) LkcPlan.fromJson(p as Map<String, dynamic>),
  ];

  LkcPlan? plan(String id) => plans.where((p) => p.id == id).firstOrNull;
}

/// Names from the catalog; the ids while it hasn't been read.
extension LkcCatalogNames on LkcCatalog? {
  String lineName(String line) => this?.lines[line] ?? line;

  String planName(String plan) => this?.plan(plan)?.name ?? plan;
}

/// The largest file one upload sends: the object store's limit, no plan's.
const lkcStoreMaxFileBytes = 5000000000;

/// The largest file of a directory's `max_file_bytes`: the store caps it.
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

/// A device registered for push notifications.
final class LkcDevice {
  final String id;

  /// `ios`.
  final String platform;

  /// The APNs topic: the app's bundle id.
  final String appId;

  /// Registered with APNs' development environment.
  final bool sandbox;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const LkcDevice({
    required this.id,
    required this.platform,
    required this.appId,
    required this.sandbox,
    required this.createdAt,
    required this.lastSeenAt,
  });

  factory LkcDevice.fromJson(Map<String, dynamic> json) => LkcDevice(
    id: '${json['id']}',
    platform: json['platform'] as String,
    appId: json['app_id'] as String,
    sandbox: json['sandbox'] as bool? ?? false,
    createdAt: DateTime.parse(json['created_at'] as String),
    lastSeenAt: DateTime.parse(json['last_seen_at'] as String),
  );
}

const _units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];

/// [bytes] in powers of 1024, as homebase words the plans: `5 GiB`, `9.5 MiB`.
String lkcBytes(int bytes) {
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < _units.length - 1) {
    v /= 1024;
    i++;
  }
  if (i == 0) return '$bytes ${_units[i]}';
  var text = v.toStringAsFixed(v < 10 ? 1 : 0);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_units[i]}';
}

/// One row of the paywall, worded and formatted by homebase.
final class LkcPaywallItem {
  /// A Material icon's name (`sync`, `backup`, …); one this build doesn't
  /// know shows a generic icon.
  final String icon;
  final String title;
  final String? detail;

  const LkcPaywallItem({required this.icon, required this.title, this.detail});

  factory LkcPaywallItem.fromJson(Map<String, dynamic> json) => LkcPaywallItem(
    icon: json['icon'] as String? ?? '',
    title: json['title'] as String,
    detail: json['detail'] as String?,
  );

  @override
  String toString() => detail == null ? title : '$title: $detail';
}

/// What each line's plans grant, as homebase words it in [locale]:
/// GET /v2/billing/paywall. Shown as it is: the limits are homebase's.
final class LkcPaywall {
  /// The tier of a line without a plan.
  static const free = 'free';

  /// The locale homebase answered in, which may be a fallback of the one asked.
  final String locale;

  /// Line ids in homebase's order.
  final List<String> lines;

  /// Rows by line, then by tier (`free` or a plan id).
  final Map<String, Map<String, List<LkcPaywallItem>>> rows;

  const LkcPaywall({
    required this.locale,
    required this.lines,
    required this.rows,
  });

  factory LkcPaywall.fromJson(Map<String, dynamic> json) {
    final lines = <String>[];
    final items = <String, Map<String, List<LkcPaywallItem>>>{};
    for (final l in (json['lines'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final line = l['line'] as String;
      lines.add(line);
      items[line] = {
        for (final t in (l['tiers'] as List? ?? const []).cast<Map<String, dynamic>>())
          t['tier'] as String: [
            for (final i in t['items'] as List? ?? const [])
              LkcPaywallItem.fromJson(i as Map<String, dynamic>),
          ],
      };
    }
    return LkcPaywall(
      locale: json['locale'] as String? ?? '',
      lines: lines,
      rows: items,
    );
  }

  /// What [tier] of [line] grants; none for a tier homebase doesn't list.
  List<LkcPaywallItem> items(String line, String tier) =>
      rows[line]?[tier] ?? const [];
}
