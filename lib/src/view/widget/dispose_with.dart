import 'package:flutter/widgets.dart';

/// Disposes [notifiers] when this leaves the tree, rather than when the code
/// that made them stops waiting.
///
/// For the controllers a dialog is built from. `showRoundDialog` — like
/// `showDialog` under it — completes when the route is **popped**, not when it
/// has finished going away, so the usual shape
///
/// ```dart
/// final controller = TextEditingController();
/// try {
///   return await context.showRoundDialog(child: Input(controller: controller));
/// } finally {
///   controller.dispose();
/// }
/// ```
///
/// tears the controller out from under a field that is still mounted and still
/// animating. `TextField` autofocused leaves a 167ms animation running in its
/// decoration; rebuilding that against a disposed controller is
/// "A TextEditingController was used after being disposed", and then "Tried to
/// build dirty widget in the wrong build scope" — a red screen, some of the
/// time, depending on how fast the answer came.
///
/// Not disposing at all is the other half of the same mistake: it does not
/// crash, so it survives review, and every dialog opened leaks its controller.
///
/// Wrapping the dialog's own child hands the question to the framework, which
/// already knows when the element is finished with.
///
/// [notifiers] is read once. A widget that needs to swap one out wants its own
/// [State], not this.
class DisposeWith extends StatefulWidget {
  const DisposeWith({super.key, required this.notifiers, required this.child});

  /// [TextEditingController] and [FocusNode] are both [ChangeNotifier]s, which
  /// is every case this exists for.
  final List<ChangeNotifier> notifiers;

  final Widget child;

  @override
  State<DisposeWith> createState() => _DisposeWithState();
}

class _DisposeWithState extends State<DisposeWith> {
  late final List<ChangeNotifier> _owned = widget.notifiers;

  @override
  void dispose() {
    for (final notifier in _owned) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
