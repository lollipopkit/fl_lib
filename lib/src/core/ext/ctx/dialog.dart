import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:choice/choice.dart';
import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

extension DialogX on BuildContext {
  static const _actionsPadding = EdgeInsets.only(left: 13, right: 13, bottom: 7);
  static const _contentPadding = EdgeInsets.all(24);

  /// Show a dialog with a title, a child and actions.
  ///
  /// - [child] is the content of the dialog.
  /// - [actions] is the list of actions.
  /// - [title] is the title of the dialog.
  /// - [barrierDismiss] if true, the dialog can be dismissed by tapping the barrier.
  /// - [titleMaxLines] is the max lines of the title.
  /// - [actionsPadding] is the padding of the actions.
  /// - [contentPadding] is the padding of the content.
  /// - [titleBuilder] is the function to build the title. If not null, [title] will be ignored.
  /// - [childBuilder] is the function to build the child. If not null, [child] will be ignored.
  /// - [actionsBuilder] is the function to build the actions. If not null, [actions] will be ignored.
  Future<T?> showRoundDialog<T>({
    Widget? child,
    List<Widget>? actions,
    String? title,
    bool barrierDismiss = true,
    int? titleMaxLines,
    EdgeInsetsGeometry? actionsPadding = _actionsPadding,
    EdgeInsetsGeometry? contentPadding = _contentPadding,
    Widget? Function(BuildContext ctx)? titleBuilder,
    Widget? Function(BuildContext ctx)? childBuilder,
    List<Widget>? Function(BuildContext ctx)? actionsBuilder,
  }) async {
    if (!mounted) return null;

    return await showDialog<T>(
      context: this,
      barrierDismissible: barrierDismiss,
      // Stated rather than inherited. The default is being deprecated, and it
      // stops being a formality once there is more than one navigator: a
      // dialog on the nearest one is clipped to whatever pane raised it, so a
      // confirmation for a destructive action would appear inside a column.
      useRootNavigator: true,
      builder: (ctx) {
        final title_ = switch (titleBuilder) {
          null => title != null ? Text(title, maxLines: titleMaxLines) : null,
          _ => titleBuilder(ctx),
        };
        final child_ = childBuilder?.call(ctx) ?? child;
        final actions_ = actionsBuilder?.call(ctx) ?? actions;

        return AlertDialog(
          title: title_,
          content: child_,
          actions: actions_,
          actionsPadding: actions_?.isEmpty == true ? EdgeInsets.zero : actionsPadding,
          contentPadding: contentPadding,
        );
      },
    );
  }

  /// [timeout] is the timeout of the Future [fn] (default `null`).
  ///
  /// If an error occurs:
  /// - the dialog will be closed and an error dialog will be displayed
  /// - the [onErr] function will be called (awaited)
  /// - the return value will be `null`
  Future<FnRes<T>> showLoadingDialog<T>({
    required Future<T> Function() fn,
    bool barrierDismiss = false,
    FutureOr<void> Function(Object e, StackTrace s)? onErr,
    Duration? timeout = const Duration(seconds: 17),
  }) async {
    showRoundDialog(child: SizedLoading.medium, barrierDismiss: barrierDismiss);

    return Resx.tryCatch(
      () async {
        final ret = switch (timeout) {
          null => await fn(),
          _ => await fn().timeout(timeout),
        };
        popDialog();
        return ret;
      },
      onErr: (e, s) {
        popDialog();
        showErrDialog(e, s);
        onErr?.call(e, s);
      },
    );
  }

  static final _recoredPwd = <String, String>{};

  /// Show a dialog to input password.
  ///
  /// - [id] is the key to record the password.
  /// - [remember] if true, the password will be recorded. Only works when [id] is not null.
  Future<String?> showPwdDialog({String? title, String? label, String? id, bool remember = true}) async {
    if (!mounted) return null;
    return await showRoundDialog<String>(
      title: title,
      child: Input(
        controller: TextEditingController(text: _recoredPwd[id]),
        autoFocus: true,
        type: TextInputType.visiblePassword,
        obscureText: true,
        onSubmitted: (val) {
          popDialog(val);
          if (remember && id != null) {
            _recoredPwd[id] = val;
          }
        },
        label: label ?? l10n.pwd,
      ),
    );
  }

  /// Show a dialog to pick a value from a list.
  ///
  /// - [title] is the title of the dialog.
  /// - [items] is the list of items to pick.
  /// - [display] is the function to display the item.
  /// - [multi] if true, the user can pick multiple items.
  /// - [initial] is the initial value(s) of the dialog.
  /// - [clearable] if true, the user can clear the selected items.
  /// - [actions] is the list of actions.
  /// - [addOkBtn] if true, the dialog will have an OK button.
  /// - [showLoading] is the state to show the loading.
  /// - [ascend] is the state to sort the items.
  Future<List<T>?> showPickDialog<T>({
    String? title,
    required List<T> items,
    String Function(T)? display,
    bool multi = true,
    List<T>? initial,
    bool clearable = false,
    List<Widget>? actions,
    bool addOkBtn = true,
    VNode<bool>? showLoading,
    VNode<bool>? ascend,
  }) async {
    var vals = initial ?? <T>[];
    final btns = actions ?? <Widget>[];
    if (multi && addOkBtn) {
      btns.add(TextButton(onPressed: () => popDialog(true), child: Text(l10n.ok)));
    }

    final itemsList = items.toList();
    final isAscending = ascend ?? nvn<bool>();
    showLoading ??= false.vn;

    Widget buildChoice() {
      return ChoiceWidget<T>(
        onChanged: (value) {
          vals = value;
          if (!multi) popDialog(true);
        },
        multi: multi,
        clearable: clearable,
        items: itemsList,
        selected: vals,
        display: display,
      );
    }

    Widget buildTitle(BuildContext context) {
      Widget buildSortIcon(bool? asc) {
        return AnimatedSwitcher(
          duration: Durations.medium1,
          child: IconButton(
            key: ValueKey(asc),
            icon: Icon(switch (asc) {
              true => Icons.arrow_upward,
              false => Icons.arrow_downward,
              null => Icons.sort,
            }),
            onPressed: () {
              final asc_ = asc ?? true;
              isAscending.value = !asc_;
              itemsList.sort((a, b) {
                final aStr = display?.call(a) ?? a.toString();
                final bStr = display?.call(b) ?? b.toString();
                return asc_ ? aStr.compareTo(bStr) : bStr.compareTo(aStr);
              });
            },
          ),
        );
      }

      return Row(
        children: [
          Expanded(child: Text(title ?? l10n.select)),
          isAscending.listenVal(buildSortIcon),
        ],
      );
    }

    Widget buildBody(bool loading) {
      return loading ? SizedLoading.medium : isAscending.listen(buildChoice);
    }

    final sure = await showRoundDialog<bool>(
      titleBuilder: buildTitle,
      child: SingleChildScrollView(child: showLoading.listenVal(buildBody)),
      actions: btns.isEmpty ? null : btns,
    );
    if (sure == true) return vals;
    return null;
  }

  /// Show a dialog to pick a single value from a list.
  ///
  /// - [title] is the title of the dialog.
  /// - [items] is the list of items to pick.
  /// - [display] is the function to display the item.
  /// - [initial] is the initial value of the dialog.
  /// - [clearable] if true, the user can clear the selected item.
  /// - [actions] is the list of actions.
  /// - [addOkBtn] if true, the dialog will have an OK button.
  /// - [showLoading] is the state to show the loading.
  Future<T?> showPickSingleDialog<T>({
    String? title,
    required List<T> items,
    String Function(T)? display,
    T? initial,
    bool clearable = false,
    List<Widget>? actions,
    bool addOkBtn = true,
    VNode<bool>? showLoading,
  }) async {
    final vals = await showPickDialog<T>(
      title: title,
      items: items,
      display: display,
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

  /// Show a dialog to pick a value from a list with tags.
  ///
  /// - [title] is the title of the dialog.
  /// - [itemsBuilder] is the function to build the items with the tag.
  /// - [tags] is the set of tags.
  /// - [display] is the function to display the item.
  /// - [initial] is the initial value(s) of the dialog.
  /// - [clearable] if true, the user can clear the selected items.
  /// - [multi] if true, the user can pick multiple items.
  /// - [actions] is the list of actions.
  /// - [showLoading] is the state to show the loading.
  /// - [ascend] is the state to sort the items.
  Future<List<T>?> showPickWithTagDialog<T>({
    String? title,
    required List<T?> Function(String tag) itemsBuilder,
    required ValueNotifier<Set<String>> tags,
    String Function(T)? display,
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

    final sure = await showRoundDialog<bool>(
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
        TextButton(onPressed: () => popDialog(true), child: Text(l10n.ok)),
      ],
    );
    if (sure == true && vals.isNotEmpty) {
      return vals;
    }
    return null;
  }

  /// Show a dialog of error.
  ///
  /// - [e] is the error.
  /// - [s] is the stack trace.
  /// - [operation] is the operation of the error.
  void showErrDialog([Object? e, StackTrace? s, String? operation]) {
    showRoundDialog(
      title: operation ?? l10n.fail,
      child: ErrorView.es(e, s),
      actions: [TextButton(onPressed: () => Pfs.copy('$e\n$s'), child: Text(l10n.copy))],
    );
  }

  /// Show a dialog to import data from file, network or clipboard.
  /// - [title] is the title of the dialog
  /// - [modelDef] is the [Map] definition of the model, it will be displayed like:
  ///   ```jsonc
  ///   {"name": "", "age": 0}
  ///   ```
  Future<Uint8List?> showImportDialog({required String title, Map<String, dynamic>? modelDef}) async {
    title = '$title - ${l10n.import}';
    final from = await showRoundDialog<_ImportFrom>(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Btn.tile(onTap: () => popDialog(_ImportFrom.file), text: l10n.file, icon: const Icon(MingCute.file_line)),
          Btn.tile(onTap: () => popDialog(_ImportFrom.network), text: l10n.network, icon: const Icon(ZondIcons.network)),
          Btn.tile(onTap: () => popDialog(_ImportFrom.clipboard), text: l10n.clipboard, icon: const Icon(MingCute.clipboard_line)),
          if (modelDef != null)
            Btn.tile(
              text: l10n.example,
              icon: const Icon(MingCute.paragraph_fill),
              onTap: () {
                final content = const JsonEncoder.withIndent('\t\t').convert([modelDef]);
                showRoundDialog(
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
        await showRoundDialog(
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
                  onSubmitted: (p0) => popDialog(),
                ),
                UIs.height7,
                Input(
                  icon: HeroIcons.queue_list,
                  label: 'Headers',
                  hint: 'key1: value1\nkey2: value2',
                  controller: headersCtrl,
                  maxLines: 5,
                  minLines: 2,
                  onSubmitted: (p0) => popDialog(),
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
          Loggers.app.warning('showImportDialog parse headers', e, s);
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
        return Uint8List.fromList(text.codeUnits);
    }
  }

  /// Show a dialog to migrate the configuration.
  ///
  /// - [tip] is the tip of the migration.
  Future<bool?> showMigrationDialog(String tip) {
    return showRoundDialog<bool>(
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
