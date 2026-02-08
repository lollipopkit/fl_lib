/// File view page / card
///
/// - Preview text/image file content
/// - Open other file types with system app
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// File card view;
///
/// [Card] + [ListTile]
final class FileCardView extends StatefulWidget {
  /// File path.
  final String path;

  /// Use this to override the file name.
  final String? name;

  /// For smooth UI, set a delay to load file stat.
  final Duration loadDelay;

  const FileCardView({
    super.key,
    required this.path,
    this.name,
    this.loadDelay = const Duration(milliseconds: 500),
  });

  @override
  _FileCardViewState createState() => _FileCardViewState();
}

final class _FileCardViewState extends State<FileCardView> with AutomaticKeepAliveClientMixin {
  (String? mime, Uint8List content)? _content;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFileContent();
  }

  Future<void> _loadFileContent() async {
    setStateSafe(() {
      _loading = true;
      _error = null;
    });
    await Future.delayed(widget.loadDelay);
    try {
      final file = File(widget.path);
      final mime = await file.mimeType;
      final content = await file.readAsBytes();
      setStateSafe(() {
        _content = (mime, content);
        _loading = false;
      });
    } catch (e) {
      setStateSafe(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CardX(child: _buildBody);
  }

  Widget get _buildBody {
    if (_loading) return UIs.smallLinearLoading;
    if (_error != null) {
      return Center(child: Text(libL10n.error + (kDebugMode ? '\n$_error' : '')));
    }
    if (_content == null) {
      return Center(child: Text(libL10n.empty));
    }
    return _buildPreview(_content!);
  }

  Widget _buildPreview((String? mime, Uint8List content) data) {
    final mime = data.$1;
    if (mime?.startsWith('image/') == true) {
      return LayoutBuilder(builder: (_, cons) {
        return ImageCard(
          imageUrl: widget.path,
          heroTag: widget.path,
          size: cons.maxWidth / 3,
          onRet: _onImgRet,
        );
      });
    } else {
      final file = File(widget.path);
      return FutureBuilder<FileStat>(
        future: file.stat(),
        builder: (context, snapshot) {
          final stat = snapshot.data;
          final sizeStr = stat != null ? stat.size.bytes2Str : '';
          final dateStr = stat != null ? stat.modified.toString().split('.').first : '';
          return ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: Text(widget.name ?? file.uri.pathSegments.last),
            subtitle:
                Text([?mime, if (sizeStr.isNotEmpty) sizeStr, if (dateStr.isNotEmpty) dateStr].join(' · ')),
            trailing: IconButton(
              icon: const Icon(Icons.open_in_new),
              onPressed: _onTapCard,
            ),
          );
        },
      );
    }
  }

  @override
  bool get wantKeepAlive => true;
}

extension on _FileCardViewState {
  void _onTapCard() {
    if (_error != null) {
      return context.showErrDialog(_error);
    }

    FileViewPage.route.go(context, FileViewPageArgs(path: widget.path, name: widget.name));
  }

  void _onImgRet(ImagePageRet p0) async {
    if (p0.isDeleted) {
      try {
        await File(widget.path).delete();
      } catch (e, s) {
        contextSafe?.showErrDialog(e, s, libL10n.delete);
      }
    }
  }
}

/// File view page arguments
final class FileViewPageArgs {
  final String? path;
  final String? name;
  final Uint8List? content;
  final Set<String> supportedMimes;

  const FileViewPageArgs({
    this.path,
    this.name,
    this.content,
    this.supportedMimes = const {'text/plain', 'text/markdown'},
  }) : assert(path != null || content != null, 'path or content must be provided');
}

/// File view page
final class FileViewPage extends StatefulWidget {
  final FileViewPageArgs args;

  const FileViewPage({
    super.key,
    required this.args,
  });

  @override
  _FileViewPageState createState() => _FileViewPageState();

  static const route = AppRouteArg<void, FileViewPageArgs>(
    page: FileViewPage.new,
    path: '/file_view',
  );
}

final class _FileViewPageState extends State<FileViewPage> {
  /// 128KB
  static const int maxPreviewBytes = 128 * 1024;

  (String mime, Uint8List content, int? fileSize, bool truncated)? _content;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    setStateSafe(() {
      _loading = true;
      _error = null;
    });
    final content = widget.args.content;
    if (content != null) {
      setStateSafe(() {
        _content = (
          widget.args.supportedMimes.firstOrNull ?? 'text/plain',
          content,
          content.length,
          false,
        );
        _loading = false;
      });
      return;
    }
    try {
      final value = await _fetchContent();
      setStateSafe(() {
        _content = value;
        _loading = false;
      });
    } catch (e) {
      setStateSafe(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(
        title: Text(widget.args.name ?? libL10n.file),
        actions: [
          if (widget.args.path != null)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: libL10n.open,
              onPressed: _onOpenWithSystem,
            ),
        ],
      ),
      body: _loading ? UIs.smallLinearLoading : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(libL10n.unsupported + (kDebugMode ? '\n$_error' : '')));
    }
    final content = _content;
    if (content == null) return _buildUnsupport();
    final mime = content.$1;
    final fileSize = content.$3;
    final truncated = content.$4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${widget.args.name ?? widget.args.path ?? ''} $mime ${fileSize != null ? fileSize.bytes2Str : '-'}',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        Expanded(
          child: switch (mime) {
            _ when mime.startsWith('image/') => _buildImage(content.$2),
            _ when mime.startsWith('text/') => _buildText(content.$2, truncated),
            _ => _buildUnsupport(),
          },
        ),
      ],
    );
  }

  Widget _buildText(Uint8List content, bool truncated) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<String>(
          future: compute(utf8.decode, content),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return UIs.smallLinearLoading;
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Text(snapshot.error?.toString() ?? '???');
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    snapshot.data ?? libL10n.empty,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                if (truncated)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      libL10n.sizeTooLargeOnlyPrefix(maxPreviewBytes.bytes2Str),
                      style: const TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildImage(Uint8List content) {
    return InteractiveViewer(
      constrained: false,
      child: Image.memory(content, fit: BoxFit.contain),
    );
  }

  Widget _buildUnsupport() {
    return Center(
      child: Text(libL10n.empty),
    );
  }
}

extension on _FileViewPageState {
  Future<(String mime, Uint8List content, int? fileSize, bool truncated)?> _fetchContent() async {
    final file = File(widget.args.path!);
    final mime = await file.mimeType;
    final stat = await file.stat();
    final fileSize = stat.size;
    bool truncated = false;
    Uint8List content;
    if (fileSize > _FileViewPageState.maxPreviewBytes) {
      final raf = await file.open();
      content = await raf.read(_FileViewPageState.maxPreviewBytes);
      await raf.close();
      truncated = true;
    } else {
      content = await file.readAsBytes();
    }
    if (mime != null && !widget.args.supportedMimes.contains(mime)) {
      return null;
    }
    return (mime ?? 'text/plain', content, fileSize, truncated);
  }

  void _onOpenWithSystem() async {
    final path = widget.args.path;
    if (path == null) return;
    try {
      await Pfs.sharePaths(paths: [path], title: widget.args.name);
    } catch (e) {
      contextSafe?.showErrDialog(e);
    }
  }
}
