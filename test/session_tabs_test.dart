import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _ensureBinding() => TestWidgetsFlutterBinding.ensureInitialized();

/// The two things that are easy to get subtly wrong when a page hosts several
/// live sessions: naming a second session on the same target, and deciding
/// what to show after one in the middle is closed.
void main() {
  _ensureBinding();

  group('names', () {
    test('a second session on one target does not reuse the name', () {
      final c = SessionTabsController<String>();
      final first = c.add(preferred: 'alpine', build: (_, _, _) => 'srv');
      final second = c.add(preferred: 'alpine', build: (_, _, _) => 'srv');
      final third = c.add(preferred: 'alpine', build: (_, _, _) => 'srv');

      expect(first.name, 'alpine');
      expect(second.name, 'alpine(1)');
      expect(
        third.name,
        'alpine(2)',
        reason: 'two tabs labelled the same leave no way to say which is which',
      );
    });

    test('the leading tab reserves its name too', () {
      final c = SessionTabsController<String>(leadingName: '+');
      expect(c.add(preferred: '+', build: (_, _, _) => 'srv').name, '+(1)');
    });

    test('an id is never handed out again, even when the name is', () {
      // A callback that outlives its tab — a connection that ends long after
      // the tab was closed — must not act on whichever tab now answers to the
      // same name.
      final c = SessionTabsController<String>();
      final first = c.add(preferred: 'alpine', build: (_, _, _) => 'srv');
      c.remove(first.id);
      final second = c.add(preferred: 'alpine', build: (_, _, _) => 'srv');

      expect(second.name, first.name, reason: 'the label comes back');
      expect(second.id, isNot(first.id), reason: 'the identity does not');

      c.remove(first.id);
      expect(c.tabs.length, 1, reason: 'the stale id removed nothing');
    });

    test('a name freed by closing is available again', () {
      final c = SessionTabsController<String>();
      c.add(preferred: 'alpine', build: (_, _, _) => 'srv');
      c.add(preferred: 'alpine', build: (_, _, _) => 'srv');
      c.remove(c.tabs.first.id);

      expect(c.add(preferred: 'alpine', build: (_, _, _) => 'srv').name, 'alpine');
    });
  });

  group('closing', () {
    test('closing to the left of the visible tab keeps it visible', () {
      final c = SessionTabsController<String>();
      c.add(preferred: 'a', build: (_, _, _) => 'a');
      c.add(preferred: 'b', build: (_, _, _) => 'b');
      c.add(preferred: 'c', build: (_, _, _) => 'c');
      c.select(2); // showing 'c'

      c.remove(c.tabs.firstWhere((t) => t.name == 'a').id);

      expect(c.index, 1);
      expect(
        c.current?.name,
        'c',
        reason: 'closing a tab elsewhere must not move the user',
      );
    });

    test('closing the visible tab shows its neighbour', () {
      final c = SessionTabsController<String>();
      c.add(preferred: 'a', build: (_, _, _) => 'a');
      c.add(preferred: 'b', build: (_, _, _) => 'b');
      c.select(1);

      c.remove(c.tabs.firstWhere((t) => t.name == 'b').id);

      expect(c.index, 0);
      expect(c.current?.name, 'a');
    });

    test('closing the last one falls back to the leading tab', () {
      final c = SessionTabsController<String>(leadingName: '+');
      c.add(preferred: 'a', build: (_, _, _) => 'a');
      c.select(1);

      c.remove(c.tabs.firstWhere((t) => t.name == 'a').id);

      expect(c.index, 0);
      expect(c.current, isNull, reason: 'the leading tab has no session');
    });

    test('closing something that is not there changes nothing', () {
      final c = SessionTabsController<String>();
      c.add(preferred: 'a', build: (_, _, _) => 'a');
      c.select(0);

      expect(c.remove('no-such-id'), 0);
      expect(c.tabs.length, 1);
    });
  });

  test('disposing right after a close does not dispose the tab twice', () {
    // Closing a tab defers disposing its focus node by a frame; leaving the
    // page in that same frame used to dispose it a second time.
    final c = SessionTabsController<String>();
    final tab = c.add(preferred: 'a', build: (_, _, _) => 'a');
    c.remove(tab.id);
    c.dispose();

    // The deferred callback runs on the next frame; nothing should throw.
    expect(() => WidgetsBinding.instance.handleBeginFrame(null), returnsNormally);
    expect(() => WidgetsBinding.instance.handleDrawFrame(), returnsNormally);
  });

  testWidgets('only the selected session is marked visible', (tester) async {
    final c = SessionTabsController<String>(leadingName: '+');
    addTearDown(c.dispose);
    c.add(preferred: 'a', build: (_, _, _) => 'a');
    c.add(preferred: 'b', build: (_, _, _) => 'b');

    await tester.pumpWidget(
      MaterialApp(
        home: SessionTabsView<String>(
          controller: c,
          leading: const Text('add'),
          builder: (_, tab) => Text('page ${tab.name}'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    c.select(2);
    await tester.pumpAndSettle();

    expect(c.tabs[0].visible.value, isFalse);
    expect(
      c.tabs[1].visible.value,
      isTrue,
      reason: 'a background terminal should stop repainting',
    );
  });
}
