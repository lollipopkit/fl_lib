import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

/// Display error and stack trace in a markdown view.
///
/// eg.:
/// ```dart
/// ErrorView.error('Error message');
/// ErrorView.es('Error message', StackTrace.current);
/// ```
final class ErrorView extends StatelessWidget {
  /// Error object.
  final Object? error;

  /// Stack trace. Optional.
  final StackTrace? stackTrace;

  /// - [e] is the error object.
  const ErrorView.error(Object? e, {super.key})
      : error = e,
        stackTrace = null;

  /// - [e] is the error object.
  /// - [s] is the stack trace.
  const ErrorView.es(Object? e, StackTrace? s, {super.key})
      : error = e,
        stackTrace = s;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SimpleMarkdown(data: '$error\n```\n$stackTrace\n```'),
    );
  }
}
