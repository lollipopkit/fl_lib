part of 'toast.dart';

/// A single toast.
class _ToastItem extends StatefulWidget {
  final _ToastEntry entry;

  /// Width of the stack. Known here rather than measured, because whether the
  /// title fits on one line has to be decided before the row is laid out.
  final double width;

  const _ToastItem({super.key, required this.entry, required this.width});

  @override
  State<_ToastItem> createState() => _ToastItemState();
}

class _ToastItemState extends State<_ToastItem> with SingleTickerProviderStateMixin {
  static const _animeDuration = Duration(milliseconds: 240);
  static const _radius = BorderRadius.all(Radius.circular(11));
  static const _padding = EdgeInsets.symmetric(horizontal: 12, vertical: 10);
  static const _gap = 8.0;
  static const _iconSize = 18.0;
  static const _lineHeight = 18.0;
  static const _chevronSlot = _iconSize + _gap;
  static const _titleStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, height: 1.3);

  late final AnimationController _anime;
  late final CurvedAnimation _curve;
  late final Animation<Offset> _slide;

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
    _slide = Tween<Offset>(
      begin: Offset(ToastConfig.align.isEnd ? 0.25 : -0.25, 0),
      end: Offset.zero,
    ).animate(_curve);

    _anime.forward();
    _restartTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expandable = _computeExpandable();
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
    _anime.dispose();
    super.dispose();
  }

  // -- Actions --

  /// The countdown restarts rather than resumes once the toast is released.
  /// Pausing it means the user is reading; a message that vanishes half a
  /// second after the pointer leaves has not been read.
  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final duration = _data.duration;
    if (duration <= Duration.zero || _expanded || _hovering) return;
    _timer = Timer(duration, () => _ToastCtrl.dismiss(widget.entry));
  }

  void _onDismissing() {
    if (!widget.entry.dismissing.value) return;
    _timer?.cancel();
    // Removed only after the exit animation, so that the toasts below it slide
    // up instead of jumping.
    _anime.reverse().whenCompleteOrCancel(() => _ToastCtrl.remove(widget.entry));
  }

  void _onHover(bool hovering) {
    _hovering = hovering;
    _restartTimer();
  }

  void _toggleExpand() {
    if (!_expandable) return;
    setState(() => _expanded = !_expanded);
    _restartTimer();
  }

  void _onTap() {
    final onTap = _data.onTap;
    if (onTap != null) return onTap();
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

  // -- Widget build --

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _data.accentColor(context);

    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topLeft,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: _slide,
          child: Padding(
            padding: const EdgeInsets.only(bottom: _gap),
            child: Dismissible(
              key: ValueKey('toast_${widget.entry.id}'),
              direction: DismissDirection.horizontal,
              onDismissed: (_) => _ToastCtrl.remove(widget.entry),
              child: MouseRegion(
                onEnter: (_) => _onHover(true),
                onExit: (_) => _onHover(false),
                child: _buildCard(theme, accent),
              ),
            ),
          ),
        ),
      ),
    );
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
        onTap: _data.onTap != null || _expandable ? _onTap : null,
        onLongPress: _onLongPress,
        child: Padding(padding: _padding, child: _buildContent(theme, accent)),
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
                    maxLines: _expanded ? null : 1,
                    overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                  ),
                  if (_expanded && body != null) ...[
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
        if (_expandable) ...[
          const SizedBox(width: _gap),
          // Its own target rather than the whole card: when the call site took
          // the tap over with `onTap`, this is the only way left to open it.
          SizedBox(
            height: _lineHeight,
            child: InkResponse(
              onTap: _toggleExpand,
              radius: 16,
              child: AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
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
