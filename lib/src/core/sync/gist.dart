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

  static Future<void> test({required String token, String? gistId}) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.github.com',
        headers: {
          'Accept': 'application/vnd.github+json',
          'Authorization': 'token $token',
        },
      ),
    );

    if (gistId == null || gistId.isEmpty) {
      // List the user's gists to validate token
      await dio.get('/gists');
    } else {
      // Get a specific gist to validate both
      await dio.get('/gists/$gistId');
    }
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

