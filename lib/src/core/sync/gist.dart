part of 'base.dart';

/// GitHub Gist based remote storage.
///
/// - Stores the backup JSON as a file within a single Gist.
/// - Requires a GitHub token with gist scope and a target Gist ID.
final class GistRs implements RemoteStorage<String> {
  /// GitHub API client.
  final Dio _client;

  /// Target gist id. If null, will create one on first upload.
  String? gistId;

  /// GitHub token used for auth. The shared client loads it from secure storage.
  String? token;

  GistRs({String? gistId, this.token, Dio? client})
      : gistId = gistId ?? PrefProps.gistId.get(),
        _client = client ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.github.com',
                headers: {
                  'Accept': 'application/vnd.github+json',
                },
              ),
            );

  /// Shared instance reading config from preferences.
  static final shared = GistRs();

  static Future<void> initShared() async {
    shared.gistId = PrefProps.gistId.get();
    String? token;
    try {
      token = await SecureStoreProps.githubToken.read();
    } catch (e) {
      dprint('Failed to read migrated GitHub token: $e');
    }
    // ignore: deprecated_member_use_from_same_package
    shared.token = token ?? PrefProps.githubToken.get();
  }

  /// The id in [input]: an id as is, or the one at the end of a gist's link
  /// (`https://gist.github.com/<user>/<id>`, `https://api.github.com/gists/<id>`)
  /// — what a browser's address bar gives. Null when it is neither.
  static String? idOf(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    if (_id.hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    // Where the id is, and nowhere else: `/<id>` or `/<user>/<id>`, and the
    // API's `/gists/<id>`. A deeper link — a revision — ends in something else.
    final String? id = switch (host) {
      'gist.github.com' when segments.length == 1 || segments.length == 2 =>
        segments.last,
      'api.github.com' when segments.length == 2 && segments.first == 'gists' =>
        segments.last,
      _ => null,
    };
    if (id == null) return null;
    final bare = id.endsWith('.git') ? id.substring(0, id.length - 4) : id;
    return _id.hasMatch(bare) ? bare : null;
  }

  // Hex since 2013 (20 or 32 characters), digits before that. A word such as
  // `backup` is neither.
  static final _id = RegExp(r'^(?:[0-9a-fA-F]{20,32}|[0-9]+)$');

  /// Checks [token], and with a [gistId] that the token can read that gist.
  ///
  /// Throws [GistTestException] for what the user can fix in the dialog; a
  /// network error is thrown as it is.
  static Future<void> test({
    required String token,
    String? gistId,
    Dio? client,
  }) async {
    final dio = client ??
        Dio(BaseOptions(baseUrl: 'https://api.github.com'));
    final options = Options(headers: {
      'Accept': 'application/vnd.github+json',
      'Authorization': 'token $token',
    });
    try {
      if (gistId == null || gistId.isEmpty) {
        // List the user's gists to validate token
        await dio.get('/gists', options: options);
      } else {
        // Get a specific gist to validate both
        await dio.get('/gists/$gistId', options: options);
      }
    } on DioException catch (e) {
      final reason = switch (e.response?.statusCode) {
        // GitHub answers a rate limit with 403 as well, and that is no fault
        // of the token: thrown as it is, a failure to try again later.
        403 when _rateLimited(e.response!) => null,
        401 || 403 => GistTestFailure.badToken,
        // GitHub answers a secret gist the token cannot read the same as one
        // that does not exist, so the two cannot be told apart.
        404 when gistId != null && gistId.isNotEmpty => GistTestFailure.notFound,
        _ => null,
      };
      if (reason == null) rethrow;
      throw GistTestException(reason, e);
    }
  }

  static bool _rateLimited(Response<dynamic> response) {
    if (response.headers.value('x-ratelimit-remaining') == '0') return true;
    final data = response.data;
    final message = data is Map ? data['message'] : null;
    return message is String && message.toLowerCase().contains('rate limit');
  }

  Map<String, dynamic> _authHeaders() {
    final t = token;
    if (t == null || t.isEmpty) {
      throw StateError('GitHub token is missing. Configure Gist access first.');
    }
    return {
      'Authorization': 'token $t',
    };
  }

  Future<String> _ensureGistForUpload({required String fileName, required String content}) async {
    final headers = _authHeaders();
    final existingId = gistId ?? PrefProps.gistId.get();
    if (existingId != null && existingId.isNotEmpty) return existingId;

    // Create a new secret gist with the file
    final res = await _client.post(
      '/gists',
      data: {
        'description': 'Backup for ${Paths.doc.split('/').last}',
        'public': false,
        'files': {
          fileName: {'content': content},
        },
      },
      options: Options(headers: headers),
    );
    final id = (res.data as Map)['id'] as String;
    gistId = id;
    // Persist id for later use
    try {
      await PrefProps.gistId.set(id);
    } catch (_) {}
    return id;
  }

  @override
  Future<void> upload({required String relativePath, String? localPath}) async {
    final headers = _authHeaders();
    final path = localPath ?? Paths.doc.joinPath(relativePath);
    final content = await File(path).readAsString();

    final id = await _ensureGistForUpload(fileName: relativePath, content: content);

    // Update the gist file content
    await _client.patch(
      '/gists/$id',
      data: {
        'files': {
          relativePath: {'content': content},
        },
      },
      options: Options(headers: headers),
    );
  }

  @override
  Future<void> delete(String relativePath) async {
    final headers = _authHeaders();
    final id = gistId ?? PrefProps.gistId.get();
    if (id == null || id.isEmpty) return;

    await _client.patch(
      '/gists/$id',
      data: {
        'files': {
          relativePath: null,
        },
      },
      options: Options(headers: headers),
    );
  }

  @override
  Future<void> download({required String relativePath, String? localPath}) async {
    final headers = _authHeaders();
    final id = gistId ?? PrefProps.gistId.get();
    if (id == null || id.isEmpty) {
      throw StateError('Gist id is missing. Set PrefProps.gistId or upload once to create.');
    }

    final res = await _client.get(
      '/gists/$id',
      options: Options(headers: headers),
    );

    final data = res.data as Map<String, dynamic>;
    final files = (data['files'] as Map).cast<String, dynamic>();
    final file = files[relativePath] as Map<String, dynamic>?;
    if (file == null) {
      throw StateError('Gist does not contain file: $relativePath');
    }

    String? content = file['content'] as String?;
    if (content == null) {
      final rawUrl = file['raw_url'] as String?;
      if (rawUrl == null) {
        throw StateError('No raw_url for file: $relativePath');
      }
      final raw = await _client.get<String>(
        rawUrl,
        options: Options(responseType: ResponseType.plain),
      );
      content = raw.data ?? '';
    }

    final outPath = localPath ?? Paths.doc.joinPath(relativePath);
    await File(outPath).writeAsString(content);
  }

  @override
  Future<bool> exists(String relativePath) async {
    try {
      final headers = _authHeaders();
      final id = gistId ?? PrefProps.gistId.get();
      if (id == null || id.isEmpty) return false;

      final res = await _client.get('/gists/$id', options: Options(headers: headers));
      final data = res.data as Map<String, dynamic>;
      final files = (data['files'] as Map).cast<String, dynamic>();
      return files.containsKey(relativePath);
    } catch (e) {
      Loggers.app.warning('Check if file exists in Gist', e);
      return false;
    }
  }

  @override
  String get identity => gistId ?? PrefProps.gistId.get() ?? '';

  /// The gist's current revision SHA.
  ///
  /// `history[0].version` is a commit id: unique per revision, and it moves on
  /// every write and only on a write. It replaced `updated_at` paired with the
  /// file's size, which was two lossy values standing in for one exact one —
  /// a second of resolution on the timestamp, and a length that a different
  /// revision can easily share.
  ///
  /// Over-reports, and that is the safe direction: the SHA covers the whole
  /// gist, so an edit to another file in it reads as a change to this one and
  /// costs a round trip. The opposite mistake costs an update.
  @override
  Future<String?> versionTag(String relativePath) async {
    try {
      final id = gistId ?? PrefProps.gistId.get();
      if (id == null || id.isEmpty) return null;

      final res = await _client.get('/gists/$id', options: Options(headers: _authHeaders()));
      final data = res.data as Map<String, dynamic>;
      if ((data['files'] as Map?)?.containsKey(relativePath) != true) {
        return null;
      }

      final history = data['history'];
      if (history is! List || history.isEmpty) return null;
      final version = (history.first as Map?)?['version'];
      return version is String && version.isNotEmpty ? version : null;
    } catch (e) {
      Loggers.app.warning('Gist version tag', e);
      return null;
    }
  }

  @override
  Future<List<String>> list() async {
    try {
      final headers = _authHeaders();
      final id = gistId ?? PrefProps.gistId.get();
      if (id == null || id.isEmpty) return [];

      final res = await _client.get('/gists/$id', options: Options(headers: headers));
      final data = res.data as Map<String, dynamic>;
      final files = (data['files'] as Map).cast<String, dynamic>();
      return files.keys.toList();
    } catch (e) {
      Loggers.app.warning('List files in Gist', e);
      return [];
    }
  }
}

/// Why [GistRs.test] refused a token or a gist id.
enum GistTestFailure {
  /// 401, or a 403 that is not a rate limit: the token is wrong, expired or
  /// revoked, or has no gist access.
  badToken,

  /// 404 for the gist id: there is no such gist, or it is someone else's
  /// secret gist.
  notFound,
}

/// What [GistRs.test] found wrong with what the user entered.
final class GistTestException implements Exception {
  final GistTestFailure reason;

  /// The response it was read from.
  final DioException cause;

  const GistTestException(this.reason, this.cause);

  @override
  String toString() => 'GistTestException($reason, ${cause.response?.statusCode})';
}
