part of 'toast.dart';

/// A single toast.
class _ToastItem extends StatefulWidget {
  final _ToastEntry entry;

  /// Width of the stack. Known here rather than measured, because whether the
  /// title fits on one line has to be decided before the row is laid out.
  final double width;

  /// 0 is the front of the pile, the newest toast.
  final int depth;

  /// 0 piled, 1 opened. Drives what the depth is drawn as.
  final double open;

  /// Whether there is more than one toast, and so a pile at all.
  final bool piled;

  /// Whether a tap may open the body. False while piled, where a tap means the
  /// pile instead.
  final bool bodyAllowed;

  /// Whether the countdown is held, because the pile is open and being read.
  final bool paused;

  /// Opens or closes the pile. Null when there is only this one toast.
  final VoidCallback? onPileToggle;

  const _ToastItem({
    super.key,
    required this.entry,
    required this.width,
    required this.depth,
    required this.open,
    required this.piled,
    required this.bodyAllowed,
    required this.paused,
    required this.onPileToggle,
  });

  @override
  State<_ToastItem> createState() => _ToastItemState();
}

class _ToastItemState extends State<_ToastItem> with TickerProviderStateMixin {
  static const _animeDuration = Duration(milliseconds: 240);
  static const _radius = BorderRadius.all(Radius.circular(11));
  static const _padding = EdgeInsets.symmetric(horizontal: 12, vertical: 10);
  static const _gap = 8.0;
  static const _iconSize = 18.0;
  static const _lineHeight = 18.0;
  static const _chevronSlot = _iconSize + _gap;
  static const _barHeight = 1.0;
  static const _titleStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, height: 1.3);

  late final AnimationController _anime;

  /// Height and opacity, which cannot overshoot.
  late final CurvedAnimation _curve;

  /// Displacement, which springs past its mark and settles back.
  late final CurvedAnimation _slideCurve;

  late final Animation<Offset> _slide;

  /// Drives the countdown bar only. The dismissal itself is a [Timer]: a ticker
  /// is muted while the window is not being drawn, and how long a message stays
  /// should not depend on that.
  late final AnimationController _countdown;

  Timer? _timer;
  Timer? _copiedTimer;
  late bool _expanded = _data.expanded;
  var _hovering = false;
  var _copied = false;
  var _expandable = false;

  ToastData get _data => widget.entry.data;

  @override
  void initState() {
    super.initState();
    widget.entry.mounted = true;
    widget.entry.dismissing.addListener(_onDismissing);

    _anime = AnimationController(vsync: this, duration: _animeDuration);
    _curve = CurvedAnimation(
      parent: _anime,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slideCurve = CurvedAnimation(
      parent: _anime,
      curve: _kSpring,
      reverseCurve: Curves.easeInCubic,
    );
    // In from the edge it is pinned to. The dx is in logical direction — the
    // `SlideTransition` below is given the text direction and flips it in RTL.
    _slide = Tween<Offset>(
      begin: switch (ToastConfig.align) {
        ToastAlign.topEnd || ToastAlign.bottomEnd => const Offset(0.25, 0),
        ToastAlign.topStart || ToastAlign.bottomStart => const Offset(-0.25, 0),
        ToastAlign.topCenter => const Offset(0, -0.4),
        ToastAlign.bottomCenter => const Offset(0, 0.4),
      },
      end: Offset.zero,
    ).animate(_slideCurve);

    _countdown = AnimationController(vsync: this, duration: _data.duration);

    _anime.forward();
    _restartTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expandable = _computeExpandable();
  }

  @override
  void didUpdateWidget(_ToastItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Opening the pile holds every countdown in it, and closing it releases
    // them again — as does a body that is no longer reachable.
    if (widget.paused != oldWidget.paused || widget.bodyAllowed != oldWidget.bodyAllowed) {
      _restartTimer();
    }
  }

  @override
  void dispose() {
    // Back to unowned. An entry whose host went away has nothing left to play
    // its exit animation, and must be droppable outright.
    widget.entry.mounted = false;
    widget.entry.dismissing.removeListener(_onDismissing);
    _timer?.cancel();
    _copiedTimer?.cancel();
    _curve.dispose();
    _slideCurve.dispose();
    _countdown.dispose();
    _anime.dispose();
    super.dispose();
  }

  // -- Actions --

  /// The countdown restarts rather than resumes once the toast is released.
  /// Pausing it means the user is reading; a message that vanishes half a
  /// second after the pointer leaves has not been read. The bar going back to
  /// full is what says so.
  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final duration = _data.duration;
    if (duration <= Duration.zero) return;
    if (_isExpanded || _hovering || widget.paused) {
      _countdown.stop();
      _countdown.value = 0;
      return;
    }
    _timer = Timer(duration, () => _ToastCtrl.dismiss(widget.entry));
    _countdown.forward(from: 0);
  }

  void _onDismissing() {
    if (!widget.entry.dismissing.value) return;
    _timer?.cancel();
    _countdown.stop();
    // Removed only after the exit animation, so that the toasts below it slide
    // up instead of jumping.
    _anime.reverse().whenCompleteOrCancel(() => _ToastCtrl.remove(widget.entry));
  }

  void _onHover(bool hovering) {
    _hovering = hovering;
    _restartTimer();
  }

  void _toggleExpand() {
    if (!_canOpenBody) return;
    setState(() => _expanded = !_expanded);
    _restartTimer();
  }

  /// A tap on the card itself.
  ///
  /// Every gesture has one meaning at a time: a pile answers with the pile, and
  /// only once it is open does a tap on one of its toasts mean that toast's
  /// body. [ToastData.onTap] takes precedence over both, being explicit.
  void _onTap() {
    final onTap = _data.onTap;
    if (onTap != null) return onTap();
    final togglePile = widget.onPileToggle;
    if (togglePile != null) return togglePile();
    _toggleExpand();
  }

  void _onLongPress() {
    Pfs.copy(_data.textToCopy);
    HapticFeedback.mediumImpact();

    // Desktop has no haptics, so the toast says it itself.
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _onAction() {
    final action = _data.action;
    if (action == null) return;
    if (action.dismissOnTap) _ToastCtrl.dismiss(widget.entry);
    action.onTap();
  }

  // -- Utils --

  /// Whether the body is showing. [_expanded] is what the user asked for;
  /// while piled there is no room to honour it.
  bool get _isExpanded => _expanded && widget.bodyAllowed;

  /// Whether a body can be opened at all right now.
  bool get _canOpenBody => _expandable && widget.bodyAllowed;

  /// Whether there is anything to reveal.
  ///
  /// A body, or a title too long for one line: `Toast.show('$e')` has nowhere
  /// else to put the rest of the exception, and it is the shape most call sites
  /// have. Not measured when there is an action button, whose width is not
  /// known before layout.
  bool _computeExpandable() {
    final data = _data;
    if (data.content != null) return false;
    if (data.body != null) return true;
    if (data.action != null) return false;

    final hasLeading = data.leading != null || data.iconData != null;
    final available = widget.width - _padding.horizontal - (hasLeading ? _iconSize + _gap : 0) - _chevronSlot;
    if (available <= 0) return false;

    final painter = TextPainter(
      text: TextSpan(text: data.title, style: _titleStyle),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: available);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return exceeded;
  }

  /// Outwards only, the way it came in.
  ///
  /// Dragging a toast in the end corner towards the middle of the window is a
  /// drag across the content it covers, and there is no edge that way. For one
  /// pinned to no side edge the only way out is up or down.
  ///
  /// `startToEnd` and `endToStart` are resolved against the text direction, as
  /// [ToastAlign.isEnd] is, so this holds in RTL too.
  static DismissDirection get _dismissDirection {
    final align = ToastConfig.align;
    if (align.isEnd) return DismissDirection.startToEnd;
    if (align.isStart) return DismissDirection.endToStart;
    return align.isTop ? DismissDirection.up : DismissDirection.down;
  }

  // -- Widget build --

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _data.accentColor(context);
    final fromTop = ToastConfig.align.isTop;
    final depth = widget.depth;

    Widget card = SizeTransition(
      sizeFactor: _curve,
      // Grows from the edge the stack hangs from, so what is already there does
      // not shift as this one arrives.
      alignment: fromTop ? Alignment.topLeft : Alignment.bottomLeft,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: _slide,
          textDirection: Directionality.of(context),
          child: Dismissible(
            key: ValueKey('toast_${widget.entry.id}'),
            direction: _dismissDirection,
            onDismissed: (_) => _ToastCtrl.remove(widget.entry),
            child: MouseRegion(
              onEnter: (_) => _onHover(true),
              onExit: (_) => _onHover(false),
              child: _buildCard(theme, accent),
            ),
          ),
        ),
      ),
    );

    // Behind the front of the pile: drawn a little smaller, and past the peek
    // limit not drawn at all. Both settle to normal as the pile opens. Neither
    // is a layout change, so the pile still measures the full height it will
    // need once open.
    if (depth > 0) {
      final opacity = depth <= _kMaxPeek ? 1.0 : widget.open;
      if (opacity < 1) card = Opacity(opacity: opacity, child: card);
      card = Transform.scale(
        scale: _lerp(1 - depth * _kPileScaleStep, 1, widget.open),
        alignment: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
        child: card,
      );
      // Under the front of a closed pile, where there is nothing to hit.
      if (widget.piled && !widget.bodyAllowed) card = IgnorePointer(child: card);
    }

    return card;
  }

  Widget _buildCard(ThemeData theme, Color accent) {
    final scheme = theme.colorScheme;
    final surface = scheme.surfaceContainerHigh;
    final tinted = _data.color == null && _data.level == ToastLevel.none
        ? surface
        : Color.alphaBlend(accent.withValues(alpha: 0.08), surface);

    return Material(
      color: tinted,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: _radius,
        side: BorderSide(
          color: _copied ? accent : scheme.outlineVariant.withValues(alpha: 0.5),
          width: _copied ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: _data.onTap != null || widget.onPileToggle != null || _canOpenBody ? _onTap : null,
        onLongPress: _onLongPress,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: _padding, child: _buildContent(theme, accent)),
            _buildCountdown(accent),
          ],
        ),
      ),
    );
  }

  /// How long is left, along the bottom edge.
  Widget _buildCountdown(Color accent) {
    if (_data.duration <= Duration.zero) return UIs.placeholder;

    return SizedBox(
      height: _barHeight,
      child: ValBuilder(
        listenable: _countdown,
        builder: (value) => FractionallySizedBox(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1 - value,
          child: ColoredBox(color: accent),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, Color accent) {
    final data = _data;
    final content = data.content;
    final icon = data.iconData;
    final leading = data.leading ?? (icon == null ? null : Icon(icon, size: _iconSize, color: accent));
    final action = data.action;
    final body = data.body;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[
          SizedBox(width: _iconSize, height: _lineHeight, child: Center(child: leading)),
          const SizedBox(width: _gap),
        ],
        Expanded(
          child: content ??
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    style: _titleStyle,
                    maxLines: _isExpanded ? null : 1,
                    overflow: _isExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
                  ),
                  if (_isExpanded && body != null) ...[
                    const SizedBox(height: 5),
                    Text(body, style: UIs.text12Grey),
                  ],
                ],
              ),
        ),
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: TextButton(
              onPressed: _onAction,
              style: TextButton.styleFrom(
                foregroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(action.label, style: UIs.text12),
            ),
          ),
        if (_canOpenBody) ...[
          const SizedBox(width: _gap),
          // Its own target rather than the whole card: when the call site took
          // the tap over with `onTap`, this is the only way left to open it.
          SizedBox(
            height: _lineHeight,
            child: InkResponse(
              onTap: _toggleExpand,
              radius: 16,
              child: AnimatedRotation(
                turns: _isExpanded ? 0.5 : 0,
                duration: Durations.short3,
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: _iconSize,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
