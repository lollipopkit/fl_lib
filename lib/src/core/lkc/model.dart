/// What LKC Cloud (homebase) answers with.
library;

/// A product line: a user holds at most one effective plan in each.
enum LkcLine {
  basic,
  storage,
  conduit,

  /// A line this build doesn't know.
  unknown;

  /// The line of a plan id: `basic`, `storage.plus`, `conduit.pro`, …
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

/// Who granted a manual subscription, and until when it renews (for good when null).
final class LkcGrant {
  final String by;
  final DateTime? endsAt;

  const LkcGrant({required this.by, this.endsAt});

  factory LkcGrant.fromJson(Map<String, dynamic> json) =>
      LkcGrant(by: json['by'] as String, endsAt: _date(json['ends_at']));
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
  final LkcGrant? grant;

  const LkcEntitlement({
    required this.plan,
    required this.source,
    required this.status,
    required this.cancelScheduled,
    this.periodStart,
    this.periodEnd,
    this.grant,
  });

  LkcLine get line => LkcLine.ofPlan(plan);

  factory LkcEntitlement.fromJson(Map<String, dynamic> json) => LkcEntitlement(
    plan: json['plan'] as String,
    source: _byName(LkcSource.values, json['source']) ?? LkcSource.unknown,
    status: _byName(LkcStatus.values, json['status']) ?? LkcStatus.unknown,
    periodStart: _date(json['period_start']),
    periodEnd: _date(json['period_end']),
    cancelScheduled: json['cancel_scheduled'] as bool? ?? false,
    grant: switch (json['grant']) {
      final Map<String, dynamic> g => LkcGrant.fromJson(g),
      _ => null,
    },
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
