import 'package:flutter/foundation.dart';

/// What kind of thing happened.
///
/// An open set, unlike a plain enum, because the categories worth having are
/// the app's: a server, a terminal session and a file transfer mean nothing
/// here, and a library that named them would be describing one app. The
/// constants below are the ones any app on this library has.
///
/// An `extension type` so that an app declaring its own costs nothing at
/// runtime and still cannot pass an arbitrary string by accident:
///
/// ```dart
/// abstract final class AppDiag {
///   static const server = DiagCategory('server');
/// }
/// ```
extension type const DiagCategory(String name) {
  /// Launch, foreground, background, and the migrations in between.
  static const lifecycle = DiagCategory('lifecycle');

  /// Which page the user is on.
  static const nav = DiagCategory('nav');

  /// The database and the stores over it.
  static const store = DiagCategory('store');

  /// Requests leaving the device, and what came back.
  static const network = DiagCategory('network');
}

/// How much a crumb matters, in the levels every reporting backend already has.
enum DiagLevel { debug, info, warning, error }

/// One thing that happened, on the way to something that went wrong.
///
/// **Everything in here is written on the assumption that it will be made
/// public.** A local file is not a private one: the point of this log is that a
/// user pastes it into a bug report, so "redact before sending" would be
/// redacting something already published. A crumb therefore never carries a
/// host, a username, a path or a command line — it carries what those *were*,
/// in a shape that answers the question without naming the thing. [Redact] is
/// how, and it is the caller's job, not the sink's: a sink that redacted would
/// have to guess which of two strings was the secret.
@immutable
final class Breadcrumb {
  const Breadcrumb({
    required this.category,
    required this.message,
    this.level = DiagLevel.info,
    this.data,
  });

  final DiagCategory category;

  /// A fixed phrase, not a formatted sentence. Values belong in [data], where a
  /// backend can index them and a reader can see what differs between two runs.
  final String message;

  final DiagLevel level;

  /// Already safe to publish, by the rule above.
  final Map<String, String>? data;

  @override
  String toString() {
    final buf = StringBuffer('${category.name}: $message');
    final data = this.data;
    if (data != null && data.isNotEmpty) {
      buf.write(' {');
      buf.write(data.entries.map((e) => '${e.key}=${e.value}').join(', '));
      buf.write('}');
    }
    return buf.toString();
  }
}

/// Where a diagnostic goes.
///
/// A class with empty defaults rather than an interface, for the same reason
/// `SSHCryptoBackend` is one: this will grow — a reporting backend wants
/// sessions, releases and a user id that a local file has no use for — and an
/// abstract method added later breaks every implementer at once. Overriding
/// nothing gives a sink that drops everything, which is a valid sink and is
/// what an app that has installed none gets.
///
/// Implementations are called from wherever the event happened, including the
/// isolate drawing frames. They must not block: a sink that cannot keep up
/// drops crumbs rather than making the app wait.
class DiagnosticsSink {
  const DiagnosticsSink();

  /// Something happened that a later failure would be read in the light of.
  void breadcrumb(Breadcrumb crumb) {}

  /// Something failed. [source] names what noticed, not what broke.
  void error(Object error, StackTrace? stack, {String? source}) {}

  /// A log line, as it is written.
  ///
  /// Distinct from [breadcrumb], and the distinction is when it is sent. A
  /// crumb is context for a failure that has not happened yet, so a sink holds
  /// it and attaches it to whatever goes wrong later — if nothing does, it is
  /// discarded. A log line is delivered as it happens, which is what makes a
  /// problem visible that never produces an error at all.
  ///
  /// Most sinks should ignore this. The local one already has the line — it is
  /// what wrote it — and a network sink forwarding every line is a decision
  /// about bandwidth and storage, not a default.
  void log(DiagLevel level, String message, {String? logger}) {}

  /// A fact about this run that every later event should be read with — the
  /// platform, the schema version, whether an SSH engine is present.
  ///
  /// Passing null clears it.
  void tag(String key, String? value) {}

  /// Pushes anything buffered. Awaited on the way into the background, where
  /// the process may never be resumed.
  Future<void> flush() async {}
}

/// Sends everything to each of [sinks], in order.
///
/// One sink throwing must not stop the next. The local file exists precisely
/// for the runs where a network sink can report nothing, so the order sinks
/// were listed in must not decide whether a crash is recorded at all.
final class FanOutSink extends DiagnosticsSink {
  const FanOutSink(this.sinks);

  final List<DiagnosticsSink> sinks;

  @override
  void breadcrumb(Breadcrumb crumb) => _each((s) => s.breadcrumb(crumb));

  @override
  void error(Object error, StackTrace? stack, {String? source}) =>
      _each((s) => s.error(error, stack, source: source));

  @override
  void log(DiagLevel level, String message, {String? logger}) =>
      _each((s) => s.log(level, message, logger: logger));

  @override
  void tag(String key, String? value) => _each((s) => s.tag(key, value));

  @override
  Future<void> flush() async {
    for (final sink in sinks) {
      try {
        await sink.flush();
      } catch (_) {}
    }
  }

  void _each(void Function(DiagnosticsSink) fn) {
    for (final sink in sinks) {
      try {
        fn(sink);
      } catch (_) {
        // Reporting a failure of the thing that reports failures has nowhere
        // to go but here.
      }
    }
  }
}
