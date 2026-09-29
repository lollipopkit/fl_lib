// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';

const _level2Color = {
  'INFO': Colors.cyan,
  'WARNING': Colors.yellow,
  'ERROR': Color(0xffbb2d6f),
};

/// Captures logs and ad-hoc debug messages into in-app widgets and lines.
///
/// Maintains a bounded list of rich [widgets] and plain [lines] that you can
/// render in a debug console page. Integrates with [Logger] records and with
/// [lprint]/[dprint] via [DebugProvider.addString].
final class DebugProvider {
  static const int maxLines = 100;
  static final widgets = <Widget>[].vn;
  static final lines = <String>[];

  /// Append a [LogRecord] into the debug console.
  static void addLog(LogRecord record) {
    final color = _level2Color[record.level.name] ?? Colors.blue;
    final title = '[${DateTime.now().hourMinute}][${record.loggerName}]';
    final level = '[${record.level}]';
    final message = record.error == null
        ? '\n${record.message}'
        : '\n${record.message}: ${record.error}';
    lines.add('$title$level$message');
    widgets.value.add(Text.rich(TextSpan(
      children: [
        TextSpan(text: title, style: TextStyle(color: color)),
        TextSpan(text: level, style: TextStyle(color: color)),
        TextSpan(
          text: message,
          style: const TextStyle(color: Colors.white),
        ),
      ],
    )));
    if (record.stackTrace != null) {
      widgets.value.add(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          '${record.stackTrace}',
          style: const TextStyle(color: Colors.white),
        ),
      ));
    }
    widgets.value.add(UIs.height13);
    if (widgets.value.length > maxLines) {
      widgets.value.removeRange(0, widgets.value.length - maxLines);
    }
    widgets.notify();

    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
    }
  }

  /// Append a plain [message] string into the debug console.
  static void addString(String message) {
    final title = '[${DateTime.now().hourMinute}][Debug]';
    lines.add('$title: $message');
    widgets.value.add(Text.rich(TextSpan(
      children: [
        TextSpan(text: title, style: const TextStyle(color: Color(0xff8b2252))),
        TextSpan(text: '\n$message', style: const TextStyle(color: Colors.white)),
      ],
    )));
    widgets.value.add(UIs.height13);
    if (widgets.value.length > maxLines) {
      widgets.value.removeRange(0, widgets.value.length - maxLines);
    }
    widgets.notify();

    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
    }
  }

  /// Clear all cached widgets and lines.
  static void clear() {
    widgets.value.clear();
    lines.clear();
    widgets.notify();
  }

  /// Copy all lines to the clipboard.
  static void copy() => Pfs.copy(lines.join('\n'));
}
