import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:choice/choice.dart';
import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:icons_plus/icons_plus.dart';

extension SheetX on BuildContext {
  /// The sheets [showSheet] raised that are on screen, the newest last.
  static final _open = <SheetStack>[];

  /// The sheet in front of everything else, if one is.
  static ModalRoute<Object?>? get topSheet => frontSheet?.route;

  /// The pages of [topSheet].
  static SheetStack? get frontSheet {
    final stack = _open.lastOrNull;
    return stack != null && stack.route.isCurrent ? stack : null;
  }

  /// A bottom sheet with a title, content, and actions: a [PromptSheet] in a
  /// [showResizableSheet], on the root navigator — one on the nearest is
  /// clipped to whatever pane raised it.
  ///
  /// - [dismissible] false keeps it open against the barrier and a drag.
  /// - [titleBuilder], [childBuilder], and [actionsBuilder] override their
  ///   corresponding values when provided, with the sheet's own context.
  /// - [onShown] is handed what closes this sheet and nothing else — not a
  ///   page raised over it meanwhile — from any context: for one that closes
  ///   itself, a progress.
  ///
  /// Closed by [ContextX.popSheet].
  Future<T?> showSheet<T>({
    Widget? child,
    List<Widget>? actions,
    String? title,
    bool dismissible = true,
    int? titleMaxLines,
    EdgeInsetsGeometry actionsPadding = PromptSheet.defaultActionsPadding,
    EdgeInsetsGeometry contentPadding = PromptSheet.defaultContentPadding,
    Widget? Function(BuildContext ctx)? titleBuilder,
    Widget? Function(BuildContext ctx)? childBuilder,
    List<Widget>? Function(BuildContext ctx)? actionsBuilder,
    ValueSetter<VoidCallback>? onShown,
  }) {
    return _raise<T>(
      dismissible: dismissible,
      onShown: onShown,
      builder: (ctx) => PromptSheet(
        title: switch (titleBuilder) {
          null => title != null ? Text(title, maxLines: titleMaxLines) : null,
          _ => titleBuilder(ctx),
        },
        actions: actionsBuilder?.call(ctx) ?? actions,
        contentPadding: contentPadding,
        actionsPadding: actionsPadding,
        child: childBuilder?.call(ctx) ?? child,
      ),
    );
  }

  /// Raises [builder] in a sheet on the root navigator, kept in [_open] while
  /// it is up so [ContextX.popSheet] finds it from a context gone since.
  ///
  /// With one of these sheets in front, [builder] is its next page instead —
  /// decided by what is in front rather than by this context, which is most
  /// often the page's, not the sheet's.
  Future<T?> _raise<T>({
    required WidgetBuilder builder,
    bool dismissible = true,
    double restLimit = PromptSheet.restLimit,
    ValueSetter<VoidCallback>? onShown,
  }) async {
    if (!mounted) return null;

    if (frontSheet case final front?) {
      final (page, answered) = front.push(
        builder,
        dismissible: dismissible,
        restLimit: restLimit,
      );
      onShown?.call(() => front.remove(page));
      final result = await answered;
      return result is T ? result : null;
    }

    final (stack, popped) = SheetStack.raise(
      this,
      builder: builder,
      dismissible: dismissible,
      restLimit: restLimit,
    );
    onShown?.call(() => stack.remove(stack.first));
    _open.add(stack);
    final Object? result;
    try {
      result = await popped;
    } finally {
      _open.remove(stack);
    }
    try {
      // Answered once the sheet is off the screen, not when it starts to
      // leave: its exit still builds what it holds, and what a caller does
      // next — disposing a field's controller — must not be under it. The
      // pages over the first answer before it does, innermost first. This
      // waits for frames: a paused app answers on resume.
      await stack.route.completed;
      for (final answered in stack.ended()) {
        await answered;
      }
    } finally {
      stack
        ..released()
        ..dispose();
    }
    // The route is untyped: a page over the first pops its own type through
    // it.
    return result is T ? result : null;
  }

  /// [timeout] is the timeout of the Future [fn] (default `null`).
  ///
  /// If an error occurs:
  /// - the sheet will be closed and an error sheet will be displayed
  /// - the [onErr] function will be called (awaited)
  /// - the return value will be `null`
  ///
  /// [showErr] false leaves saying the error to the caller.
  Future<FnRes<T>> showLoadingSheet<T>({
    required Future<T> Function() fn,
    bool dismissible = false,
    bool showErr = true,
    FutureOr<void> Function(Object e, StackTrace s)? onErr,
    Duration? timeout = const Duration(seconds: 17),
  }) async {
    // Closed by its own handle: a page raised over it while [fn] runs — a
    // password asked from inside it — is not what ends here, and a pop of the
    // top would leave this one up, holding back.
    VoidCallback? close;
    _raise<void>(
      dismissible: dismissible,
      onShown: (c) => close = c,
      builder: (_) => const PromptSheet(
        child: Center(heightFactor: 1, child: SizedLoading.medium),
      ),
    );

    return Resx.tryCatch(
      () async {
        final ret = switch (timeout) {
          null => await fn(),
          _ => await fn().timeout(timeout),
        };
        close?.call();
        return ret;
      },
      onErr: (e, s) {
        close?.call();
        if (showErr) showErrSheet(e, s);
        onErr?.call(e, s);
      },
    );
  }

  /// A sheet with one field, answered with what was typed — by OK or by
  /// submitting the field — or null.
  Future<String?> showInputSheet({
    String? title,
    String? initial,
    String? label,
    String? hint,
    IconData? icon,
    TextInputType? type,
    bool obscureText = false,
    int maxLines = 1,
    int? minLines,
  }) {
    // Made by the sheet, which owns it: a context gone already raises none.
    TextEditingController? made;
    TextEditingController ctrl() => made ??= TextEditingController(text: initial);
    return showSheet<String>(
      title: title,
      childBuilder: (ctx) => DisposeWith(
        notifiers: [ctrl()],
        child: Input(
          controller: ctrl(),
          autoFocus: true,
          type: type,
          obscureText: obscureText,
          maxLines: maxLines,
          minLines: minLines,
          icon: icon,
          hint: hint,
          // Empty is no label: an empty one would still take the room a label
          // floats into, and push the text below the middle of the field.
          label: label == null || label.isEmpty ? null : label,
          onSubmitted: (val) => ctx.popSheet(val),
        ),
      ),
      actionsBuilder: (ctx) => [
        Btn.cancel(),
        Btn.ok(onTap: () => ctx.popSheet(ctrl().text)),
      ],
    );
  }

  static final _recoredPwd = <String, String>{};

  /// [showInputSheet] for a password.
  ///
  /// - [id] is the key to record the password.
  /// - [remember] if true, the password will be recorded. Only works when [id] is not null.
  Future<String?> showPwdSheet({String? title, String? label, String? id, bool remember = true}) async {
    final pwd = await showInputSheet(
      title: title,
      initial: _recoredPwd[id],
      type: TextInputType.visiblePassword,
      obscureText: true,
      label: label == null || label.isEmpty ? l10n.pwd : label,
    );
    if (pwd != null && remember && id != null) _recoredPwd[id] = pwd;
    return pwd;
  }

  /// Show a sheet to pick a value from a list.
  ///
  /// - [title] is the title of the sheet.
  /// - [items] is the list of items to pick.
  /// - [display] is the function to display the item.
  /// - [multi] if true, the user can pick multiple items.
  /// - [initial] is the initial value(s) of the sheet.
  /// - [clearable] if true, the user can clear the selected items.
  /// - [actions] is the list of actions.
  /// - [addOkBtn] if true, the sheet will have an OK button.
  /// - [showLoading] is the state to show the loading.
  /// - [ascend] is the state to sort the items.
  Future<List<T>?> showPickSheet<T>({
    String? title,
    required List<T> items,
    String Function(T)? display,
    Widget? Function(T)? avatar,
    bool multi = true,
    List<T>? initial,
    bool clearable = false,
    List<Widget>? actions,
    bool addOkBtn = true,
    VNode<bool>? showLoading,
    VNode<bool>? ascend,
  }) async {
    var vals = initial ?? <T>[];
    // A list of its own: the caller's may be reused for the next sheet, or
    // const, and appending to it would grow it by an OK each time or throw.
    final btns = <Widget>[
      ...?actions,
      if (multi && addOkBtn) TextButton(onPressed: () => popSheet(true), child: Text(l10n.ok)),
    ];

    final loading = showLoading ?? false.vn;
    final asc = ascend ?? nvn<bool>();
    final sure = await _raise<bool>(
      // A list, which scrolls: as tall as every other one.
      restLimit: ResizableSheet.restFactor,
      builder: (_) => PickSheet<T>(
        title: title,
        items: items,
        initial: vals,
        onChanged: (value) => vals = value,
        display: display,
        avatar: avatar,
        multi: multi,
        clearable: clearable,
        actions: btns,
        showLoading: loading,
        ascend: asc,
      ),
    );
    return sure == true ? vals : null;
  }

  /// Show a sheet to pick a single value from a list.
  ///
  /// - [title] is the title of the sheet.
  /// - [items] is the list of items to pick.
  /// - [display] is the function to display the item.
  /// - [initial] is the initial value of the sheet.
  /// - [clearable] if true, the user can clear the selected item.
  /// - [actions] is the list of actions.
  /// - [addOkBtn] if true, the sheet will have an OK button.
  /// - [showLoading] is the state to show the loading.
  Future<T?> showPickSingleSheet<T>({
    String? title,
    required List<T> items,
    String Function(T)? display,
    Widget? Function(T)? avatar,
    T? initial,
    bool clearable = false,
    List<Widget>? actions,
    bool addOkBtn = true,
    VNode<bool>? showLoading,
  }) async {
    final vals = await showPickSheet<T>(
      title: title,
      items: items,
      display: display,
      avatar: avatar,
      multi: false,
      initial: initial == null ? null : [initial],
      actions: actions,
      clearable: clearable,
      addOkBtn: addOkBtn,
      showLoading: showLoading,
    );
    if (vals != null && vals.isNotEmpty) {
      return vals.first;
    }
    return null;
  }

  /// Show a sheet to pick a value from a list with tags.
  ///
  /// - [title] is the title of the sheet.
  /// - [itemsBuilder] is the function to build the items with the tag.
  /// - [tags] is the set of tags.
  /// - [display] is the function to display the item.
  /// - [initial] is the initial value(s) of the sheet.
  /// - [clearable] if true, the user can clear the selected items.
  /// - [multi] if true, the user can pick multiple items.
  /// - [actions] is the list of actions.
  /// - [showLoading] is the state to show the loading.
  /// - [ascend] is the state to sort the items.
  Future<List<T>?> showPickWithTagSheet<T>({
    String? title,
    required List<T?> Function(String tag) itemsBuilder,
    required ValueNotifier<Set<String>> tags,
    String Function(T)? display,
    Widget? Function(T)? avatar,
    List<T>? initial,
    bool clearable = false,
    bool multi = false,
    List<Widget>? actions,
    VNode<bool>? showLoading,
    VNode<bool>? ascend,
  }) async {
    var vals = initial ?? <T>[];
    final tag = ''.vn;
    final size = MediaQuery.sizeOf(this);
    final choices = tag.listenVal((tVal) {
      return Choice<T>(
        onChanged: (value) => vals = value,
        multiple: multi,
        clearable: clearable,
        value: vals,
        builder: (state, _) {
          final items = itemsBuilder(tVal);
          return Wrap(
            children: List<Widget>.generate(items.length, (index) {
              final item = items[index];
              if (item == null) return UIs.placeholder;
              return ChoiceChipX<T>(label: display?.call(item) ?? item.toString(), state: state, value: item);
            }),
          );
        },
      );
    });

    final sure = await showSheet<bool>(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TagSwitcher(tags: tags, initTag: tag.value, onTagChanged: (e) => tag.value = e),
          const Divider(color: Color.fromARGB(30, 158, 158, 158)),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.5),
            child: SingleChildScrollView(child: choices),
          ),
        ],
      ),
      actions: [
        ...?actions,
        TextButton(onPressed: () => popSheet(true), child: Text(l10n.ok)),
      ],
    );
    if (sure == true && vals.isNotEmpty) {
      return vals;
    }
    return null;
  }

  /// Show a sheet of error.
  ///
  /// - [e] is the error.
  /// - [s] is the stack trace.
  /// - [operation] is the operation of the error.
  void showErrSheet([Object? e, StackTrace? s, String? operation]) {
    showSheet(
      title: operation ?? l10n.fail,
      child: ErrorView.es(e, s),
      actions: [TextButton(onPressed: () => Pfs.copy('$e\n$s'), child: Text(l10n.copy))],
    );
  }

  /// Show a sheet to import data from file, network or clipboard.
  /// - [title] is the title of the sheet
  /// - [modelDef] is the [Map] definition of the model, it will be displayed like:
  ///   ```jsonc
  ///   {"name": "", "age": 0}
  ///   ```
  Future<Uint8List?> showImportSheet({required String title, Map<String, dynamic>? modelDef}) async {
    title = '$title - ${l10n.import}';
    final from = await showSheet<_ImportFrom>(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Btn.tile(onTap: () => popSheet(_ImportFrom.file), text: l10n.file, icon: const Icon(MingCute.file_line)),
          Btn.tile(onTap: () => popSheet(_ImportFrom.network), text: l10n.network, icon: const Icon(ZondIcons.network)),
          Btn.tile(onTap: () => popSheet(_ImportFrom.clipboard), text: l10n.clipboard, icon: const Icon(MingCute.clipboard_line)),
          if (modelDef != null)
            Btn.tile(
              text: l10n.example,
              icon: const Icon(MingCute.paragraph_fill),
              onTap: () {
                final content = const JsonEncoder.withIndent('\t\t').convert([modelDef]);
                showSheet(
                  title: l10n.example,
                  child: SingleChildScrollView(
                    child: SimpleMarkdown(
                      data:
                          '''
```json
$content
```''',
                      selectable: true,
                    ),
                  ),
                  actions: [TextButton(onPressed: () => Pfs.copy(content), child: Text(l10n.copy))],
                );
              },
            ),
        ],
      ),
    );
    if (from == null) return null;

    switch (from) {
      case _ImportFrom.file:
        final file = await Pfs.pickFile();
        if (file == null) return null;
        // Read on demand since file_picker 12, which no longer fills `bytes`.
        return file.readAsBytes();
      case _ImportFrom.network:
        final urlCtrl = TextEditingController();
        final headersCtrl = TextEditingController();
        await showSheet(
          title: title,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Input(
                  icon: ZondIcons.network,
                  label: 'Url',
                  hint: 'https://a.com',
                  controller: urlCtrl,
                  maxLines: 3,
                  minLines: 1,
                  onSubmitted: (p0) => popSheet(),
                ),
                UIs.height7,
                Input(
                  icon: HeroIcons.queue_list,
                  label: 'Headers',
                  hint: 'key1: value1\nkey2: value2',
                  controller: headersCtrl,
                  maxLines: 5,
                  minLines: 2,
                  onSubmitted: (p0) => popSheet(),
                ),
              ],
            ),
          ),
          actions: Btnx.oks,
        );
        final url = urlCtrl.text;
        final headers = <String, String>{};
        try {
          final lines = headersCtrl.text.split('\n');
          for (final line in lines) {
            final parts = line.split(':');
            if (parts.length != 2) continue;
            headers[parts[0].trim()] = parts[1].trim();
          }
        } catch (e, s) {
          Loggers.app.warning('showImportSheet parse headers', e, s);
        }
        if (url.isEmpty) return null;
        final resp = await myDio.get(
          url,
          options: Options(headers: headers.isEmpty ? null : headers, responseType: ResponseType.bytes),
        );
        return resp.data;
      case _ImportFrom.clipboard:
        final text = await Pfs.paste();
        if (text == null) return null;
        return utf8.encode(text);
    }
  }

  /// Show a sheet to migrate the configuration.
  ///
  /// - [tip] is the tip of the migration.
  Future<bool?> showMigrationSheet(String tip) {
    return showSheet<bool>(
      title: l10n.migrateCfg,
      child: SingleChildScrollView(
        child: SimpleMarkdown(
          data:
              '''
${libL10n.migrateCfgTip}:\n
$tip''',
        ),
      ),
      actions: Btnx.oks,
    );
  }
}

enum _ImportFrom { file, network, clipboard }
