import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/lkc/auth.dart';
import 'package:fl_lib/src/core/lkc/model.dart';
import 'package:fl_lib/src/core/store/secure.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// The `code` of a homebase reply.
enum LkcCode { ok, internal, perm, notFound, param, quota }

/// A request LKC Cloud refused, or a reply that isn't its.
final class LkcException implements Exception {
  /// Null when the reply isn't the API's: a proxy's error page, the object store.
  final LkcCode? code;

  /// A stable snake_case key saying what the user can fix, such as `file_quota`.
  /// Translate by it; [message] is its English text.
  final String? reason;
  final String? message;

  /// The HTTP status.
  final int? status;

  const LkcException({this.code, this.reason, this.message, this.status});

  /// The token is missing, expired or revoked, or the user lacks the right.
  bool get isPerm => code == LkcCode.perm;

  @override
  String toString() =>
      'LkcException(${code?.name ?? 'status $status'}${reason == null ? '' : ', $reason'})';
}

/// A client of LKC Cloud (homebase): sign-in, account, subscriptions and files.
///
/// The user signs in at the IdP with the app's public client ([LkcOidc]);
/// homebase is sent the IdP's access token, refreshed when it is about to end.
final class LkcClient {
  static const defaultBaseUrl = 'https://api.lollipopkit.com';

  final LkcOidc oidc;
  final Uri baseUrl;

  /// Whether this app may sell plans by the web checkout.
  ///
  /// Off on iOS and macOS: an App Store app may neither sell digital content
  /// outside of in-app purchase nor link to such a purchase (3.1.1, 3.1.3(b)).
  /// The Stripe portal can switch plans, so it is held to this too.
  final bool webCheckout;

  /// Where the tokens are kept.
  final SecureProp tokenProp;
  final Dio _api;

  /// Talks to the object store: never sends the token.
  final Dio _store;
  final LkcIdp _idp;

  LkcTokens? _tokens;

  /// The refresh in flight: one at a time, as the IdP takes a refresh token once.
  Future<LkcTokens>? _refreshing;

  /// The signed-in user, null when signed out.
  final user = ValueNotifier<LkcUser?>(null);

  /// The effective plan of each line the user holds one in, null until read.
  final entitlements = ValueNotifier<List<LkcEntitlement>?>(null);

  LkcClient({
    required this.oidc,
    Uri? baseUrl,
    bool? webCheckout,
    this.tokenProp = SecureStoreProps.lkcToken,
    Dio? api,
    Dio? store,
    Dio? idp,
    @visibleForTesting Future<bool> Function(Uri url)? openBrowser,
    @visibleForTesting bool? loopback,
  }) : baseUrl = baseUrl ?? Uri.parse(defaultBaseUrl),
       webCheckout = webCheckout ?? (!isIOS && !isMacOS),
       _api = api ?? Dio(),
       _store = store ?? Dio(),
       _idp = LkcIdp(
         oidc,
         (idp ?? Dio())..options.validateStatus = (_) => true,
         openBrowser:
             openBrowser ??
             (url) => launchUrl(url, mode: LaunchMode.externalApplication),
         loopback: loopback,
       ) {
    _api.options
      ..baseUrl = this.baseUrl.toString()
      ..validateStatus = (_) => true;
    _store.options.validateStatus = (_) => true;
  }

  bool get signedIn => _tokens != null;

  /// Load the saved tokens and their user. Tokens the IdP or homebase refuse
  /// are dropped; on any other error they are kept, and the error thrown.
  Future<void> init() async {
    final saved = await tokenProp.read();
    if (saved == null) return;
    try {
      _tokens = LkcTokens.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    } catch (_) {
      // TODO: rm once no build that kept a homebase token here is around.
      await tokenProp.write(null);
      return;
    }
    try {
      await refresh();
    } on LkcException catch (e) {
      if (e.isPerm) await _forget();
      rethrow;
    }
  }

  /// Re-read the user and the entitlements.
  Future<void> refresh() async {
    user.value = await _getUser();
    await refreshEntitlements();
  }

  /// Sign in at the IdP: AppAuth where the app has a URL scheme, a loopback
  /// redirect elsewhere. Null when the user cancels.
  Future<LkcUser?> signIn() async {
    final tokens = await _idp.signIn();
    if (tokens == null) return null;
    _tokens = tokens;
    try {
      var u = await _getUser();
      // homebase makes the account of a new IdP user from the token's subject
      // alone, so its name is the id until it is set.
      final name = tokens.name;
      if (u.name == u.id && name != null) {
        await _call('POST', '/auth/user', body: {'name': name});
        u = await _getUser();
      }
      await _save(tokens);
      user.value = u;
      await refreshEntitlements();
      return u;
    } catch (_) {
      if (user.value == null) _tokens = null;
      rethrow;
    }
  }

  /// Sign out here and end the session at the IdP.
  Future<void> signOut() async {
    final tokens = _tokens;
    await _forget();
    if (tokens != null) await _idp.revoke(tokens);
  }

  Future<void> _forget() async {
    _tokens = null;
    user.value = null;
    entitlements.value = null;
    await tokenProp.write(null);
  }

  Future<void> _save(LkcTokens tokens) =>
      tokenProp.write(jsonEncode(tokens.toJson()));

  /// The access token to send, refreshed once due.
  Future<String> _accessToken() async {
    final tokens = _tokens;
    if (tokens == null) throw const LkcException(code: LkcCode.perm);
    if (!tokens.due) return tokens.access;
    final refreshing = _refreshing ??= _refresh(tokens)
        .whenComplete(() => _refreshing = null);
    return (await refreshing).access;
  }

  Future<LkcTokens> _refresh(LkcTokens tokens) async {
    final LkcTokens fresh;
    try {
      fresh = await _idp.refresh(tokens);
    } on LkcException catch (e) {
      // The refresh token is spent or revoked: the session is over.
      if (e.isPerm) await _forget();
      rethrow;
    }
    _tokens = fresh;
    await _save(fresh);
    return fresh;
  }

  Future<LkcUser> _getUser() async => LkcUser.fromJson(
    await _call('GET', '/auth/user') as Map<String, dynamic>,
  );

  Future<void> updateUser({String? name, String? avatar}) async {
    await _call('POST', '/auth/user', body: {'name': ?name, 'avatar': ?avatar});
    user.value = await _getUser();
  }

  /// Whether the user has a subscription only its app store can cancel. Ask
  /// them to cancel it there before [deleteAccount]: the server can't, and it
  /// would keep renewing.
  Future<bool> hasStoreSubscription() async {
    final list = await refreshEntitlements();
    return list.any((e) => e.source.isStore && e.status != LkcStatus.canceled);
  }

  /// Delete the account and its files; web subscriptions are canceled.
  ///
  /// The tokens are revoked and dropped too: the IdP identity stays, and a
  /// valid token would make an empty account again.
  Future<void> deleteAccount() async {
    await _call('DELETE', '/auth/user');
    await signOut();
  }

  // Subscriptions

  Future<List<LkcEntitlement>> refreshEntitlements() async {
    final list = _list(
      await _call('GET', '/v2/entitlements'),
      LkcEntitlement.fromJson,
    );
    entitlements.value = list;
    return list;
  }

  /// The effective plan of [line], if any.
  LkcEntitlement? entitlementOf(LkcLine line) =>
      entitlements.value?.where((e) => e.line == line).firstOrNull;

  /// Every subscription, ended ones included, newest change first.
  Future<List<LkcEntitlement>> subscriptions() async => _list(
    await _call('GET', '/v2/billing/subscriptions'),
    LkcEntitlement.fromJson,
  );

  /// What every plan grants, and having none. Public: no sign-in needed.
  Future<LkcBenefits> benefits() async => LkcBenefits.fromJson(
    await _call('GET', '/v2/billing/benefits', auth: false) as List? ??
        const [],
  );

  /// The plan catalog. Public: no sign-in needed.
  Future<List<LkcPlan>> plans() async => _list(
    await _call('GET', '/v2/billing/plans', auth: false),
    LkcPlan.fromJson,
  );

  /// Open the Stripe checkout of [plan] in the browser, with a discount [code].
  /// The entitlements are read again when the app comes back.
  ///
  /// Throws [StateError] where [webCheckout] is off.
  Future<void> openCheckout(String plan, {String? code}) async {
    _checkWebCheckout();
    final res = await _call(
      'POST',
      '/v2/billing/stripe/checkout',
      body: {
        'plan': plan,
        if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
      },
    );
    await _openBilling(res);
  }

  /// Open the Stripe customer portal, where the user manages web subscriptions.
  ///
  /// Throws [StateError] where [webCheckout] is off.
  Future<void> openPortal() async {
    _checkWebCheckout();
    await _openBilling(await _call('POST', '/v2/billing/stripe/portal'));
  }

  void _checkWebCheckout() {
    if (!webCheckout) throw StateError('Web checkout is off on this platform');
  }

  AppLifecycleListener? _returnListener;

  Future<void> _openBilling(Object? res) async {
    final url = Uri.parse((res as Map<String, dynamic>)['url'] as String);
    _returnListener?.dispose();
    _returnListener = AppLifecycleListener(
      onResume: () {
        _returnListener?.dispose();
        _returnListener = null;
        unawaited(
          refreshEntitlements().then(
            (_) {},
            onError: (Object e) {
              debugPrint('LKC entitlements after billing: $e');
            },
          ),
        );
      },
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _returnListener?.dispose();
      _returnListener = null;
      throw StateError('No browser to open the billing page');
    }
  }

  // Files

  /// The files of [dir] (the user's own by default), newest first.
  Future<List<LkcFile>> files({String? dir}) async => _list(
    await _call('GET', '/file/meta', query: {'dir': ?dir}),
    LkcFile.fromJson,
  );

  /// What the files of [dir] (the user's own by default) take, and its quota.
  Future<LkcUsage> usage({String? dir}) async => LkcUsage.fromJson(
    await _call('GET', '/file/usage', query: {'dir': ?dir})
        as Map<String, dynamic>,
  );

  /// Upload [size] bytes of [data] straight to the object store, up to 5 GB.
  /// Returns the stored name.
  ///
  /// [name] is the stored name, a random one keeping [originalName]'s
  /// extension when null. Rejections carry the reasons `file_exists`,
  /// `file_too_large`, `file_quota`, `upload_unknown` and `upload_size`.
  Future<String> upload({
    required Stream<List<int>> data,
    required int size,
    required String originalName,
    String? name,
    String? dir,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    final upload = LkcUpload.fromJson(
      await _call(
        'POST',
        '/file/uploads',
        body: {
          'original_name': originalName,
          'size': size,
          'name': ?name,
          'dir': ?dir,
        },
      ) as Map<String, dynamic>,
    );
    final res = await _store.putUri<void>(
      upload.url,
      data: data,
      options: Options(
        headers: {Headers.contentLengthHeader: size},
        contentType: 'application/octet-stream',
        responseType: ResponseType.plain,
      ),
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) throw LkcException(status: status);
    return await _call('POST', '/file/uploads/${upload.id}/complete') as String;
  }

  /// [upload] of a local [file].
  Future<String> uploadFile(
    File file, {
    String? originalName,
    String? name,
    String? dir,
    ProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async => upload(
    data: file.openRead(),
    size: await file.length(),
    originalName: originalName ?? file.uri.pathSegments.last,
    name: name,
    dir: dir,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );

  /// A URL to download [name] from for about an hour, saved as its original name.
  Future<LkcLink> link(String name, {String? dir}) async => LkcLink.fromJson(
    await _call('GET', '/file/link', query: {'name': name, 'dir': ?dir})
        as Map<String, dynamic>,
  );

  /// Delete files by their stored names. Returns the names deleted; names
  /// without a file are skipped.
  Future<List<String>> deleteFiles(List<String> names, {String? dir}) async {
    final res = await _call(
      'DELETE',
      '/file',
      body: {'names': names, 'dir': ?dir},
    );
    return [for (final n in res as List? ?? const []) n as String];
  }

  // Transport

  /// The `data` of a homebase reply, or throws its rejection.
  Future<Object?> _call(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool auth = true,
  }) async {
    final token = auth ? await _accessToken() : null;
    final res = await _api.request<Object?>(
      path,
      queryParameters: query,
      data: body,
      options: Options(
        method: method,
        headers: {if (auth) HttpHeaders.authorizationHeader: 'Bearer $token'},
      ),
    );
    return unwrap(res.statusCode, res.data);
  }

  /// The `data` of a reply [body], or throws its rejection. Dio decodes a JSON
  /// reply; anything else, such as a proxy's error page, stays a string.
  @visibleForTesting
  static Object? unwrap(int? status, Object? body) {
    final Object? json;
    try {
      json = body is String && body.isNotEmpty ? jsonDecode(body) : body;
    } on FormatException {
      throw LkcException(status: status);
    }
    if (json is! Map<String, dynamic>) throw LkcException(status: status);
    // An `Ok` reply leaves the code out.
    final idx = json['code'] ?? 0;
    final code = idx is int && idx >= 0 && idx < LkcCode.values.length
        ? LkcCode.values[idx]
        : null;
    if (code == LkcCode.ok) return json['data'];
    final reason = json['reason'] as String?;
    final data = json['data'];
    throw LkcException(
      code: code,
      reason: reason,
      message: reason != null && data is String ? data : json['msg'] as String?,
      status: status,
    );
  }

  static List<T> _list<T>(
    Object? data,
    T Function(Map<String, dynamic>) fromJson,
  ) => [
    for (final e in data as List? ?? const [])
      fromJson(e as Map<String, dynamic>),
  ];

  void dispose() {
    _returnListener?.dispose();
    user.dispose();
    entitlements.dispose();
    _api.close();
    _store.close();
  }
}
