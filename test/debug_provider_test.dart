import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('a copied record keeps the stack trace the page shows', () {
    final stack = StackTrace.fromString('#0 main (test.dart:1)');
    DebugProvider.addLog(
      LogRecord(Level.SEVERE, 'Zone error', 'App', StateError('x'), stack),
    );
    expect(
      DebugProvider.lines.last,
      endsWith('Zone error: Bad state: x\n$stack'),
    );

    DebugProvider.addLog(LogRecord(Level.INFO, 'plain', 'App'));
    expect(DebugProvider.lines.last, endsWith('\nplain'));
  });
}
