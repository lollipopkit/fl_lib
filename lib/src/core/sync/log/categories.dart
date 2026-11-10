import 'package:fl_lib/src/core/store/iface.dart';
import 'package:flutter/foundation.dart';

/// What a person chose to sync beside the records every sync carries, each
/// its own switch on this device.
final class SyncCategory {
  const SyncCategory({required this.name, required this.pref, required this.collections, this.also = const [], this.extra});

  /// For logs and the app's labels.
  final String name;

  /// This device's switch.
  final PrefPropDefault<bool> pref;

  /// The collections it covers (`kv:<store>`, a kind's).
  final Set<String> collections;

  /// Other switches [extra] reads, to listen to.
  final List<Listenable> also;

  /// Whether it is on besides [pref] (ServerBox's passphrases also need them
  /// kept here).
  final bool Function()? extra;

  bool get on => pref.get() && (extra?.call() ?? true);

  Listenable get changes => Listenable.merge([pref.listenable(), ...also]);
}

/// The app's categories ([define]); a collection none covers is always
/// carried.
abstract final class SyncCategories {
  static List<SyncCategory> values = const [];

  static void define(List<SyncCategory> categories) => values = categories;

  /// The category of a record of collection [c]; null for one every sync
  /// carries.
  static SyncCategory? of(String c) {
    for (final cat in values) {
      if (cat.collections.contains(c)) return cat;
    }
    return null;
  }

  /// Whether records of [c] are sent and taken now.
  static bool carries(String c) => of(c)?.on ?? true;

  /// The collections not sent or taken now.
  static Set<String> notCarried() => {
    for (final cat in values)
      if (!cat.on) ...cat.collections,
  };

  static Set<SyncCategory> get onNow => {
    for (final c in values)
      if (c.on) c,
  };

  /// Any switch changing.
  static Listenable get changes => Listenable.merge([for (final c in values) c.changes]);
}
