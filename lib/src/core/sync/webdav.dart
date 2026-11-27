part of 'base.dart';

final class Webdav implements RemoteStorage<String> {
  Webdav({this.prefix = defaultPrefix, this.client});

  /// {@template webdav_prefix}
  /// Some WebDAV provider only support non-root path
  /// {@endtemplate}
  static const defaultPrefix = 'lpkt-apps/';

  /// The prefix of the path.
  ///
  /// - Defaults to [defaultPrefix].
  ///
  /// {@macro webdav_prefix}
  String prefix;

  /// The WebDAV client.
  ///
  /// {@template webdav_client}
  /// You should call [init] before using this.
  /// {@endtemplate}
  WebdavClient? client;

  static final shared = Webdav();

  static Future<void> initShared() async {
    String? pwd;
    try {
      pwd = await SecureStoreProps.webdavPwd.read();
    } catch (e) {
      dprint('Failed to read migrated WebDAV password: $e');
    }
    // ignore: deprecated_member_use_from_same_package
    pwd ??= PrefProps.webdavPwd.get();
    shared.client = WebdavClient.basicAuth(
      url: PrefProps.webdavUrl.get() ?? '',
      user: PrefProps.webdavUser.get() ?? '',
      pwd: pwd ?? '',
    );
  }

  /// Formats [e] as a concise single-line summary without dumping raw response
  /// payloads (such as full HTML error pages). Returns null when [e] carries no
  /// status or message.
  static String? formatError(WebdavException<Object?> e) {
    final status = [
      if (e.statusCode != null) '${e.statusCode}',
      if (e.statusMessage case final sm? when sm.trim().isNotEmpty) sm.trim(),
    ].join(' ');
    final detail = e.message.trim();
    if (status.isEmpty && detail.isEmpty) return null;
    if (status.isEmpty) return detail;
    if (detail.isEmpty) return status;
    return '$status · $detail';
  }

  /// Verifies that [url] speaks WebDAV under [prefix] with [user]/[pwd].
  ///
  /// Uses `PROPFIND` rather than `OPTIONS` (`ping`), because plain HTTP roots
  /// commonly answer `OPTIONS` with 200 while rejecting WebDAV methods with
  /// 405. When [prefix] does not exist yet (404), probes the base collection
  /// instead.
  static Future<void> test(
    String url,
    String user,
    String pwd, {
    String prefix = defaultPrefix,
    Duration timeout = const Duration(seconds: 15),
    CancelToken? cancelToken,
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw FormatException('Invalid WebDAV URL', url);
    }
    final client = WebdavClient.basicAuth(
      url: trimmed,
      user: user,
      pwd: pwd,
      options: WebdavOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    WebdavFile? probed;
    try {
      probed = await client.readProps(prefix, cancelToken: cancelToken);
    } on WebdavException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    probed ??= await client.readProps('/', cancelToken: cancelToken);
    if (probed == null || !probed.isDir) {
      throw WebdavException(message: 'Endpoint is not a WebDAV directory');
    }
  }

  /// {@macro webdav_client}
  @override
  Future<void> upload({
    required String relativePath,
    String? localPath,
  }) {
    return client!.writeFile(
      localPath ?? Paths.doc.joinPath(relativePath),
      prefix + relativePath,
    );
  }

  /// {@macro webdav_client}
  @override
  Future<void> delete(String relativePath) async {
    return client!.remove(prefix + relativePath);
  }

  /// {@macro webdav_client}
  @override
  Future<void> download({
    required String relativePath,
    String? localPath,
  }) {
    return client!.readFile(
      prefix + relativePath,
      localPath ?? Paths.doc.joinPath(relativePath),
    );
  }

  /// Check if a file exists in WebDAV storage
  @override
  Future<bool> exists(String relativePath) async {
    try {
      final path = prefix + relativePath;
      return await client!.exists(path);
    } catch (e) {
      Loggers.app.warning('Check if file exists in WebDAV', e);
      return false;
    }
  }

  @override
  String get identity => '${client?.url ?? ''}|$prefix';

  /// The ETag, and nothing else.
  ///
  /// There was a modification-time-and-size fallback here for servers that
  /// send no ETag, and it is the wrong kind of weak. `getlastmodified` is an
  /// HTTP date — **one second of resolution** — so a write that lands in the
  /// same second as the one already recorded, at the same length, reads as no
  /// change at all and the sync is skipped. That is a missed update, which is
  /// the failure this check must not have. Answering null costs those servers
  /// the shortcut and nothing else.
  @override
  Future<String?> versionTag(String relativePath) async {
    try {
      final eTag = (await client!.readProps(prefix + relativePath))?.eTag;
      return eTag == null || eTag.isEmpty ? null : eTag;
    } catch (e) {
      Loggers.app.warning('WebDAV version tag', e);
      return null;
    }
  }

  /// {@macro webdav_client}
  @override
  Future<List<String>> list() async {
    final list = await client!.readDir(prefix);
    final names = <String>[];
    for (final item in list) {
      final name = item.name;
      if (item.isDir || name.isEmpty) continue;
      names.add(name);
    }
    return names;
  }
}
