part of 'toast.dart';

/// Where the toasts are drawn.
///
/// Wrap it around the app in `MaterialApp.builder`, so that the stack sits
/// above every route and dialog and still finds a [Theme], a [Directionality]
/// and a [MediaQuery]:
///
/// ```dart
/// MaterialApp(
///   builder: (ctx, child) => ToastHost(child: child),
/// )
/// ```
class ToastHost extends StatefulWidget {
  /// The app.
  final Widget child;

  const ToastHost({super.key, required this.child});

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  @override
  void initState() {
    super.initState();
    _ToastCtrl.hosts++;
  }

  @override
  void dispose() {
    _ToastCtrl.hosts--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The host only wraps the app; it must not change how the app is
      // measured, so the incoming constraints go through untouched.
      fit: StackFit.passthrough,
      children: [widget.child, const _ToastLayer()],
    );
  }
}

class _ToastLayer extends StatelessWidget {
  const _ToastLayer();

  @override
  Widget build(BuildContext context) {
    return ValBuilder(
      listenable: _ToastCtrl.entries,
      builder: (entries) {
        if (entries.isEmpty) return UIs.placeholder;

        final align = ToastConfig.align;
        final margin = ToastConfig.margin;
        final dir = Directionality.of(context);
        final ltr = dir == TextDirection.ltr;
        final mediaQuery = MediaQuery.of(context);
        final safe = mediaQuery.padding;

        final width = math.min(
          ToastConfig.maxWidth,
          mediaQuery.size.width - margin.horizontal - safe.horizontal,
        );

        // On Windows and Linux the virtual window frame draws the minimize and
        // close buttons across the top; a toast in that band would sit on them.
        final caption = WindowFrameConfig.showCaption ? CustomAppBar.sysStatusBarHeight : 0.0;

        return Positioned.directional(
          textDirection: dir,
          top: align.isTop ? safe.top + caption + margin.top : null,
          bottom: align.isTop ? null : safe.bottom + margin.bottom,
          start: align.isEnd ? null : (ltr ? safe.left + margin.left : safe.right + margin.right),
          end: align.isEnd ? (ltr ? safe.right + margin.right : safe.left + margin.left) : null,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in entries)
                  _ToastItem(key: ValueKey(entry.id), entry: entry, width: width),
              ],
            ),
          ),
        );
      },
    );
  }
}
