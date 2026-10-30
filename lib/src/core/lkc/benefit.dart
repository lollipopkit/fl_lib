import 'dart:math' as math;

import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:fl_lib/src/core/lkc/model.dart';
import 'package:intl/intl.dart';

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// [bytes] in powers of 1000, as storage is sold: `5 GB`, `9.5 MB`.
String lkcBytes(int bytes) {
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1000 && i < _units.length - 1) {
    v /= 1000;
    i++;
  }
  if (i == 0) return '$bytes ${_units[i]}';
  var text = v.toStringAsFixed(v < 10 ? 1 : 0);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_units[i]}';
}

/// What a benefit is, for its icon.
enum LkcBenefitKind {
  backups,
  relay,
  uptime,
  sync,
  storage,
  shareLinks,
  credit,
  concurrency,
}

/// One benefit as a row shows it: a name, and what it amounts to.
final class LkcBenefitItem {
  final LkcBenefitKind kind;
  final String title;
  final String detail;

  const LkcBenefitItem(this.kind, this.title, this.detail);

  @override
  String toString() => '$title: $detail';
}

/// The paywall's text of the benefits, from their amounts.
extension LkcBenefitItems on LkcBenefits {
  /// What [tier] (`free` or a plan id) grants in [line]; a benefit not
  /// granted has no item. Conduit's are its plan's limits: [lkcConduitItems].
  List<LkcBenefitItem> items(LibLocalizations l10n, String tier, LkcLine line) {
    int? of(LkcBenefit b) => amount(tier, b);
    final items = <LkcBenefitItem>[];
    switch (line) {
      case LkcLine.storage:
        final bytes = of(LkcBenefit.fileBytes);
        if (bytes != 0) {
          final file = lkcBytes(lkcMaxFileBytes(of(LkcBenefit.fileMaxBytes)));
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.storage,
              'WebDAV',
              l10n.lkcBenefitStorageDetail(file),
            ),
          );
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.shareLinks,
              l10n.lkcBenefitShareLinks,
              l10n.lkcBenefitShareLinksDetail,
            ),
          );
        }
      case LkcLine.basic:
        final kept = of(LkcBenefit.backupCount);
        if (kept != 0) {
          final total = of(LkcBenefit.backupTotalBytes);
          final app = of(LkcBenefit.backupAppBytes);
          final detail = l10n.lkcBenefitBackupsDetail(
            switch (kept) {
              1 => l10n.lkcBenefitBackupsLatest,
              null => l10n.lkcBenefitBackupsRollingUnlimited,
              final int n => l10n.lkcBenefitBackupsRolling(n),
            },
            // A cap without a row (0) is not set: backups are granted.
            switch ((total, app)) {
              (final int t, _) when t != 0 => l10n.lkcBenefitBackupsTotalBytes(
                lkcBytes(t),
              ),
              (_, final int a) when a != 0 => l10n.lkcBenefitBackupsAppBytes(
                lkcBytes(a),
              ),
              _ => l10n.lkcBenefitBackupsNoLimit,
            },
          );
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.backups,
              l10n.lkcBenefitBackups,
              detail,
            ),
          );
        }
        final rate = of(LkcBenefit.relayBytesPerSec);
        if (rate != 0) {
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.relay,
              l10n.lkcBenefitRelay,
              rate == null
                  ? l10n.lkcBenefitRelayUnlimited
                  : l10n.lkcBenefitRelayDetail('${lkcBytes(rate)}/s'),
            ),
          );
        }
        final targets = of(LkcBenefit.uptimeTargets);
        if (targets != 0) {
          final secs = of(LkcBenefit.uptimeIntervalSecs);
          final minutes = secs == null || secs == 0
              ? null
              : math.max(1, (secs / 60).round());
          final detail = switch ((minutes, targets)) {
            (null, null) => l10n.lkcBenefitUptimeTargetsUnlimited,
            (null, final int n) => l10n.lkcBenefitUptimeTargets(n),
            (final int m, null) => l10n.lkcBenefitUptimeUnlimited(m),
            (final int m, final int n) => l10n.lkcBenefitUptimeDetail(m, n),
          };
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.uptime,
              l10n.lkcBenefitUptime,
              detail,
            ),
          );
        }
        if (of(LkcBenefit.sync) != 0) {
          items.add(
            LkcBenefitItem(
              LkcBenefitKind.sync,
              l10n.lkcBenefitSync,
              l10n.lkcBenefitSyncDetail,
            ),
          );
        }
      case LkcLine.conduit || LkcLine.unknown:
    }
    return items;
  }
}

/// What a Conduit plan grants, from the limits Conduit publishes.
List<LkcBenefitItem> lkcConduitItems(
  LibLocalizations l10n,
  LkcConduitLimits limits,
) {
  final credit = NumberFormat.simpleCurrency(name: 'USD')
      .format(limits.creditNanoUsd / 1e9);
  final concurrency = limits.concurrency;
  return [
    LkcBenefitItem(
      LkcBenefitKind.credit,
      l10n.lkcConduitCredit,
      switch (limits.period) {
        'monthly' => l10n.lkcConduitCreditMonthly(credit),
        'weekly' => l10n.lkcConduitCreditWeekly(credit),
        // A period this build doesn't know, passed on as Conduit names it.
        final period => '$credit / $period',
      },
    ),
    LkcBenefitItem(
      LkcBenefitKind.concurrency,
      l10n.lkcConduitConcurrency,
      concurrency == null
          ? l10n.lkcUnlimited
          : l10n.lkcConduitConcurrencyDetail(concurrency),
    ),
  ];
}
