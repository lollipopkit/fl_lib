import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

/// Records what it was given, for asserting on what reached it.
final class _RecordingSink extends DiagnosticsSink {
  final crumbs = <Breadcrumb>[];
  final errors = <Object>[];
  final tags = <String, String?>{};
  var flushes = 0;

  @override
  void breadcrumb(Breadcrumb crumb) => crumbs.add(crumb);

  @override
  void error(Object error, StackTrace? stack, {String? source}) =>
      errors.add(error);

  @override
  void tag(String key, String? value) => tags[key] = value;

  @override
  Future<void> flush() async => flushes++;
}

/// A backend having a bad day: the network one, mid-outage.
final class _ThrowingSink extends DiagnosticsSink {
  @override
  void breadcrumb(Breadcrumb crumb) => throw StateError('sink down');

  @override
  void error(Object error, StackTrace? stack, {String? source}) =>
      throw StateError('sink down');

  @override
  void tag(String key, String? value) => throw StateError('sink down');

  @override
  Future<void> flush() async => throw StateError('sink down');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(Diag.uninstall);

  group('Diag', () {
    test('does nothing until a sink is installed', () {
      // The state a release with reporting turned off is in, on every call
      // site left in the code. It must not be a special case anywhere.
      expect(
        () => Diag.crumb(DiagCategory.nav, 'opened', data: {'page': 'home'}),
        returnsNormally,
      );
      expect(() => Diag.error(StateError('x')), returnsNormally);
      expect(() => Diag.tag('platform', 'test'), returnsNormally);
    });

    test('passes crumbs to the installed sink', () {
      final sink = _RecordingSink();
      Diag.install(sink);

      Diag.crumb(DiagCategory.nav, 'opened', data: {'page': 'home'});

      expect(sink.crumbs.single.category, DiagCategory.nav);
      expect(sink.crumbs.single.message, 'opened');
      expect(sink.crumbs.single.data, {'page': 'home'});
      expect(sink.crumbs.single.level, DiagLevel.info);
    });

    test('uninstall stops delivery rather than asking the sink to be quiet',
        () {
      // Withdrawing consent has to take the sink out. A sink merely told to go
      // quiet could still send what it had already batched.
      final sink = _RecordingSink();
      Diag.install(sink);
      Diag.uninstall();

      Diag.crumb(DiagCategory.nav, 'after');

      expect(sink.crumbs, isEmpty);
    });
  });

  group('FanOutSink', () {
    test('reaches every sink', () {
      final a = _RecordingSink();
      final b = _RecordingSink();
      Diag.install(FanOutSink([a, b]));

      Diag.crumb(DiagCategory.store, 'migrated');
      Diag.tag('schema', '17');

      expect(a.crumbs.single.message, 'migrated');
      expect(b.crumbs.single.message, 'migrated');
      expect(a.tags['schema'], '17');
      expect(b.tags['schema'], '17');
    });

    test('one sink throwing does not stop the next', () async {
      // The local file exists for exactly the runs where a network sink cannot
      // report anything. The order they were listed in must not decide whether
      // a crash is recorded at all.
      final local = _RecordingSink();
      Diag.install(FanOutSink([_ThrowingSink(), local]));

      Diag.crumb(DiagCategory.lifecycle, 'launched');
      Diag.error(StateError('boom'));
      Diag.tag('k', 'v');
      await Diag.flush();

      expect(local.crumbs.single.message, 'launched');
      expect(local.errors, hasLength(1));
      expect(local.tags['k'], 'v');
      expect(local.flushes, 1);
    });
  });

  group('LocalDiagnosticsSink', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('diag_local_test');
      Logger.root.level = Level.WARNING;
      // Subscribing to the log stream is what `handleErrors` does; without it
      // a log record never reaches the file and only crumbs would.
      CrashLog.handleErrors();
      await CrashLog.attach(tmp.path);
    });

    tearDown(() async {
      await CrashLog.resetForTest();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<String> written() =>
        File(tmp.path.joinPath(CrashLog.currentName)).readAsString();

    test('crumbs land in the same file as the log, in one time order',
        () async {
      // Interleaved on purpose: what happened before the error is the entire
      // reason to have crumbs, and a sidecar file makes the reader reconstruct
      // that by hand.
      Diag.install(LocalDiagnosticsSink());

      Diag.crumb(DiagCategory.network, 'request', data: {'host': 'private/ab'});
      Loggers.app.warning('it failed');
      Diag.crumb(DiagCategory.network, 'retry');

      final content = await written();
      expect(content.indexOf('request'), lessThan(content.indexOf('it failed')));
      expect(content.indexOf('it failed'), lessThan(content.indexOf('retry')));
      expect(content, contains('host=private/ab'));
    });

    test('a repeated tag is written once', () async {
      // Tags are set from places that run per connection or per frame. A line
      // per call would crowd out the log they are supposed to annotate.
      final sink = LocalDiagnosticsSink();
      Diag.install(sink);

      Diag.tag('engine', 'ish');
      Diag.tag('engine', 'ish');
      Diag.tag('engine', 'proot');

      final content = await written();
      expect('engine=ish'.allMatches(content).length, 1);
      expect(content, contains('engine=proot'));
      expect(sink.tags, {'engine': 'proot'});
    });

    test('an error reported through the sink is not a crash', () async {
      // `Diag.error` is for something that was caught and reported. Only the
      // run *ending* on an error sets the marker.
      Diag.install(LocalDiagnosticsSink());

      Diag.error(StateError('handled'), StackTrace.current, 'test');
      await CrashLog.resetForTest();
      await CrashLog.attach(tmp.path);

      expect(CrashLog.lastRunEndedBadly, isFalse);
    });
  });
}
