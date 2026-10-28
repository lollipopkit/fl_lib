import 'dart:math' as math;

import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:fl_lib/src/core/lkc/model.dart';

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

/// The paywall's text of the benefits, from their amounts.
extension LkcBenefitLines on LkcBenefits {
  /// What [tier] (`free` or a plan id) grants in [line], a line each; a
  /// benefit not granted has none.
  List<String> lines(LibLocalizations l10n, String tier, LkcLine line) {
    int? of(LkcBenefit b) => amount(tier, b);

    final lines = <String>[];
    switch (line) {
      case LkcLine.storage:
        final bytes = of(LkcBenefit.fileBytes);
        if (bytes != 0) {
          final file = lkcBytes(lkcMaxFileBytes(of(LkcBenefit.fileMaxBytes)));
          lines.add(
            bytes == null
                ? l10n.lkcBenefitStorageUnlimited(file)
                : l10n.lkcBenefitStorage(lkcBytes(bytes), file),
          );
          lines.add(l10n.lkcBenefitShareLinks);
        }
      case LkcLine.basic:
        final kept = of(LkcBenefit.backupCount);
        if (kept != 0) {
          final total = of(LkcBenefit.backupTotalBytes);
          final app = of(LkcBenefit.backupAppBytes);
          lines.add(
            l10n.lkcBenefitBackups(
              switch (kept) {
                1 => l10n.lkcBenefitBackupLatest,
                null => l10n.lkcBenefitBackupRollingUnlimited,
                final int n => l10n.lkcBenefitBackupRolling(n),
              },
              // A cap without a row (0) is not set: backups are granted.
              switch ((total, app)) {
                (final int t, _) when t != 0 => l10n.lkcBenefitBackupTotalBytes(
                  lkcBytes(t),
                ),
                (_, final int a) when a != 0 => l10n.lkcBenefitBackupAppBytes(
                  lkcBytes(a),
                ),
                _ => l10n.lkcBenefitBackupNoLimit,
              },
            ),
          );
        }
        final rate = of(LkcBenefit.relayBytesPerSec);
        if (rate != 0) {
          lines.add(
            rate == null
                ? l10n.lkcBenefitRelayUnlimited
                : l10n.lkcBenefitRelay('${lkcBytes(rate)}/s'),
          );
        }
        final targets = of(LkcBenefit.uptimeTargets);
        if (targets != 0) {
          final secs = of(LkcBenefit.uptimeIntervalSecs);
          final minutes = secs == null || secs == 0
              ? null
              : math.max(1, (secs / 60).round());
          lines.add(switch ((minutes, targets)) {
            (null, null) => l10n.lkcBenefitUptimeTargetsUnlimited,
            (null, final int n) => l10n.lkcBenefitUptimeTargets(n),
            (final int m, null) => l10n.lkcBenefitUptimeUnlimited(m),
            (final int m, final int n) => l10n.lkcBenefitUptime(m, n),
          });
        }
        if (of(LkcBenefit.sync) != 0) lines.add(l10n.lkcBenefitSync);
      case LkcLine.conduit || LkcLine.unknown:
    }
    return lines;
  }
}
