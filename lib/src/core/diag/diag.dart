import 'package:fl_lib/src/core/diag/sink.dart';

/// Where the app reports what it is doing and what went wrong.
///
/// Static rather than injected, and deliberately: a breadcrumb is dropped from
/// wherever the thing happened — inside a connection retry, a file transfer, a
/// route observer — and threading a sink through all of those would mean the
/// call sites that most need one are the ones least likely to have it. It is
/// also live before the container is, since the errors worth catching most
/// happen during startup.
///
/// Doing nothing until [install] is called is the intended default. An app that
/// installs no sink pays one virtual call per crumb and keeps no state, so
/// leaving instrumentation in a build that reports nothing costs nothing.
abstract final class Diag {
  static DiagnosticsSink _sink = const DiagnosticsSink();

  /// The sink everything below goes to.
  static DiagnosticsSink get sink => _sink;

  /// Replaces the sink. Pass a [FanOutSink] for more than one.
  static void install(DiagnosticsSink sink) => _sink = sink;

  /// Stops reporting, keeping whatever the sinks already wrote.
  ///
  /// What turning the setting off has to do: a sink is not asked to be quiet,
  /// it is taken out, so a backend that batches cannot send one last batch
  /// after consent was withdrawn.
  static void uninstall() => _sink = const DiagnosticsSink();

  /// Records that something happened. See [Breadcrumb] on what may go in
  /// [data] — the short version is that it will be published.
  static void crumb(
    DiagCategory category,
    String message, {
    DiagLevel level = DiagLevel.info,
    Map<String, String>? data,
  }) {
    _sink.breadcrumb(Breadcrumb(
      category: category,
      message: message,
      level: level,
      data: data,
    ));
  }

  /// Records that something failed. [source] names what noticed.
  static void error(Object error, [StackTrace? stack, String? source]) =>
      _sink.error(error, stack, source: source);

  /// A fact about this run to read every later event with. Null clears it.
  static void tag(String key, String? value) => _sink.tag(key, value);

  /// Pushes anything buffered. Awaited on the way into the background.
  static Future<void> flush() => _sink.flush();
}
