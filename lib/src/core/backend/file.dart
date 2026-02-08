part of 'api.dart';

/// File API
abstract final class FileApi {
  /// Convert local file path / server url to filename
  static String urlToName(String path) {
    if (path.startsWith('/')) return path.fileNameGetter ?? path;
    if (path.startsWith(ApiUrls.file)) {
      final uri = Uri.parse(path);
      return uri.queryParameters['name'] ?? path;
    }
    return path;
  }

  /// Convert remote file path to url
  static String nameToUrl(String name, {String? dir}) {
    dir ??= UserApi.user.value?.id;
    final url = '${ApiUrls.file}?name=$name&dir=$dir';
    return url;
  }

  /// Upload a file to the server.
  ///
  /// - [paths] is the local file path.
  /// - [dir] is the directory name.
  ///
  /// Returns the remote urls.
  static Future<List<String>> upload(List<String> paths, {String? dir}) async {
    final map = <String, dynamic>{
      'dir': ?dir,
    };
    for (final path in paths) {
      final name = urlToName(path);
      map[name] = await MultipartFile.fromFile(path);
    }

    final resp = await myDio.post(
      ApiUrls.file,
      data: FormData.fromMap(map),
      options: Options(
        headers: UserApi.authHeaders,
        responseType: ResponseType.json,
      ),
    );
    final Object? data = resp.data;
    final rPaths = _getRespData<List<dynamic>>(data)?.cast<String>();
    if (rPaths == null) throw Exception('Invalid resp: $data');
    final urls = rPaths.map((rPath) => nameToUrl(rPath)).toList();
    return urls;
  }

  /// Download a file from the server.
  ///
  /// - [name] is the file name.
  /// - [dir] is the directory name.
  /// - [respType] is the response type.
  ///
  /// Returns the file content as bytes by default.
  static Future<Uint8List> download(String name, {String? dir, ResponseType? respType}) async {
    name = urlToName(name);
    final queries = {'name': name};
    if (dir != null) queries['dir'] = dir;

    final resp = await myDio.get(
      ApiUrls.file,
      queryParameters: queries,
      options: Options(
        headers: UserApi.authHeaders,
        responseType: respType ?? ResponseType.bytes,
      ),
    );
    final contentTypes = resp.headers['content-type'];
    if (contentTypes != null && contentTypes.contains('application/json')) {
      throw Exception('Failed to download $name: ${resp.data}');
    }
    final Object? data = resp.data;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    throw Exception('Invalid resp data: ${data.runtimeType}, $data');
  }

  /// Delete a file from the server.
  ///
  /// - [names] is file names.
  /// - [dir] is the directory name.
  static Future<void> delete(
    List<String> names, {
    String? dir,
  }) async {
    names = names.map(urlToName).toList();
    final body = <String, dynamic>{'names': names};
    if (dir != null) body['dir'] = dir;

    final resp = await myDio.delete(
      ApiUrls.file,
      data: body,
      options: Options(headers: UserApi.authHeaders),
    );
    final Object? respData = resp.data;
    final data = _getRespData<List<dynamic>>(respData)?.cast<String>();
    if (data == null) throw Exception('Invalid resp: $respData');
    final diffs = names.toSet().difference(data.toSet());
    if (diffs.isNotEmpty) {
      throw Exception('Failed to delete: $diffs');
    }
  }
}

/// Get response data.
///
/// eg.: {'code': 0, 'msg': 'ok', 'data': {...}}
///
/// The code and data are optional.
T? _getRespData<T extends Object>(Object? resp) {
  return switch (resp) {
    final Map<dynamic, dynamic> m => extractData(m),
    null => null,
    _ => throw Exception('Invalid response: ${resp.runtimeType}, $resp'),
  };
}

T? extractData<T>(Map<dynamic, dynamic> m) {
  final code = m['code'];
  if (code != null && code != 0) {
    final msg = m['msg'] ?? 'Unknown error';
    throw Exception('Error: $code, $msg');
  }
  final data = m['data'];
  if (data is! T?) throw Exception('Invalid data type: $data');
  return data;
}
