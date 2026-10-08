/// What the Gist settings dialog is given and what it is told back.
///
/// A link pasted as the id used to be sent as is and came back 404, shown as
/// a raw `DioException` with nothing to say what was wrong.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'cc99f2bd38689633d7d573233c192aae';

void main() {
  group('idOf', () {
    test('an id as is', () {
      expect(GistRs.idOf(_id), _id);
      expect(GistRs.idOf('  $_id\n'), _id);
      expect(GistRs.idOf('1234567'), '1234567');
    });

    test('the id at the end of a link', () {
      for (final link in [
        'https://gist.github.com/someone/$_id',
        'https://gist.github.com/someone/$_id/',
        'https://gist.github.com/$_id',
        'https://gist.github.com/someone/$_id#file-backup-json',
        'https://gist.github.com/someone/$_id?permalink_comment_id=1',
        'https://gist.github.com/$_id.git',
        'https://api.github.com/gists/$_id',
      ]) {
        expect(GistRs.idOf(link), _id, reason: link);
      }
    });

    test('nothing that is not one', () {
      for (final input in [
        '',
        '   ',
        'https://github.com/someone/$_id',
        'https://api.github.com/users/someone',
        'https://gist.github.com/',
        'not an id',
        'gist.github.com/someone/$_id',
      ]) {
        expect(GistRs.idOf(input), isNull, reason: input);
      }
    });
  });

  group('test', () {
    Future<Object?> failureFor(int status, {String? gistId}) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'))
        ..httpClientAdapter = _StatusAdapter(status);
      try {
        await GistRs.test(token: 't', gistId: gistId, client: dio);
        return null;
      } catch (e) {
        return e;
      }
    }

    test('passes on 200', () async {
      expect(await failureFor(200), isNull);
      expect(await failureFor(200, gistId: _id), isNull);
    });

    test('a token GitHub refuses', () async {
      for (final status in [401, 403]) {
        final e = await failureFor(status);
        expect(e, isA<GistTestException>(), reason: '$status');
        expect((e as GistTestException).reason, GistTestFailure.badToken);
      }
    });

    test('a gist the token cannot find', () async {
      final e = await failureFor(404, gistId: _id);
      expect(e, isA<GistTestException>());
      expect((e as GistTestException).reason, GistTestFailure.notFound);
    });

    test('anything else is thrown as it is', () async {
      expect(await failureFor(500), isA<DioException>());
      expect(await failureFor(404), isA<DioException>());
    });
  });
}

final class _StatusAdapter implements HttpClientAdapter {
  final int status;

  _StatusAdapter(this.status);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
