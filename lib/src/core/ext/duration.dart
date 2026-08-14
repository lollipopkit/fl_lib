import 'package:fl_lib/src/res/l10n.dart';

/// Extensions on [Duration] for localized formatting.

extension DurationX on Duration {
  /// Returns a concise localized string for this duration's absolute value.
  ///
  /// Example outputs: `2 day`, `3 hour`, `15 minute`, `42 second`.
  String get toAgoStr {
    final abs_ = abs();
    final days = abs_.inDays;
    if (days > 0) {
      return '$days ${l10n.day}';
    }
    final hours = abs_.inHours;
    if (hours > 0) {
      return '$hours ${l10n.hour}';
    }
    final minutes = abs_.inMinutes;
    if (minutes > 0) {
      return '$minutes ${l10n.minute}';
    }
    final seconds = abs_.inSeconds;
    return '$seconds ${l10n.second}';
  }
}

extension DateTimeAgoX on DateTime {
  /// How long ago this was, in words: `Just now`, `5 minutes ago`.
  ///
  /// Anything inside [justNowBelow] reads as "just now" rather than a count of
  /// seconds — a list of things touched moments apart should not look like a
  /// stopwatch.
  String toAgoStr({
    DateTime? now,
    Duration justNowBelow = const Duration(minutes: 1),
  }) {
    // `difference` on a timestamp from the future is negative, and
    // [DurationX.toAgoStr] takes the absolute value; treating that as "just
    // now" is the honest reading of a clock that moved.
    final elapsed = (now ?? DateTime.now()).difference(this);
    if (elapsed < justNowBelow) return l10n.justNow;
    return l10n.agoFmt(elapsed.toAgoStr);
  }
}
