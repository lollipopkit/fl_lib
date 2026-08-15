import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

typedef IntroPageBuilder = Widget Function(BuildContext ctx, double padTop);

final class IntroPageArgs {
  final List<Widget> pages;
  final void Function(BuildContext context) onDone;

  /// Width of the content column the pages lay themselves out in.
  ///
  /// The bottom bar is bounded by it too, so the progress and the navigation
  /// buttons line up with the edges of the page content instead of drifting to
  /// the window edges. Pass whatever the pages use.
  final double maxWidth;

  const IntroPageArgs({
    required this.pages,
    required this.onDone,
    this.maxWidth = UIs.pageColumnWidth,
  });
}

final class IntroPage extends StatefulWidget {
  final IntroPageArgs args;

  const IntroPage({
    super.key,
    required this.args,
  });

  @override
  State<IntroPage> createState() => _IntroPageState();

  static const route = AppRouteArg<void, IntroPageArgs>(
    page: IntroPage.new,
    path: '/intro',
  );

  static Widget title({IconData? icon, String? text, bool big = false}) {
    assert(icon != null || text != null);

    Widget child;
    if (icon != null) {
      child = Icon(icon, size: big ? 41 : null);
    } else if (text != null) {
      child = Text(
        text,
        style: big
            ? const TextStyle(fontSize: 41, fontWeight: FontWeight.w500)
            : UIs.textGrey,
      );
    } else {
      child = const SizedBox();
    }
    if (!big) {
      child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: child,
      );
    }
    return Center(child: child);
  }
}

final class _IntroPageState extends State<IntroPage> {
  final _pageController = PageController();
  final _currentPage = 0.vn;

  /// Read through, never cached. The caller rebuilds these args whenever the
  /// layout changes — a rotation, a resized window, a keyboard appearing — and
  /// a copy taken at the first build would pin the page to whatever the first
  /// frame happened to measure. On desktop that frame is often before the
  /// window has its real size.
  IntroPageArgs get _args => widget.args;

  int get _pageCount => _args.pages.length;

  static const _switchDuration = Duration(milliseconds: 300);

  /// Below this the bar has no room for two labelled buttons beside the
  /// counter, and shows icons instead.
  ///
  /// The same number, measured off the same thing, as the `MOBILE` breakpoint
  /// this used to ask `ResponsiveBreakpoints` for — but read from
  /// `MediaQuery`, which is always there. Reading an inherited widget that
  /// only exists when the host app installed `ResponsivePoints.builder` made
  /// this public page throw for anyone who had not.
  static const _compactBarWidth = 600.0;

  @override
  void dispose() {
    _pageController.dispose();
    _currentPage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView.builder(
        controller: _pageController,
        itemCount: _pageCount,
        onPageChanged: (index) => _currentPage.value = index,
        itemBuilder: (_, index) => _args.pages[index],
      ),
      bottomNavigationBar: BottomAppBar(
        // The window, not the bar's own constraints: the bar is inset by its
        // own padding, which would put the switch a few pixels off from where
        // every other breakpoint in the app puts it.
        child: MediaQuery.sizeOf(context).width < _compactBarWidth
            ? _buildCompactBar(context)
            : _buildWideBar(context),
      ),
    );
  }

  /// What the forward button does and looks like, in one place.
  ///
  /// Both bars end the intro and both step forward; they differ only in
  /// chrome. Written twice, the two had already drifted apart on their keys,
  /// and a change to what "done" means would have had to be made in each.
  ({VoidCallback onPressed, IconData icon, String label}) _forward(
    BuildContext context,
  ) {
    final libL10n = context.libL10n;
    return (
      onPressed: hasNext ? _toNext : () => _args.onDone(context),
      icon: hasNext ? Icons.arrow_forward : Icons.done,
      label: hasNext ? libL10n.next : libL10n.done,
    );
  }

  /// Progress on the left, navigation grouped on the right, both bounded by
  /// the content column so they align with the page above.
  Widget _buildWideBar(BuildContext context) {
    final libL10n = context.libL10n;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _args.maxWidth),
        child: Row(
          children: [
            _buildProgress(context),
            const Spacer(),
            ListenBuilder(
              listenable: _currentPage,
              builder: () {
                final forward = _forward(context);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // No back arrow: the label says it, and the one directional
                    // glyph in the bar belongs to the action that moves
                    // forward.
                    if (hasPre) ...[
                      FadeIn(
                        child: TextButton(
                          onPressed: _toPre,
                          child: Text(libL10n.previous),
                        ),
                      ),
                      UIs.width7,
                    ],
                    FadeIn(
                      key: ValueKey(hasNext),
                      child: FilledButton(
                        onPressed: forward.onPressed,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(forward.label),
                            UIs.width7,
                            Icon(forward.icon, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactBar(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        ListenBuilder(
          listenable: _currentPage,
          builder: () {
            if (!hasPre) return UIs.placeholder;
            return FadeIn(
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _toPre,
              ),
            );
          },
        ).expanded(),
        Center(child: _buildProgress(context)).expanded(),
        ListenBuilder(
          listenable: _currentPage,
          builder: () {
            final forward = _forward(context);
            return FadeIn(
              // The same key the wide bar uses, so the two agree on when the
              // button is a new one to fade in.
              key: ValueKey(hasNext),
              child: IconButton(
                icon: Icon(forward.icon),
                tooltip: forward.label,
                onPressed: forward.onPressed,
              ),
            );
          },
        ).expanded(),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    // `1 / 1` states nothing the page doesn't already show.
    if (_pageCount <= 1) return UIs.placeholder;

    final scheme = Theme.of(context).colorScheme;

    return ValBuilder(
      listenable: _currentPage,
      builder: (idx) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeIn(
              key: ValueKey(idx),
              child: Text(
                '${idx + 1}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
            Text(
              ' / $_pageCount',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }

  void _toPre() => _pageController.previousPage(
    duration: _switchDuration,
    curve: Curves.easeInOut,
  );

  void _toNext() => _pageController.nextPage(
    duration: _switchDuration,
    curve: Curves.easeInOut,
  );

  bool get hasPre => _currentPage.value > 0;
  bool get hasNext => _currentPage.value < _pageCount - 1;
}
