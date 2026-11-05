import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

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

  static Widget title({
    IconData? icon,
    String? text,
    bool big = false,
    Widget? mark,
  }) {
    assert(icon != null || text != null);

    Widget child;
    if (icon != null) {
      child = Icon(icon, size: big ? 41 : null);
    } else if (text != null) {
      // The mark rides the last line of the title rather than sitting after
      // the block: a heading is one or two lines depending on the width it is
      // given, and beside the block it would sit against the shorter of them.
      child = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              text,
              style: big
                  ? const TextStyle(fontSize: 41, fontWeight: FontWeight.w500)
                  : UIs.textGrey,
            ),
          ),
          if (mark case final mark?) ...[const SizedBox(width: 9), mark],
        ],
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

  static const _switchDuration = Duration(milliseconds: 377);
  static const _switchCurve = Curves.easeOutCubic;
  static const _barHeight = 61.6;
  static const _progressHeight = 3.0;

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
      bottomNavigationBar: _buildBar(context),
    );
  }

  /// Progress across the top edge, then previous · counter · next in the
  /// content column. One layout at every width: the labels fit a phone.
  Widget _buildBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgress(context),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _args.maxWidth),
                child: SizedBox(
                  height: _barHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    child: ListenBuilder(
                      listenable: _currentPage,
                      builder: () => Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: _buildPrevious(context),
                            ),
                          ),
                          _buildCounter(context),
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: _buildNext(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Faded rather than removed on the first page, so the counter and the next
  /// button do not move when it appears.
  Widget _buildPrevious(BuildContext context) {
    return AnimatedOpacity(
      opacity: hasPre ? 1 : 0,
      duration: context.motion(Durations.short4),
      child: IgnorePointer(
        ignoring: !hasPre,
        child: ExcludeSemantics(
          excluding: !hasPre,
          child: TextButton(
            onPressed: _toPre,
            child: Text(context.libL10n.previous, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  Widget _buildNext(BuildContext context) {
    final libL10n = context.libL10n;
    return FilledButton(
      onPressed: hasNext ? _toNext : () => _args.onDone(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              hasNext ? libL10n.next : libL10n.done,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          UIs.width7,
          Icon(hasNext ? Icons.arrow_forward : Icons.done, size: 18),
        ],
      ),
    );
  }

  Widget _buildCounter(BuildContext context) {
    // `1 / 1` states nothing the page doesn't already show.
    if (_pageCount <= 1) return UIs.placeholder;
    final scheme = Theme.of(context).colorScheme;
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${_currentPage.value + 1}'),
            TextSpan(
              text: '/$_pageCount',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }

  /// A track filled to the current page; a hairline when there is one page.
  Widget _buildProgress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_pageCount <= 1) {
      return Container(height: Hairline.thickness, color: Hairline.color(context));
    }
    return ValBuilder(
      listenable: _currentPage,
      builder: (idx) => TweenAnimationBuilder<double>(
        tween: Tween(end: (idx + 1) / _pageCount),
        duration: context.motion(_switchDuration),
        curve: _switchCurve,
        builder: (_, value, _) => Container(
          height: _progressHeight,
          color: scheme.surfaceContainerHighest,
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: value,
            child: ColoredBox(color: scheme.primary, child: const SizedBox.expand()),
          ),
        ),
      ),
    );
  }

  void _toPre() => _pageController.previousPage(
    duration: context.motion(_switchDuration),
    curve: _switchCurve,
  );

  void _toNext() => _pageController.nextPage(
    duration: context.motion(_switchDuration),
    curve: _switchCurve,
  );

  bool get hasPre => _currentPage.value > 0;
  bool get hasNext => _currentPage.value < _pageCount - 1;
}
