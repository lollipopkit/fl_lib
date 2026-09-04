import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/src/core/diag/diag.dart';
import 'package:fl_lib/src/core/diag/sink.dart';
import 'package:fl_lib/src/core/ext/string.dart';
import 'package:fl_lib/src/core/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Keeps a crashed run's log where the crash cannot take it.
///
/// An in-memory console covers a user who notices something and goes looking.
/// It cannot cover a crash: the process is gone and the buffer with it, and a
/// crash during launch leaves no page to open and copy anything out of.
///
/// Three decisions shape what is here.
///
/// The sink is a file, and it is attached to the log stream *before* the parts
/// of startup most likely to fail. [handleErrors] runs first and buffers into
/// memory, [attach] hands that buffer to disk once there is a path to write to,
/// and nothing between the two is lost — which is the point, because native
/// library loading, database opening and schema migration all happen in there.
///
/// The previous run's file is kept whole rather than appended to. The run that
/// crashed is the one worth reading, and one file holding both interleaves the
/// crash with whatever the user did next.
///
/// Writes are synchronous. A crash gives no chance to flush, and the last lines
/// before it are the point of the file. Callers are expected to keep the log
/// level at WARNING and to use breadcrumbs, not logging, for anything frequent.
abstract final class CrashLog {
  /// The run happening now.
  static const currentName = 'app.log';

  /// The run before this one, kept whole. What a report is built from.
  static const previousName = 'app.log.1';

  /// Written when a handler here sees an error nothing else caught, read on the
  /// next launch, and deleted once read.
  ///
  /// A file rather than a line in the log, so that answering "did the last run
  /// end badly" does not mean parsing one — and so that a platform-side crash
  /// handler can set it without agreeing on a log format first.
  static const markerName = 'unhandled';

  /// A ceiling, not a target: a run that loops on an error would otherwise fill
  /// the disk. Past this the file stops growing and says so on its last line.
  static const maxBytes = 512 * 1024;

  /// How much of an error and its stack the marker keeps.
  ///
  /// The marker is read on the launch after the crash and is the only thing
  /// that survives it, so it holds the error rather than only the fact of one.
  /// Bounded because a stack from a deeply nested async chain has no natural
  /// size, and this file is written from inside a failing process.
  static const maxMarkerChars = 8 * 1024;

  /// Whether an error handed to a sink right now is being uploaded.
  ///
  /// Set by an app that uploads crashes; left null by one that does not, where
  /// every crash is worth describing to the next launch.
  ///
  /// Read when the marker is written, and it decides whether the marker keeps
  /// a *detail*. An error a sink has already sent needs none: the next launch
  /// reading one is what makes it report the crash again, and a crash sent
  /// live and replayed the following launch is one bug filed as two. What is
  /// left with a detail is the case the live path cannot reach — an error
  /// before there is a sink at all, which is most of startup.
  static bool Function()? uploadsNow;

  static Directory? _dir;
  static RandomAccessFile? _file;
  static int _written = 0;
  static bool _truncated = false;
  static bool _lastRunEndedBadly = false;
  static String? _lastRunError;
  static StreamSubscription<LogRecord>? _sub;
  static bool _installed = false;
  static FlutterExceptionHandler? _prevFlutterOnError;
  static bool Function(Object, StackTrace)? _prevPlatformOnError;

  /// Lines logged before [attach] found somewhere to put them.
  static final _pending = <String>[];

  /// How many of those are kept. Startup between the two calls logs a handful
  /// on a healthy launch; this is a bound for the launch that is not healthy.
  static const _maxPending = 200;

  /// Whether the previous run ended on an error no handler expected.
  ///
  /// False until [attach] has run. Says nothing about a run the user ended
  /// themselves, or one the OS reclaimed while it sat in the background —
  /// neither leaves the marker, which is why the marker exists rather than a
  /// "did we exit cleanly" flag. Flutter gets no reliable say in when it is
  /// being killed, so a flag like that reads a backgrounded app as a crash.
  static bool get lastRunEndedBadly => _lastRunEndedBadly;

  /// What ended the previous run, when the marker was left with a detail.
  ///
  /// The error's own text and its stack, separated by a newline. Null both
  /// when the run ended normally and when it ended on an error something had
  /// already uploaded — see [uploadsNow]. So this is not "was there a crash",
  /// which is [lastRunEndedBadly]; it is "is there a crash nobody has heard
  /// about yet".
  static String? get lastRunError => _lastRunError;

  /// Whether [attach] has found somewhere to write.
  static bool get isAttached => _file != null;

  /// Where the logs are, once [attach] has run.
  ///
  /// So that a caller keeping something of its own beside them — a composed
  /// report, say — does not have to be told the same path a second time and
  /// then be the thing that disagrees about it.
  static String? get dirPath => _dir?.path;

  /// Installs the error handlers and starts buffering.
  ///
  /// Call before anything that can fail, and before [attach]: the errors most
  /// worth catching are the ones that stop the app from finishing startup, and
  /// those happen before there is a writable path.
  ///
  /// The handlers are additive. [FlutterError.onError] keeps presenting the
  /// error the way it did — the red screen in debug is how a developer notices
  /// at all — and `PlatformDispatcher.onError` answers whatever the previous
  /// handler did, so an app relying on `runZonedGuarded` keeps seeing what it
  /// saw before.
  static void handleErrors() {
    // Idempotent: a second call would wrap the handlers this one installed,
    // and every error would then be recorded once per call.
    if (_installed) return;
    _installed = true;

    _sub = Logger.root.onRecord.listen(_onRecord);

    final presentError = _prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      // `silent` is set for errors the framework expects to handle itself, and
      // for the second and later copies of one it already reported.
      if (!details.silent) {
        _recordUnhandled('FlutterError', details.exception, details.stack);
      }
      presentError?.call(details);
    };

    // Errors that reach the engine with nothing in Dart having handled them.
    final onError = _prevPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, s) {
      _recordUnhandled('PlatformDispatcher', e, s);
      return onError?.call(e, s) ?? false;
    };
  }

  /// Rotates the previous run's file out of the way and starts writing.
  ///
  /// Best effort by construction: a device that cannot be written to is not one
  /// where the app should refuse to start, and every failure here costs a log
  /// rather than a feature. [handleErrors] keeps buffering if this never runs.
  static Future<void> attach(String dirPath) async {
    if (_file != null) return;
    try {
      final dir = await Directory(dirPath).create(recursive: true);
      _dir = dir;

      final current = File(_path(dir, currentName));
      if (await current.exists()) {
        // `rename` over an existing file replaces it on POSIX and throws on
        // Windows, and this has to behave the same on both.
        final previous = File(_path(dir, previousName));
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }

      _file = await current.open(mode: FileMode.writeOnlyAppend);
      _written = 0;
      _truncated = false;

      // Last, and only once there is somewhere to write. Taking it first
      // meant a rotation that threw — a locked file on Windows, a full
      // volume — consumed the marker on the way past: the crash it recorded
      // became unreportable *and* unrepeatable, since the next launch would
      // then see a clean start too.
      _lastRunEndedBadly = await _takeMarker(dir);

      final pending = List.of(_pending);
      _pending.clear();
      for (final line in pending) {
        write(line);
      }
    } catch (e, s) {
      // Not through `Loggers`: that arrives back here and finds no file, so it
      // would only fill the buffer this failure means nothing will ever drain.
      debugPrint('CrashLog.attach($dirPath): $e\n$s');
    }
  }

  /// Appends one line, or buffers it when [attach] has not run yet.
  ///
  /// Public because a breadcrumb is not a log record and should not have to
  /// become one to be written: routing crumbs through [Logger] would put them
  /// in the in-app console and the developer's terminal too, at a rate neither
  /// is meant for.
  static void write(String line) {
    final file = _file;
    if (file == null) {
      // Bounded, and the newest is what is kept: an app that never reaches
      // [attach] must not grow a list until it dies of that instead, and when
      // the buffer does reach disk the lines nearest the failure are the ones
      // worth having.
      if (_pending.length >= _maxPending) _pending.removeAt(0);
      _pending.add(line);
      return;
    }
    if (_truncated) return;

    try {
      final bytes = utf8.encode('$line\n');
      if (_written + bytes.length > maxBytes) {
        _truncated = true;
        file.writeStringSync('--- log full, further lines dropped ---\n');
        return;
      }
      // Written, not fsynced. `writeFromSync` hands the bytes to the kernel,
      // and a process dying does not take the kernel's copy with it — which
      // is the whole failure this file exists for. `flushSync` would only add
      // durability against power loss, at the price of an fsync on the
      // calling isolate: a crumb is emitted on every route change and every
      // container operation, so that was an fsync per screen transition on
      // the isolate drawing frames.
      file.writeFromSync(bytes);
      _written += bytes.length;
    } catch (e) {
      // A full disk, or a file the OS took away. Dropping the line is the only
      // option that does not turn logging into its own crash.
      debugPrint('CrashLog write: $e');
    }
  }

  /// Forces what has been written out to storage.
  ///
  /// Not needed to survive a crash — the kernel already holds those bytes —
  /// but it is what survives the battery going flat or the device being
  /// yanked, which is worth one fsync at the point the app is going away
  /// anyway. Called from the lifecycle handler, not per line.
  static void flush() {
    try {
      _file?.flushSync();
    } catch (e) {
      debugPrint('CrashLog flush: $e');
    }
  }

  /// Records that *this* run ended on something nothing handled.
  ///
  /// Exposed so a sink that caught an error outside Flutter's handlers can
  /// mark the run the same way the handlers here do. Writes the marker, which
  /// the next launch reads — so it does nothing before [attach].
  ///
  /// [error] and [stack] are what the next launch reads back as
  /// [lastRunError], and passing them is worth doing even when a sink is
  /// installed: whether they are kept is decided here, by [uploadsNow], rather
  /// than by each caller working out whether anything heard about the error.
  static void markUnhandled([Object? error, StackTrace? stack]) =>
      _leaveMarker(error, stack);

  /// Records that the *previous* run ended badly, on some other authority.
  ///
  /// For a platform that keeps its own record of how the process died —
  /// Android's `ApplicationExitInfo`, iOS's MetricKit. Those cover the deaths
  /// the marker cannot: a native crash takes the process with it, so no
  /// handler here runs and no marker is written, and the next launch would
  /// otherwise see a clean start.
  ///
  /// Sets the answer directly rather than writing a marker for the launch
  /// after this one. The platform is reporting a conclusion about a run that
  /// is already over, and routing that through a file would delay it by a
  /// launch for no reason.
  static void reportPreviousRunCrashed() => _lastRunEndedBadly = true;

  /// The previous run's log, or null when there is none to read.
  static Future<String?> readPrevious() async {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final previous = File(_path(dir, previousName));
      if (!await previous.exists()) return null;
      return await previous.readAsString();
    } catch (e, s) {
      debugPrint('CrashLog.readPrevious: $e\n$s');
      return null;
    }
  }

  /// This run's log so far.
  static Future<String?> readCurrent() async {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final current = File(_path(dir, currentName));
      if (!await current.exists()) return null;
      return await current.readAsString();
    } catch (e, s) {
      debugPrint('CrashLog.readCurrent: $e\n$s');
      return null;
    }
  }

  /// Drops both runs' logs and the marker.
  static Future<void> clear() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await _file?.close();
      _file = null;
      for (final name in const [currentName, previousName, markerName]) {
        final file = File(_path(dir, name));
        if (await file.exists()) await file.delete();
      }
      _lastRunEndedBadly = false;
      _lastRunError = null;
      final current = File(_path(dir, currentName));
      _file = await current.open(mode: FileMode.writeOnlyAppend);
      _written = 0;
      _truncated = false;
    } catch (e, s) {
      debugPrint('CrashLog.clear: $e\n$s');
    }
  }

  /// Reverts everything [handleErrors] and [attach] installed. Tests only.
  @visibleForTesting
  static Future<void> resetForTest() async {
    await _sub?.cancel();
    _sub = null;
    await _file?.close();
    _file = null;
    _dir = null;
    _pending.clear();
    _written = 0;
    _truncated = false;
    _lastRunEndedBadly = false;
    _lastRunError = null;
    uploadsNow = null;
    if (_installed) {
      FlutterError.onError = _prevFlutterOnError;
      PlatformDispatcher.instance.onError = _prevPlatformOnError;
      _prevFlutterOnError = null;
      _prevPlatformOnError = null;
      _installed = false;
    }
  }

  static void _onRecord(LogRecord record) {
    final buf = StringBuffer()
      ..write('[${record.time.toIso8601String()}]')
      ..write('[${record.loggerName}][${record.level.name}] ')
      ..write(record.message);
    if (record.error != null) buf.write(': ${record.error}');
    final trace = record.stackTrace;
    if (trace != null) buf.write('\n$trace');
    write(buf.toString());

    // Also offered live, for a sink that streams logs rather than waiting for
    // a failure. SEVERE is withheld: it reaches a sink through `error` on its
    // own path, and forwarding it here as well would send every crash twice.
    if (record.level < Level.SEVERE) {
      Diag.log(
        record.level >= Level.WARNING ? DiagLevel.warning : DiagLevel.info,
        record.message,
        logger: record.loggerName,
      );
    }
  }

  /// Logged and marked. The mark is what the next launch reads.
  ///
  /// Through [Diag], because this is the path [_onRecord] withholds SEVERE
  /// for. Between them they were the only two ways an error reached a sink,
  /// and neither took it: `_onRecord` skips SEVERE on the grounds that it
  /// "reaches a sink through `error` on its own path", and that path did not
  /// call [Diag.error]. So an installed sink heard about every log line and
  /// every crumb, and never about the one error that ended the run.
  ///
  /// [LocalDiagnosticsSink.error] writes to the file by way of [Loggers], so
  /// logging here as well would record every crash twice. With no sink
  /// installed nothing would be written at all — and that is most of startup,
  /// since [handleErrors] deliberately runs before anything calls
  /// [Diag.install] — so the direct logger call is what covers that window.
  static void _recordUnhandled(String source, Object error, StackTrace? stack) {
    if (Diag.enabled) {
      Diag.error(error, stack, 'Unhandled ($source)');
    } else {
      Loggers.app.severe('Unhandled ($source)', error, stack);
    }
    _leaveMarker(error, stack);
  }

  static void _leaveMarker([Object? error, StackTrace? stack]) {
    final dir = _dir;
    if (dir == null) return;
    try {
      File(_path(dir, markerName)).writeAsStringSync(_markerBody(error, stack));
    } catch (e) {
      debugPrint('CrashLog marker: $e');
    }
  }

  /// What the marker says, which is the error and nothing around it.
  ///
  /// Empty for a crash a sink is already uploading — see [uploadsNow] — and
  /// empty when the caller had nothing to describe, which is every marker left
  /// by a platform's own crash record rather than by a Dart handler.
  static String _markerBody(Object? error, StackTrace? stack) {
    if (error == null) return '';
    if (uploadsNow?.call() ?? false) return '';
    final body = stack == null ? '$error' : '$error\n$stack';
    return body.length > maxMarkerChars
        ? body.substring(0, maxMarkerChars)
        : body;
  }

  /// Reads the marker and removes it, so one crash is reported once.
  static Future<bool> _takeMarker(Directory dir) async {
    try {
      final marker = File(_path(dir, markerName));
      if (!await marker.exists()) return false;
      // Read separately from the delete, and not allowed to prevent it. A
      // marker whose contents will not decode still answers the question this
      // is here to answer; leaving it behind because the detail was unreadable
      // would report the same crash on every launch from now on.
      String body;
      try {
        body = await marker.readAsString();
      } catch (e) {
        debugPrint('CrashLog marker body: $e');
        body = '';
      }
      await marker.delete();
      _lastRunError = body.isEmpty ? null : body;
      return true;
    } catch (e) {
      debugPrint('CrashLog marker: $e');
      return false;
    }
  }

  static String _path(Directory dir, String name) => dir.path.joinPath(name);
}
