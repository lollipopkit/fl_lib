import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mark's two contracts, both of which are only visible in a row: it must
/// take the width of its own text rather than the line it is in, and a long
/// name beside it must ellipsise instead of pushing it off.
void main() {
  testWidgets('BetaTag is as wide as its text, not as wide as the row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              BetaTag(key: const ValueKey('beta')),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final tag = tester.getRect(find.byKey(const ValueKey('beta')));
    expect(tag.width, lessThan(60));
    expect(tag.height, BetaTag.title);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('a long name ellipsises rather than pushing the mark off', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: TwoLineText(
              up: 'A remote desktop session with a name far too long for a bar',
              down: 'web',
              mark: const BetaTag(),
            ),
          ),
        ),
      ),
    );

    final bar = tester.getRect(find.byType(AppBar));
    final tag = tester.getRect(find.text('Beta'));
    expect(tag.right, lessThanOrEqualTo(bar.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mark is drawn at the size it is asked for', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: BetaTag(height: BetaTag.heading)),
        ),
      ),
    );
    expect(tester.getRect(find.byType(BetaTag)).height, BetaTag.heading);
  });
}
