import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:computer/computer.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:flutter_highlight/themes/monokai.dart';
import 'package:re_editor/re_editor.dart';

const _kSoftWrap = false;
const _kEnableHighlight = true;
const _kCloseAfterSave = false;

/// The return value type
enum EditorPageRetType { path, text }

/// The return value of the editor page
final class EditorPageRet {
  final EditorPageRetType typ;
  final String val;

  const EditorPageRet(this.typ, this.val);
}

final class EditorPageArgs {
  /// If path is not null, then it's a file editor
  /// If path is null, then it's a text editor
  final String? path;

  /// Only used when path is null
  final String? text;

  /// Code of language, eg: dart, go, etc.
  /// Higher priority than [path]
  final ProgLang? lang;

  /// The title of the editor
  final String? title;

  /// The theme of the editor in light mode
  final HighlightTheme? lightTheme;

  /// The theme of the editor in dark mode
  final HighlightTheme? darkTheme;

  /// The callback when the editor is saved
  final void Function(EditorPageRet) onSave;

  /// Whether to soft wrap the text
  final bool softWrap;

  /// Whether to enable highlight
  final bool enableHighlight;

  /// Whether to close the editor after saving
  final bool closeAfterSave;

  /// The controller of the selection toolbar.
  /// eg.: [CodeContextMenuController]
  final SelectionToolbarController? toolbarController;

  /// The font family to use in the editor
  final String? fontFamily;

  const EditorPageArgs({
    this.path,
    this.text,
    this.lang,
    this.title,
    required this.onSave,
    this.lightTheme,
    this.darkTheme,
    this.softWrap = _kSoftWrap,
    this.enableHighlight = _kEnableHighlight,
    this.closeAfterSave = _kCloseAfterSave,
    this.toolbarController,
    this.fontFamily,
  });
}

/// The code editor page which has code highlighting and syntax highlighting
class EditorPage extends StatefulWidget {
  final EditorPageArgs? args;

  const EditorPage({super.key, this.args});

  static const route = AppRoute<void, EditorPageArgs>(
    page: EditorPage.new,
    path: '/editor',
  );

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _focusNode = FocusNode();

  final _controller = CodeLineEditingController();
  late final CodeFindController _findController;
  late Map<String, TextStyle> _codeTheme;
  late final _lang = widget.args?.lang ?? ProgLang.parseFileName(widget.args?.path);
  late final _modesMap = _lang?.editorLangs ?? ProgLang.defaultLangModeMap;
  late final _isMarkdown = _lang == ProgLang.markdown;

  /// What was last read or written: unsaved edits are a difference from it.
  var _savedText = '';
  var _dirty = false;

  /// The lines last compared: the controller also notifies for the caret and
  /// the selection, which leave the lines as they were.
  Object? _comparedLines;

  /// False while the file is read: saving then would write an empty file,
  /// and typing would be replaced by what was read.
  var _loaded = false;

  /// Markdown opens rendered; the source is one tap away.
  late var _previewing = _isMarkdown;

  @override
  void dispose() {
    _findController.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Not lazy: in preview nothing reads it before `dispose`, which would then
    // create it on the already disposed [_controller].
    _findController = CodeFindController(_controller);
    _controller.addListener(_onChanged);
    _setupCtrl();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (context.isDark) {
      _codeTheme = widget.args?.darkTheme?.theme ?? monokaiTheme;
    } else {
      _codeTheme = widget.args?.lightTheme?.theme ?? a11yLightTheme;
    }
    if (!_previewing) _focusNode.requestFocus();
  }

  void _onChanged() {
    final lines = _controller.codeLines;
    if (identical(lines, _comparedLines)) return;
    _comparedLines = lines;
    final dirty = _loaded && _controller.text != _savedText;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  @override
  Widget build(BuildContext context) {
    return PopGuard(
      enabled: _dirty,
      confirm: _confirmLeave,
      child: Scaffold(
        backgroundColor: _previewing ? null : _codeTheme['root']?.backgroundColor,
        appBar: _buildAppBar(),
        body: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return CustomAppBar(
      title: TwoLineText(
        up: widget.args?.title ?? widget.args?.path?.getFileName() ?? libL10n.unknown,
        down: _previewing ? libL10n.preview : libL10n.editor,
      ),
      actions: [
        if (_isMarkdown)
          IconButton(
            icon: Icon(_previewing ? Icons.edit_outlined : Icons.visibility_outlined),
            tooltip: _previewing ? libL10n.edit : libL10n.preview,
            onPressed: _togglePreview,
          ),
        if (!_previewing)
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: libL10n.search,
            onPressed: _loaded ? () => _findController.findMode() : null,
          ),
        // PopupMenuButton<String>(
        //   icon: const Icon(Icons.language),
        //   tooltip: libL10n.language,
        //   onSelected: (value) {
        //     _langCode = value;
        //   },
        //   initialValue: _langCode,
        //   itemBuilder: (BuildContext context) {
        //     return Highlights.all.keys.map((e) {
        //       return PopupMenuItem(
        //         value: e,
        //         child: Text(e),
        //       );
        //     }).toList();
        //   },
        // ),
        IconButton(
          icon: const Icon(Icons.save),
          tooltip: libL10n.save,
          onPressed: _loaded ? _onSave : null,
        )
      ],
    );
  }

  Widget _buildBody() {
    if (!_loaded) return const Center(child: SizedLoading.medium);
    if (_previewing) return _buildPreview();
    // The family is named even when the user chose none: `re_editor` reads a
    // null family as "start at the fallback list", so the first entry would
    // become the editor's font instead of its last resort.
    final bodyMedium = Theme.of(context).textTheme.bodyMedium;
    return CodeEditor(
      style: CodeEditorStyle(
        fontFamily: widget.args?.fontFamily ?? bodyMedium?.fontFamily,
        fontFamilyFallback: bodyMedium?.fontFamilyFallback,
        codeTheme: CodeHighlightTheme(
          languages: _modesMap,
          theme: _codeTheme,
        ),
      ),
      controller: _controller,
      findController: _findController,
      wordWrap: widget.args?.softWrap ?? false,
      focusNode: _focusNode,
      indicatorBuilder: (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            UIs.width7,
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
            ),
            UIs.width7,
          ],
        );
      },
      findBuilder: (context, controller, readOnly) => CodeFindPanelView(controller: controller, readOnly: readOnly),
      toolbarController: widget.args?.toolbarController ?? (isMobile ? AdaptiveSelectionToolbarController() : null),
    );
  }

  Widget _buildPreview() {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        // The file may come from anywhere, e.g. a remote server.
        child: SimpleMarkdown(data: _controller.text, selectable: true, loadImages: false),
      ),
    );
  }

  void _markLoaded() => setState(() => _loaded = true);

  void _togglePreview() {
    setState(() => _previewing = !_previewing);
    if (_previewing) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }
}

extension on _EditorPageState {
  /// Loads the file, or says why it cannot and closes the editor.
  ///
  /// Started from `initState` with nobody awaiting it, so a failure here had
  /// no handler at all: opening a PDF or an image decoded it as UTF-8 in the
  /// worker, and the `FileSystemException` came back as an uncaught error
  /// while the page sat empty.
  Future<void> _setupCtrl() async {
    final path = widget.args?.path;
    final text = widget.args?.text;
    if (path != null) {
      final String? code;
      try {
        code = await Computer.shared.startNoParam(() => editorReadUtf8(path));
      } catch (e, s) {
        Loggers.app.warning('Editor: read $path', e, s);
        _closeWith(libL10n.fail);
        return;
      }
      if (code == null) {
        _closeWith(libL10n.unsupported);
        return;
      }
      if (!mounted) return;
      _controller.text = code;
      // Read back: the editor keeps its own line breaks.
      _savedText = _controller.text;
      _markLoaded();
      return;
    }
    // Synchronous, from `initState`: no rebuild needed yet.
    if (text != null) {
      _controller.text = text;
      _savedText = _controller.text;
    }
    _loaded = true;
  }

  void _closeWith(String message) {
    if (!mounted) return;
    Toast.show(message);
    context.pop();
  }

  /// Writes the text where it came from; false when that failed.
  Future<bool> _save() async {
    final text = _controller.text;
    final path = widget.args?.path;
    if (path != null) {
      final (res, _) = await context.showLoadingDialog(
        fn: () => File(path).writeAsString(text),
      );
      if (res == null) {
        Toast.error(libL10n.fail);
        return false;
      }
      if (!mounted) return true;
      widget.args?.onSave(EditorPageRet(EditorPageRetType.path, path));
    } else {
      widget.args?.onSave(EditorPageRet(EditorPageRetType.text, text));
    }
    _savedText = text;
    _comparedLines = null;
    _onChanged();
    return true;
  }

  void _onSave() async {
    if (!await _save() || !mounted) return;
    if (widget.args?.closeAfterSave ?? _kCloseAfterSave) context.pop();
  }

  /// Save and leave, leave without saving, or stay.
  Future<bool> _confirmLeave() async {
    // `popDialog`, not `pop`. `showRoundDialog` puts the dialog on the root
    // navigator, while this context's nearest navigator is the one holding
    // the *page* — a different one wherever the editor was pushed inside a
    // pane or a tab.
    final shouldSave = await contextSafe?.showRoundDialog<bool>(
      title: libL10n.attention,
      child: Text(libL10n.actionAndAction(libL10n.save, libL10n.exit)),
      actions: [
        TextButton(
          onPressed: () => contextSafe?.popDialog(false),
          child: Text(libL10n.exitDirectly),
        ),
        TextButton(
          onPressed: () => contextSafe?.popDialog(true),
          child: Text(libL10n.ok),
        ),
      ],
    );
    if (shouldSave == null) return false;
    if (shouldSave) return _save();
    return true;
  }
}

@visibleForTesting
/// The file as UTF-8 text, or null when it is not text.
///
/// Top-level so it can run in a worker. Bytes and an explicit decode rather
/// than `readAsString`, so "not text" is an answer instead of the same
/// `FileSystemException` a missing file throws.
String? editorReadUtf8(String path) {
  final bytes = File(path).readAsBytesSync();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}
