/// The lock screen's exits.
///
/// It is deliberately hard to leave — `PopScope(canPop: false)` turns the back
/// gesture into "quit the app" — which makes the case where it *cannot* open
/// the one that matters. A device with no sensor, nothing enrolled, or no
/// plugin for its platform answers `notAvail` to every attempt, and the page
/// used to do nothing with that: the app could only be quit.
///
/// Reported as lollipopkit/flutter_server_box#1406, from a phone's backup
/// restored onto a Linux desktop.
library;

import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    LocalAuth.isAvailForTest = null;
    LocalAuth.goWithResultForTest = null;
  });

  /// The lock pushed over a page, which is how an app uses it.
  ///
  /// Pushed rather than made the `home`: leaving is the behaviour under test,
  /// and a navigator refuses to pop its last route — so as a root the page
  /// would look stuck no matter what it did.
  ///
  /// `LocalAuth` is stubbed rather than left to the plugin: a plugin call's
  /// future does not complete inside a `testWidgets` fake-async zone, so the
  /// page would sit on its first attempt for ever and every case below would
  /// look alike.
  Future<void> openLock(
    WidgetTester tester, {
    VoidCallback? onAuthSuccess,
    VoidCallback? onUnavailable,
  }) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          LibLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: LibLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: Text('behind'))),
      ),
    );
    unawaited(
      LocalAuthPage.route.go(
        tester.element(find.text('behind')),
        args: LocalAuthPageArgs(
          onAuthSuccess: onAuthSuccess,
          onUnavailable: onUnavailable,
        ),
      ),
    );
    // Past the push, the first attempt, and the pop it may have caused.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a device that cannot authenticate is let through', (
    tester,
  ) async {
    var unavailable = 0;
    var succeeded = 0;
    LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async =>
        AuthResult.notAvail;

    await openLock(
      tester,
      onAuthSuccess: () => succeeded++,
      onUnavailable: () => unavailable++,
    );

    expect(unavailable, 1);
    expect(succeeded, 0, reason: 'unavailable is not success');
    expect(
      find.byType(LocalAuthPage),
      findsNothing,
      reason: 'the app is still held behind a lock that cannot open',
    );
  });

  testWidgets('and a caller that says nothing still gets its app back', (
    tester,
  ) async {
    // `onUnavailable` is optional, and the page letting itself out is what
    // keeps the omission from bricking the app.
    LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async =>
        AuthResult.notAvail;

    await openLock(tester);

    expect(find.byType(LocalAuthPage), findsNothing);
  });

  testWidgets('a failure keeps the lock, and says so', (tester) async {
    // The other half of the same bug: every non-success result landed in one
    // empty branch, so the screen looked broken rather than unsatisfied.
    var unavailable = 0;
    LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async =>
        AuthResult.fail;

    await openLock(tester, onUnavailable: () => unavailable++);

    expect(find.byType(LocalAuthPage), findsOneWidget);
    expect(unavailable, 0, reason: 'a wrong finger is not a missing sensor');
    expect(find.text(libL10n.fail), findsOneWidget);
  });

  testWidgets('a cancel and a lockout say the same', (tester) async {
    for (final result in [AuthResult.cancel, AuthResult.lockedOut]) {
      LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async => result;

      await openLock(tester);

      expect(find.byType(LocalAuthPage), findsOneWidget, reason: '$result');
      expect(find.text(libL10n.fail), findsOneWidget, reason: '$result');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('success leaves, and reports it once', (tester) async {
    var succeeded = 0;
    LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async =>
        AuthResult.success;

    await openLock(tester, onAuthSuccess: () => succeeded++);

    expect(succeeded, 1);
    expect(find.byType(LocalAuthPage), findsNothing);
    expect(find.text(libL10n.fail), findsNothing);
  });

  testWidgets('a second tap while one prompt is open starts nothing', (
    tester,
  ) async {
    // `goWithResult` has no re-entry guard of its own — `go` does — and this
    // page can start a prompt from `afterFirstLayout` and from every tap.
    var prompts = 0;
    LocalAuth.goWithResultForTest = ({bool onlyBio = false}) async {
      prompts++;
      await Future<void>.delayed(const Duration(seconds: 1));
      return AuthResult.fail;
    };

    await openLock(tester);
    // The first prompt is open and unanswered.
    expect(prompts, 1);

    await tester.tap(find.byType(InkWell));
    await tester.tap(find.byType(InkWell));
    await tester.pump();

    expect(prompts, 1, reason: 'a tap started a second concurrent prompt');

    // And once it answers, the page is tappable again.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(prompts, 2);

    await tester.pump(const Duration(seconds: 2));
  });
}
