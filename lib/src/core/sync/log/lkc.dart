import 'dart:async';
import 'dart:math';

import 'package:fl_lib/src/core/lkc/client.dart';
import 'package:fl_lib/src/core/logger.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/log/groups.dart';
import 'package:fl_lib/src/core/sync/log/errors.dart';
import 'package:fl_lib/src/core/sync/log/host.dart';
import 'package:fl_lib/src/core/sync/log/keys.dart';
import 'package:fl_lib/src/core/sync/log/recorder.dart';
import 'package:fl_lib/src/rust/api/lkc.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The key file's name beside the log.
const lkcKeyFileName = 'identity.age';

/// The operation-log sync on an app's LK Cloud log while [enabled]: on this
/// device's edits (after [_debounce]), on another device's batch
/// ([LkcSyncWatch]), and on every (re)connection, which may have missed some.
final class LkcLogSync {
  LkcLogSync({required this.client, required this.app, required this.enabled});

  final LkcClient client;

  /// Homebase's name for the app (`serverbox`, `llmbox`); permanent.
  final String app;

  /// Whether the app syncs to LK Cloud on this device.
  final ValueListenable<bool> enabled;

  static const _debounce = Duration(milliseconds: 500);

  Future<SyncLogEngine>? _opening;
  Timer? _soon;

  /// The account whose key was read last.
  String? _account;

  /// Whether the last read stopped at a newer build's batch.
  final tooNew = ValueNotifier(false);

  /// What the last run ended with, null when it went through: shown as the
  /// sync's failure.
  final lastFailure = ValueNotifier<Object?>(null);

  /// A run is going on.
  final running = ValueNotifier(false);

  /// When a run last went through.
  final lastSyncAt = ValueNotifier<DateTime?>(null);

  bool get _wanted => client.signedIn && client.user.value != null && enabled.value;

  final _host = SyncHost();

  void init() {
    SyncRecorder.onLocal.add(() {
      if (!_wanted) return;
      _soon?.cancel();
      _soon = Timer(_debounce, () => unawaited(sync()));
    });
    // A category carried or not: the log is read again from its start, and
    // everything here sent, so neither side misses what was left out.
    SyncGroups.changes.addListener(() {
      if (!SqliteDb.isOpen) return;
      final opening = _opening;
      if (opening == null) {
        unawaited(SyncLogEngine.forget(host: _host.call));
        return;
      }
      unawaited(opening.then((s) => s.reset()).then((_) => sync(), onError: (Object _) => SyncLogEngine.forget(host: _host.call)));
    });
    // Signed out, or in as someone else: the next run opens anew, and what
    // this device knew of the account before goes.
    // Read again (a refresh) as the same account: nothing changed.
    var user = client.user.value?.id;
    client.user.addListener(() {
      final now = client.user.value?.id;
      if (now == user) return;
      user = now;
      final was = _account;
      if (was != null && was != now) unawaited(SyncKeyring.forget(was));
      reset();
      unawaited(sync());
    });
    // Not only on the event stream connecting: a device whose network keeps
    // it from listening still sends what was edited while sync was off.
    enabled.addListener(() {
      if (!enabled.value) reset();
      unawaited(sync());
    });
    unawaited(sync());
  }

  /// Reads what other devices sent, then sends what this one has.
  Future<void> sync() => _run((s) => s.run());

  /// Reads what other devices sent, when the log at [seq] has any not read
  /// here (this device's own append is announced too).
  Future<void> pull(int seq) => _run((s) async {
    if (await s.behind(seq: seq)) await s.pull();
  });

  /// Another device wrote the account's key file: checked again now.
  Future<void> keyChanged() async {
    if (!_wanted) return;
    try {
      await syncCall(() async => (await key()).check(force: true));
    } catch (e, s) {
      if (e is! SyncPasswordMismatch) Loggers.app.warning('LK Cloud sync key', e, s);
      return;
    }
    await sync();
  }

  Future<void> _run(Future<void> Function(SyncLogEngine) run) async {
    if (!_wanted) return;
    final SyncLogEngine engine;
    final opening = _opening ??= _open();
    try {
      engine = await opening;
      // The password still opens the key: nothing syncs while it does not.
      await key();
    } catch (e, s) {
      // Opened again next time: the key, the password or the network may be
      // there by then. Only this one: another may have taken its place meanwhile.
      if (identical(_opening, opening)) _opening = null;
      lastFailure.value = e;
      if (e is! SyncPasswordMismatch && e is! SyncPasswordMissing) {
        Loggers.app.warning('LK Cloud log sync: opening', e, s);
      }
      return;
    }
    running.value = true;
    try {
      await syncCall(() => run(engine));
      lastFailure.value = null;
      lastSyncAt.value = DateTime.now();
    } catch (e, s) {
      lastFailure.value = e;
      if (e is! SyncRefused && !(e is SyncError && e.kind == SyncEngineErrorKind.remote)) {
        Loggers.app.warning('LK Cloud log sync', e, s);
      }
    } finally {
      tooNew.value = engine.tooNew();
      running.value = false;
    }
  }

  Future<SyncLogEngine> _open() async {
    final user = client.user.value;
    if (user == null) throw const LkcException(code: LkcCode.perm, reason: 'signed_out');
    final sync = await client.sync(app);
    final k = await key();
    await syncCall(() => SyncLogEngine.bind(account: user.id, host: _host.call));
    return SyncLogEngine(lkc: sync, key: k, host: _host.call);
  }

  /// The account's sync key, opened with the password here: what the log,
  /// the backup and any blobs are sealed with. Without [create], none is made
  /// where there is none.
  Future<SyncKeyHandle> key({bool create = true}) async {
    final user = client.user.value;
    if (user == null) throw const LkcException(code: LkcCode.perm, reason: 'signed_out');
    _account = user.id;
    return SyncKeyring.ofLkc(await client.sync(app), user.id, create: create);
  }

  /// Replaces the account's sync key (a device that held it is gone): what
  /// is written from now on is sealed to a new one.
  Future<void> rotateKey() async {
    if (!_wanted) throw StateError('LK Cloud sync is off');
    final engine = await (_opening ??= _open());
    final k = await key();
    await syncCall(() => engine.rotate(key: k));
  }

  /// Off, signed out or in as someone else: opened again for the next.
  void reset() {
    _soon?.cancel();
    _opening = null;
    if (_account case final id?) SyncKeyring.release(id);
    _account = null;
  }
}

/// While LK Cloud is the sync destination and the app is in the foreground
/// (on a desktop, running), listens for other devices' writes and syncs on
/// each, and on every (re)connection, which may have missed some.
final class LkcSyncWatch {
  LkcSyncWatch({
    required this._user,
    required this._signedIn,
    required this._open,
    required this._toggle,
    required this._onRemoteChange,
    this.bakFileName,
    this._onLog,
    this._onKey,
    this._retryAfter = const Duration(seconds: 30),
    this._inBackground = false,
  });

  /// The [log]'s watch: its batches pulled, its key checked, [onRemoteChange]
  /// told of the whole backup ([bakFileName]) written elsewhere.
  factory LkcSyncWatch.of(LkcLogSync log, {required VoidCallback onRemoteChange, String? bakFileName, bool inBackground = false}) =>
      LkcSyncWatch(
        user: log.client.user,
        // The user too: signing out clears it before the session is.
        signedIn: () => log.client.signedIn && log.client.user.value != null,
        open: () => log.client.sync(log.app),
        toggle: log.enabled,
        onRemoteChange: onRemoteChange,
        bakFileName: bakFileName,
        onLog: (seq) => unawaited(seq == null ? log.sync() : log.pull(seq)),
        onKey: () => unawaited(log.keyChanged()),
        inBackground: inBackground,
      );

  final Listenable _user;
  final bool Function() _signedIn;
  final Future<LkcSync> Function() _open;
  final ValueListenable<bool> _toggle;

  /// Another device wrote the whole backup ([bakFileName]), or listening
  /// began again: the app decides whether that is a sync to start.
  final VoidCallback _onRemoteChange;

  /// The whole backup's file name beside the log, if the app keeps one.
  final String? bakFileName;

  /// The log reached a seq, or (null) listening began again.
  final void Function(int? seq)? _onLog;

  /// Another device wrote the account's key file.
  final VoidCallback? _onKey;

  /// After listening could not start, or ended while still signed in; twice
  /// as long after each failure in a row, up to 32 times, until connected.
  final Duration _retryAfter;
  Timer? _retry;
  var _failures = 0;

  /// Listening whatever the window: a desktop app runs on behind other
  /// windows and in the tray. A phone's system ends the connection in the
  /// background anyway.
  final bool _inBackground;

  StreamSubscription<LkcSyncEvent>? _sub;
  LkcSync? _sync;
  var _starting = false;
  AppLifecycleListener? _lifecycle;

  void start() {
    if (_lifecycle != null) return;
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _update());
    _user.addListener(_update);
    _toggle.addListener(_update);
    _update();
  }

  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    _user.removeListener(_update);
    _toggle.removeListener(_update);
    await _stop();
  }

  bool get _wanted {
    final state = WidgetsBinding.instance.lifecycleState;
    // Inactive too: a desktop window out of focus is still in front of the
    // user, and on a phone it is a moment's overlay.
    final foreground =
        _inBackground || state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    return _lifecycle != null && foreground && _toggle.value && _signedIn();
  }

  Future<void> _stop() async {
    _retry?.cancel();
    _retry = null;
    final sub = _sub;
    _sub = null;
    _sync?.stopListening();
    await sub?.cancel();
  }

  Future<void> _update() async {
    if (!_wanted) return _stop();
    if (_sub != null || _starting) return;
    _starting = true;
    try {
      final sync = _sync ??= await _open();
      if (!_wanted) return;
      late final StreamSubscription<LkcSyncEvent> sub;
      sub = _sub = sync.listen().listen(
        _onEvent,
        onError: (Object e, StackTrace s) => Loggers.app.warning('LK Cloud sync events', e, s),
        onDone: () {
          if (!identical(_sub, sub)) return;
          _sub = null;
          // Ended by homebase refusing the session: a later sign-in starts
          // listening from there.
          if (!_signedIn()) return;
          _retryLater();
        },
      );
    } catch (e, s) {
      Loggers.app.warning('LK Cloud sync events', e, s);
      _retryLater();
    } finally {
      _starting = false;
    }
  }

  void _retryLater() {
    _retry?.cancel();
    final wait = _retryAfter * (1 << min(_failures, 5));
    _failures++;
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(_update());
    });
  }

  void _onEvent(LkcSyncEvent event) {
    if (event.lost case final why?) {
      Loggers.app.info('LK Cloud sync events: $why');
      return;
    }
    if (event.connected) _failures = 0;
    if (event.connected || (bakFileName != null && event.name == bakFileName)) _onRemoteChange();
    if (event.connected) _onLog?.call(null);
    if (event.name == lkcKeyFileName) _onKey?.call();
    if (event.logSeq case final seq?) _onLog?.call(seq);
  }
}
