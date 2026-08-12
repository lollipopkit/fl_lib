import 'package:flutter/material.dart';

/// One live page in a [SessionTabsController].
///
/// Holds the things a page needs that must outlive a rebuild: its focus, and
/// whether it is the visible one. A terminal cares about both — it takes
/// keystrokes only when focused, and stops repainting when it is not on
/// screen — and so does anything else expensive enough to be worth keeping
/// alive in the background.
class SessionTab<T> {
  SessionTab._({
    required this.id,
    required this.name,
    required this.focus,
    required this.visible,
  });

  /// Identity, and never reused within a controller.
  ///
  /// Separate from [name] because the name is a label: it is derived from
  /// whatever the session points at, it is freed when the tab closes, and the
  /// next session on the same target takes it back. Anything that remembers a
  /// tab across time — a callback fired when a connection finally ends, long
  /// after the tab was closed — would otherwise act on whichever tab happens
  /// to answer to that name now.
  final String id;

  /// Built by [SessionTabsController.add], which resolves the name and creates
  /// the focus and visibility first — a page usually needs all three to be
  /// constructed, so it cannot be handed in ready-made.
  late final T data;

  /// What the tab is labelled. Unique among the current tabs so two are
  /// tellable apart, but not stable over time — see [id].
  final String name;

  final FocusNode focus;

  final ValueNotifier<bool> visible;

  void dispose() {
    focus.dispose();
    visible.dispose();
  }
}

/// An ordered set of live pages, one visible at a time.
///
/// The parts worth sharing are the ones that are easy to get subtly wrong:
/// deriving a unique name when the same server is opened twice, and choosing
/// what to show after a tab in the middle is closed. Everything visual — the
/// tab bar, its buttons, what a session actually renders — stays with the
/// caller, because a terminal's bar and a file browser's have nothing in
/// common.
class SessionTabsController<T> extends ChangeNotifier {
  SessionTabsController({this.leadingName});

  /// Name of a fixed first tab that is not a session — the "new connection"
  /// page. Null when there is none.
  final String? leadingName;

  final _tabs = <SessionTab<T>>[];

  int _index = 0;

  /// Only ever increases, so a closed tab's id is never handed out again.
  int _nextId = 0;

  bool _disposed = false;

  /// The sessions, in tab order. Excludes the leading tab, which has no
  /// session behind it.
  List<SessionTab<T>> get tabs => List.unmodifiable(_tabs);

  /// Index into the page view, where 0 is the leading tab when there is one.
  int get index => _index;

  int get _offset => leadingName == null ? 0 : 1;

  /// Total pages including the leading one.
  int get length => _tabs.length + _offset;

  /// Names in tab order, leading tab included.
  List<String> get names => [
    ?leadingName,
    for (final tab in _tabs) tab.name,
  ];

  /// The tab with [id], or null once it has been closed.
  SessionTab<T>? byId(String id) {
    for (final tab in _tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  SessionTab<T>? get current {
    final i = _index - _offset;
    if (i < 0 || i >= _tabs.length) return null;
    return _tabs[i];
  }

  /// Adds a session and returns it.
  ///
  /// The name is [preferred] when free, and `preferred(n)` otherwise. Opening
  /// two shells on one server is ordinary, and two tabs with the same label
  /// would leave no way to say which is which.
  ///
  /// [build] receives what the controller had to decide first. A page that
  /// takes keystrokes needs the focus node, one that idles in the background
  /// needs the visibility, and anything that can close itself needs its own
  /// name to say which tab went away.
  SessionTab<T> add({
    required String preferred,
    required T Function(
      String name,
      FocusNode focus,
      ValueNotifier<bool> visible,
    )
    build,
  }) {
    final name = _uniqueName(preferred);
    final tab = SessionTab<T>._(
      id: '${_nextId++}',
      name: name,
      focus: FocusNode(debugLabel: name),
      visible: ValueNotifier(false),
    );
    tab.data = build(name, tab.focus, tab.visible);
    _tabs.add(tab);
    notifyListeners();
    return tab;
  }

  String _uniqueName(String preferred) {
    final taken = names.toSet();
    if (!taken.contains(preferred)) return preferred;
    for (var i = 1;; i++) {
      final candidate = '$preferred($i)';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  /// Removes the session with [id] and returns the index to show next.
  ///
  /// Closing a tab to the left of the visible one shifts it, so holding the
  /// index still would silently move the user to a neighbour.
  int remove(String id) {
    final at = _tabs.indexWhere((tab) => tab.id == id);
    if (at == -1) return _index;

    final removed = _tabs.removeAt(at);
    final pageIndex = at + _offset;
    if (_index > pageIndex) {
      _index -= 1;
    }
    // `length - 1` is -1 once the last tab of a controller with no leading tab
    // goes, and clamping to an empty range throws.
    _index = length == 0 ? 0 : _index.clamp(0, length - 1);

    notifyListeners();
    // After the frame: the page view is still building the list this entry is
    // in, and disposing its focus node now would be a use-after-free.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Unless the whole controller went first — closing a tab and leaving the
      // page in the same frame would otherwise dispose the entry twice.
      if (_disposed) return;
      removed.dispose();
    });
    return _index;
  }

  /// Selects by page index, leading tab included.
  void select(int index) {
    final next = index.clamp(0, length - 1);
    if (next == _index) return;
    _index = next;
    notifyListeners();
  }

  /// Marks exactly the selected session visible.
  void syncVisibility() {
    for (var i = 0; i < _tabs.length; i++) {
      _tabs[i].visible.value = i + _offset == _index;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}

/// The page view half of [SessionTabsController].
///
/// Swiping is off: these are tabs, and a terminal needs horizontal drags for
/// its own selection.
class SessionTabsView<T> extends StatefulWidget {
  const SessionTabsView({
    super.key,
    required this.controller,
    required this.builder,
    this.leading,
    this.duration = Durations.short3,
    this.curve = Curves.fastEaseInToSlowEaseOut,
  });

  final SessionTabsController<T> controller;

  final Widget Function(BuildContext context, SessionTab<T> tab) builder;

  /// The fixed first page, when [SessionTabsController.leadingName] is set.
  final Widget? leading;

  final Duration duration;
  final Curve curve;

  @override
  State<SessionTabsView<T>> createState() => _SessionTabsViewState<T>();
}

class _SessionTabsViewState<T> extends State<SessionTabsView<T>> {
  late final _pageCtrl = PageController(
    initialPage: widget.controller.index,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // The page list may have just grown or shrunk, so the animation target
    // does not exist until this build has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_pageCtrl.hasClients) return;
      final target = widget.controller.index;
      if (_pageCtrl.page?.round() == target) {
        widget.controller.syncVisibility();
        return;
      }
      await _pageCtrl.animateToPage(
        target,
        duration: widget.duration,
        curve: widget.curve,
      );
      if (!mounted) return;
      widget.controller.syncVisibility();
      final focus = widget.controller.current?.focus;
      if (focus != null) FocusScope.of(context).requestFocus(focus);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PageView.builder(
      controller: _pageCtrl,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: controller.length,
      onPageChanged: (index) {
        controller.select(index);
        controller.syncVisibility();
      },
      itemBuilder: (context, index) {
        final leading = widget.leading;
        if (leading != null && index == 0) return leading;
        final tab = controller.tabs[index - (leading != null ? 1 : 0)];
        return widget.builder(context, tab);
      },
    );
  }
}
