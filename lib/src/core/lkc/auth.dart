import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/lkc/client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

/// How an app signs in to LKC Cloud: its public client at the IdP, with S256 PKCE.
final class LkcOidc {
  static final defaultIssuer = Uri.parse(
    'https://auth.lollipopkit.com/auth/v1/',
  );

  final String clientId;

  /// Where the IdP sends an app with a URL scheme back (iOS, Android, macOS),
  /// such as `serverbox://auth/callback`. Elsewhere the redirect is a loopback
  /// one (RFC 8252 7.3), `http://127.0.0.1:<port>/oauth-callback`.
  final String redirectUrl;
  final Uri issuer;
  final List<String> scopes;

  LkcOidc({
    required this.clientId,
    required this.redirectUrl,
    Uri? issuer,
    this.scopes = const ['openid', 'profile'],
  }) : issuer = issuer ?? defaultIssuer;

  Uri get discoveryUrl => issuer.resolve('.well-known/openid-configuration');

  /// Whether [redirectUrl] is used here: the platforms AppAuth signs in on.
  static bool get native =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS);

  /// The path of the loopback redirect, which the IdP matches exactly.
  static const loopbackPath = '/oauth-callback';
}

/// The IdP's tokens. The access token is what homebase is sent.
final class LkcTokens {
  final String access;
  final String? refresh;

  /// Local time: when the token was received plus its `expires_in`.
  final DateTime expiresAt;
  final String? idToken;

  const LkcTokens({
    required this.access,
    required this.expiresAt,
    this.refresh,
    this.idToken,
  });

  /// How long before [expiresAt] a refresh is due.
  ///
  /// The IdP refuses a refresh token before the last minute of its access
  /// token, and answers an early use by revoking all of the user's sessions.
  /// [expiresAt] was taken on receipt, after the IdP's own clock started, so
  /// this window is entered no earlier than the IdP's; the margin under 60 s
  /// covers the request's own way there.
  static const refreshWindow = Duration(seconds: 45);

  bool get due => expiresAt.difference(DateTime.now()) < refreshWindow;

  /// A token response of the IdP; [previous] keeps a refresh token not rotated.
  factory LkcTokens.fromResponse(
    Map<String, dynamic> json, {
    LkcTokens? previous,
  }) => LkcTokens(
    access: json['access_token'] as String,
    refresh: json['refresh_token'] as String? ?? previous?.refresh,
    expiresAt: DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 0),
    ),
    idToken: json['id_token'] as String? ?? previous?.idToken,
  );

  factory LkcTokens.fromJson(Map<String, dynamic> json) => LkcTokens(
    access: json['access'] as String,
    refresh: json['refresh'] as String?,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expires_at'] as int),
    idToken: json['id_token'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'access': access,
    'refresh': ?refresh,
    'expires_at': expiresAt.millisecondsSinceEpoch,
    'id_token': ?idToken,
  };
}

/// The endpoints of the IdP's discovery document.
final class LkcIdpEndpoints {
  final Uri authorization;
  final Uri token;
  final Uri? revocation;

  const LkcIdpEndpoints({
    required this.authorization,
    required this.token,
    this.revocation,
  });

  factory LkcIdpEndpoints.fromJson(Map<String, dynamic> json) =>
      LkcIdpEndpoints(
        authorization: Uri.parse(json['authorization_endpoint'] as String),
        token: Uri.parse(json['token_endpoint'] as String),
        revocation: switch (json['revocation_endpoint']) {
          final String url => Uri.parse(url),
          _ => null,
        },
      );
}

/// Talks to the IdP: sign-in, refresh, revocation.
@internal
final class LkcIdp {
  final LkcOidc oidc;
  final Dio _dio;

  /// Opens the authorization page in the browser; replaced in tests.
  final Future<bool> Function(Uri url) openBrowser;

  /// Sign in by a loopback redirect rather than AppAuth.
  final bool loopback;

  LkcIdp(this.oidc, this._dio, {required this.openBrowser, bool? loopback})
    : loopback = loopback ?? !LkcOidc.native;

  LkcIdpEndpoints? _endpoints;

  Future<LkcIdpEndpoints> endpoints() async {
    if (_endpoints case final e?) return e;
    final res = await _dio.getUri<Map<String, dynamic>>(oidc.discoveryUrl);
    return _endpoints = LkcIdpEndpoints.fromJson(res.data!);
  }

  /// Sign in in the browser; null when the user cancels.
  Future<LkcTokens?> signIn() => loopback ? _signInLoopback() : _signInNative();

  Future<LkcTokens?> _signInNative() async {
    try {
      final res = await const FlutterAppAuth().authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          oidc.clientId,
          oidc.redirectUrl,
          discoveryUrl: oidc.discoveryUrl.toString(),
          scopes: oidc.scopes,
        ),
      );
      final access = res.accessToken;
      if (access == null) throw const LkcException(code: LkcCode.perm);
      return LkcTokens(
        access: access,
        refresh: res.refreshToken,
        expiresAt: res.accessTokenExpirationDateTime ?? DateTime.now(),
        idToken: res.idToken,
      );
    } on FlutterAppAuthUserCancelledException {
      return null;
    }
  }

  /// RFC 8252 7.3: a one-off listener on 127.0.0.1 takes the code.
  Future<LkcTokens?> _signInLoopback() async {
    final endpoints = await this.endpoints();
    final verifier = _random(64);
    final state = _random(32);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}${LkcOidc.loopbackPath}';
      final url = endpoints.authorization.replace(
        queryParameters: {
          ...endpoints.authorization.queryParameters,
          'response_type': 'code',
          'client_id': oidc.clientId,
          'redirect_uri': redirect,
          'scope': oidc.scopes.join(' '),
          'state': state,
          'code_challenge': base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''),
          'code_challenge_method': 'S256',
        },
      );
      // Listening before the browser opens: a redirect may come back at once.
      final answer = _awaitCode(server, state);
      // Awaited below; until then a refused redirect is no unhandled error.
      unawaited(answer.then((_) {}, onError: (_) {}));
      if (!await openBrowser(url)) {
        throw StateError('No browser to sign in with');
      }
      final code = await answer.timeout(const Duration(minutes: 10));
      if (code == null) return null;
      final res = await _dio.postUri<Map<String, dynamic>>(
        endpoints.token,
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirect,
          'client_id': oidc.clientId,
          'code_verifier': verifier,
        },
        options: _form,
      );
      return LkcTokens.fromResponse(_tokenResponse(res));
    } finally {
      await server.close(force: true);
    }
  }

  /// The code of the redirect carrying [state]; null when the user declined.
  static Future<String?> _awaitCode(HttpServer server, String state) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      // Anything else a browser asks for (an icon) is no answer.
      if (req.uri.path != LkcOidc.loopbackPath || q['state'] != state) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        continue;
      }
      req.response
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8"><p>You can close this page and return to the app.</p>',
        );
      await req.response.close();
      final code = q['code'];
      if (code != null && code.isNotEmpty) return code;
      if (q['error'] == 'access_denied') return null;
      throw LkcException(
        code: LkcCode.perm,
        message: q['error_description'] ?? q['error'],
      );
    }
    return null;
  }

  /// New tokens for [tokens]. Throws [LkcException] with [LkcCode.perm] when
  /// the IdP refuses the refresh token: the session is over.
  Future<LkcTokens> refresh(LkcTokens tokens) async {
    final refresh = tokens.refresh;
    if (refresh == null) throw const LkcException(code: LkcCode.perm);
    final endpoints = await this.endpoints();
    final res = await _dio.postUri<Map<String, dynamic>>(
      endpoints.token,
      data: {
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'client_id': oidc.clientId,
      },
      options: _form,
    );
    return LkcTokens.fromResponse(_tokenResponse(res), previous: tokens);
  }

  /// Revoke the refresh token, best effort: the local tokens go either way.
  Future<void> revoke(LkcTokens tokens) async {
    final refresh = tokens.refresh;
    if (refresh == null) return;
    try {
      final endpoint = (await endpoints()).revocation;
      if (endpoint == null) return;
      await _dio.postUri<void>(
        endpoint,
        data: {
          'token': refresh,
          'token_type_hint': 'refresh_token',
          'client_id': oidc.clientId,
        },
        options: _form,
      );
    } catch (e) {
      debugPrint('LKC revoke: ${e.runtimeType}');
    }
  }

  static final _form = Options(contentType: Headers.formUrlEncodedContentType);

  /// The body of a token reply, or the refusal: 4xx is the grant's end.
  static Map<String, dynamic> _tokenResponse(
    Response<Map<String, dynamic>> res,
  ) {
    final status = res.statusCode ?? 0;
    final body = res.data;
    if (status >= 200 &&
        status < 300 &&
        body != null &&
        body['access_token'] is String) {
      return body;
    }
    throw LkcException(
      code: status >= 400 && status < 500 ? LkcCode.perm : null,
      reason: body?['error'] as String?,
      status: status,
    );
  }

  static final _rng = Random.secure();
  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String _random(int length) => String.fromCharCodes(
    List.generate(
      length,
      (_) => _chars.codeUnitAt(_rng.nextInt(_chars.length)),
    ),
  );
}
