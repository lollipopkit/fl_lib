import 'package:fl_lib/src/core/diag/crash_log.dart';
import 'package:fl_lib/src/core/diag/sink.dart';
import 'package:fl_lib/src/core/logger.dart';

/// Writes diagnostics to the file [CrashLog] keeps, on the device.
///
/// The one sink that works with no network, no account and no consent prompt,
/// because nothing leaves the device: the user is the one who sends it, by
/// pasting it into a bug report. That is also why a crumb must already be safe
/// to publish — see [Breadcrumb].
///
/// Crumbs go into the same file as the log records, in one time order, rather
/// than into a sidecar the reader has to interleave by hand. What happened
/// before the error is the whole reason to have them.
final class LocalDiagnosticsSink extends DiagnosticsSink {
  LocalDiagnosticsSink();

  final Map<String, String> _tags = {};

  /// What this run has been tagged with, for a report header.
  Map<String, String> get tags => Map.unmodifiable(_tags);

  @override
  void breadcrumb(Breadcrumb crumb) {
    CrashLog.write('[${DateTime.now().toIso8601String()}]'
        '[${crumb.level.name}] $crumb');
  }

  @override
  void error(Object error, StackTrace? stack, {String? source}) {
    // Through the logger rather than straight to the file: an error is also
    // what the in-app console and the developer's terminal should show, and
    // [CrashLog] is already listening for it. Writing both ways would record
    // it twice.
    //
    // Not marked as unhandled. This is the path for an error something caught
    // and chose to report; the marker means the run *ended* on one, and
    // [CrashLog]'s own handlers are what set it.
    Loggers.app.severe(source ?? 'Diag', error, stack);
  }

  /// Lines are written as they arrive and are already safe against the process
  /// dying; this is the fsync, at the one moment it is worth paying for.
  @override
  Future<void> flush() async => CrashLog.flush();

  @override
  void tag(String key, String? value) {
    if (value == null) {
      if (_tags.remove(key) != null) CrashLog.write('[tag] $key cleared');
      return;
    }
    if (_tags[key] == value) return;
    _tags[key] = value;
    CrashLog.write('[tag] $key=$value');
  }
}
