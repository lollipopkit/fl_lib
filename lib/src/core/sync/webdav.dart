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

  static Future<void> test(String url, String user, String pwd) async {
    await WebdavClient.basicAuth(url: url, user: user, pwd: pwd).ping();
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
  Future<String?> versionTag(String relativePath) async {
    try {
      final props = await client!.readProps(prefix + relativePath);
      if (props == null) return null;
      final eTag = props.eTag;
      if (eTag != null && eTag.isNotEmpty) return eTag;
      // Not every server sends an ETag. Modification time paired with size is
      // the fallback — weaker, since a same-size rewrite within the clock's
      // resolution reads as unchanged, and good enough for a check whose
      // failure mode is one extra round trip.
      final modified = props.modified;
      if (modified == null) return null;
      return '${modified.millisecondsSinceEpoch}/${props.size ?? -1}';
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
