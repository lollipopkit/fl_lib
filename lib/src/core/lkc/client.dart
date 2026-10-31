import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/lkc/auth.dart';
import 'package:fl_lib/src/core/lkc/model.dart';
import 'package:fl_lib/src/core/rust.dart';
import 'package:fl_lib/src/rust/api/lkc.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/store/secure.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// The `code` of a homebase reply.
enum LkcCode { ok, internal, perm, notFound, param, quota }

/// A request LK Cloud refused, or a reply that isn't its.
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

/// A client of LK Cloud (homebase): sign-in, account, subscriptions and files.
///
/// The user signs in at the IdP with the app's public client ([LkcOidc]);
/// homebase is sent the IdP's access token. The tokens live in fl_lib's Rust
/// ([LkcSession], `fl_lkc`), the one place they are refreshed: the IdP takes a
/// refresh only in the access token's last minute and answers an early one,
/// or a spent one sent again, by ending every session of the person. This
/// side signs in in the browser and hands the tokens over.
final class LkcClient {
  static const defaultBaseUrl = 'https://api.lolli.tech';

  // Not on the object store: an upload of 5 GB takes as long as it takes.
  static const _connectTimeout = Duration(seconds: 15);
  static const _receiveTimeout = Duration(seconds: 30);

  final LkcOidc oidc;
  final Uri baseUrl;

  /// Whether this app may sell plans by the web checkout.
  ///
  /// Off on iOS and macOS: an App Store app may neither sell digital content
  /// outside of in-app purchase nor link to such a purchase (3.1.1, 3.1.3(b)).
  /// The Stripe portal can switch plans, so it is held to this too.
  final bool webCheckout;

  /// Where the session is kept, written by [LkcSession] through this side.
  final SecureProp tokenProp;
  final Dio _api;

  /// Talks to the object store: never sends the token.
  final Dio _store;
  final LkcIdp _idp;

  /// The session, restored from [tokenProp] the first time it is asked for.
  LkcSession? _session;
  Future<LkcSession>? _restoring;

  /// The signed-in user, null when signed out.
  final user = ValueNotifier<LkcUser?>(null);

  /// The effective plan of each line the user holds one in, null until read.
  final entitlements = ValueNotifier<List<LkcEntitlement>?>(null);

  /// What every plan grants, null until read. Public, as is [catalog].
  final benefits = ValueNotifier<LkcBenefits?>(null);

  /// The plan catalog, null until read.
  final catalog = ValueNotifier<LkcCatalog?>(null);

  /// What the user's own files take, null until read.
  final usage = ValueNotifier<LkcUsage?>(null);

  /// The last replies of the reads above, shown until the network answers.
  final LkcCache cache;

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
    LkcCache? cache,
  }) : cache = cache ?? LkcCache(),
       baseUrl = baseUrl ?? Uri.parse(defaultBaseUrl),
       webCheckout = webCheckout ?? (!isIOS && !isMacOS),
       _api = api ?? Dio(),
       _store = store ?? Dio(),
       _idp = LkcIdp(
         oidc,
         _timed(idp ?? Dio()),
         openBrowser:
             openBrowser ??
             (url) => launchUrl(url, mode: LaunchMode.externalApplication),
         loopback: loopback,
       ) {
    _timed(_api).options.baseUrl = this.baseUrl.toString();
    _store.options.validateStatus = (_) => true;
    benefits.value = _cached(
      _kBenefits,
      (d) => LkcBenefits.fromJson(_Tagged.of(d)!.data as List),
    );
    catalog.value = _cached(
      _kCatalog,
      (d) => LkcCatalog.fromJson(_Tagged.of(d)!.data),
    );
  }

  static const _kBenefits = 'benefits';
  static const _kCatalog = 'plans';
  static const _kUser = 'user';
  static const _kEntitlements = 'entitlements';

  /// This install's push registration, to drop it on the way out.
  static const _kDevice = 'device';

  /// [key]'s cached reply, parsed; null when there is none or it no longer parses.
  T? _cached<T>(String key, T Function(Object? data) parse) {
    final data = cache.read(key);
    if (data == null) return null;
    try {
      return parse(data);
    } catch (_) {
      cache.remove(key);
      return null;
    }
  }

  /// Replies of every status for the caller, and no request left hanging.
  static Dio _timed(Dio dio) {
    dio.options
      ..validateStatus = ((_) => true)
      ..connectTimeout = _connectTimeout
      ..receiveTimeout = _receiveTimeout;
    return dio;
  }

  bool get signedIn => _session?.signedIn() ?? false;

  /// A restore that failed (the keychain locked, the library not loaded) is
  /// tried again by the next caller.
  Future<LkcSession> _ensureSession() => _restoring ??= _restore().catchError(
    (Object e, StackTrace s) {
      _restoring = null;
      Error.throwWithStackTrace(e, s);
    },
  );

  Future<LkcSession> _restore() async {
    await FlRust.ensureInitialized();
    final saved = await tokenProp.read();
    final session = await LkcSession.restore(
      issuer: oidc.issuer.toString(),
      clientId: oidc.clientId,
      api: baseUrl.toString(),
      stored: saved,
      save: _saveSession,
    );
    // Kept by no build that reads it: a homebase token of the hand-off
    // sign-in (TODO: rm once no such build is around), or a half-written one.
    if (saved != null && !session.signedIn()) await _saveSession(null);
    return _session = session;
  }

  /// Written for [LkcSession], which sends a refresh only once its mark is.
  Future<bool> _saveSession(String? json) async {
    try {
      await tokenProp.write(json);
      return true;
    } catch (e) {
      debugPrint('LKC session not saved: ${e.runtimeType}');
      return false;
    }
  }

  /// One app's files on homebase ([LkcSync]), on this session.
  Future<LkcSync> sync(String app) async =>
      LkcSync(session: await _ensureSession(), app: app);

  /// Load the saved session and its user. A session the IdP or homebase
  /// refuses is dropped; on any other error it is kept, and the error thrown.
  Future<void> init() async {
    // The names of the lines the account row shows; the page reads it again.
    if (catalog.value == null) {
      unawaited(refreshCatalog().then((_) {}, onError: (_) {}));
    }
    final session = await _ensureSession();
    if (!session.signedIn()) return;
    // The account as last read, until homebase says it again.
    user.value ??= _cached(
      _kUser,
      (d) => LkcUser.fromJson(d as Map<String, dynamic>),
    );
    entitlements.value ??= _cached(
      _kEntitlements,
      (d) => _list(d, LkcEntitlement.fromJson),
    );
    try {
      await refresh();
    } on LkcException catch (e) {
      if (e.isPerm) await forget();
      rethrow;
    }
  }

  /// Re-read the user and the entitlements.
  Future<void> refresh() async {
    await _refreshUser();
    await refreshEntitlements();
    _refreshedAt = DateTime.now();
  }

  DateTime? _refreshedAt;

  /// Whether [refresh] ran in the last minute: a page opened again needn't.
  bool get fresh {
    final at = _refreshedAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 1);
  }

  Future<LkcUser> _refreshUser() async {
    final data = await _call('GET', '/auth/user');
    final u = LkcUser.fromJson(data as Map<String, dynamic>);
    user.value = u;
    cache.write(_kUser, data);
    return u;
  }

  /// Sign in at the IdP: AppAuth where the app has a URL scheme, a loopback
  /// redirect elsewhere. Null when the user cancels.
  Future<LkcUser?> signIn() async {
    final tokens = await _idp.signIn();
    if (tokens == null) return null;
    final session = await _ensureSession();
    try {
      await session.signIn(
        access: tokens.access,
        refresh: tokens.refresh,
        expiresAtMs: tokens.expiresAt.millisecondsSinceEpoch,
      );
    } on LkcError catch (e) {
      throw LkcException(message: e.detail);
    }
    try {
      final u = await _refreshUser();
      user.value = u;
      await refreshEntitlements();
      return u;
    } catch (_) {
      // Nobody to show for it: let the tokens go rather than keep them.
      if (user.value == null) await session.signOut();
      rethrow;
    }
  }

  /// Sign out here and end the session at the IdP.
  Future<void> signOut() async {
    await _unregisterDevice();
    _clear();
    await (await _ensureSession()).signOut();
  }

  /// Signed out here only: homebase refused the token.
  Future<void> forget() async {
    _clear();
    await _session?.forget();
  }

  void _clear() {
    _refreshedAt = null;
    usage.value = null;
    user.value = null;
    entitlements.value = null;
    cache
      ..remove(_kUser)
      ..remove(_kEntitlements);
  }

  /// The access token to send, refreshed by the session once due. A session
  /// that is over, or none: [LkcCode.perm].
  Future<String> _accessToken() async {
    final session = _session ?? await _ensureSession();
    // Asked without waiting while it needs no refresh: Rust says when it does.
    if (session.freshAccessToken() case final token?) return token;
    try {
      return await session.accessToken();
    } on LkcError catch (e) {
      if (e.failure == LkcFailure.rejected) {
        _clear();
        throw const LkcException(code: LkcCode.perm);
      }
      throw LkcException(message: e.detail);
    }
  }

  Future<void> updateUser({String? name, String? avatar}) async {
    await _call('POST', '/auth/user', body: {'name': ?name, 'avatar': ?avatar});
    user.value = await _refreshUser();
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
    await _unregisterDevice();
    await _call('DELETE', '/auth/user');
    await signOut();
  }

  // Push devices

  /// Register this device's APNs [token] for push to the signed-in user,
  /// after signing in and whenever the app has a token (it may change).
  ///
  /// [appId] is the APNs topic, the app's bundle id; [sandbox] is APNs'
  /// development environment, a debug or profile build's.
  Future<LkcDevice> registerDevice({
    required String token,
    required String appId,
    required bool sandbox,
  }) {
    final registering = _registerDevice(token, appId, sandbox);
    _registering = registering;
    return registering;
  }

  /// A registration in flight, which a sign-out waits for to drop what it adds.
  Future<LkcDevice>? _registering;

  Future<LkcDevice> _registerDevice(
    String token,
    String appId,
    bool sandbox,
  ) async {
    final device = LkcDevice.fromJson(
      await _call(
        'POST',
        '/v2/devices',
        body: {
          'platform': 'ios',
          'app_id': appId,
          'token': token,
          'sandbox': sandbox,
        },
      ) as Map<String, dynamic>,
    );
    cache.write(_kDevice, device.id);
    return device;
  }

  /// Every device registered for push to the user.
  Future<List<LkcDevice>> devices() async =>
      _list(await _call('GET', '/v2/devices'), LkcDevice.fromJson);

  Future<void> deleteDevice(String id) async {
    await _call('DELETE', '/v2/devices/${Uri.encodeComponent(id)}');
    if (cache.read(_kDevice) == id) cache.remove(_kDevice);
  }

  /// No more push here for the user who is leaving. Best effort: one that
  /// fails stays with the account until APNs reports the token gone, or the
  /// same token is registered again by whoever signs in next.
  Future<void> _unregisterDevice() async {
    await _registering?.then((_) {}, onError: (_) {});
    _registering = null;
    final id = cache.read(_kDevice);
    if (id is! String || !signedIn) return;
    try {
      await deleteDevice(id);
    } catch (e) {
      debugPrint('LKC device unregister: ${e.runtimeType}');
    }
  }

  // Subscriptions

  Future<List<LkcEntitlement>> refreshEntitlements() async {
    final data = await _call('GET', '/v2/entitlements');
    final list = _list(data, LkcEntitlement.fromJson);
    entitlements.value = list;
    cache.write(_kEntitlements, data);
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

  /// Read [benefits] again. Public: no sign-in needed.
  Future<LkcBenefits> refreshBenefits() async {
    final data = await _public('/v2/billing/benefits', _kBenefits);
    return benefits.value = LkcBenefits.fromJson(data as List? ?? const []);
  }

  /// Read [catalog] again. Public: no sign-in needed.
  Future<LkcCatalog> refreshCatalog() async {
    final data = await _public('/v2/billing/plans', _kCatalog);
    return catalog.value = LkcCatalog.fromJson(data);
  }

  /// The `data` of a public reply, kept under [key] with its ETag: the copy
  /// kept is sent for again, and a 304 confirms it.
  Future<Object?> _public(String path, String key) async {
    final kept = _Tagged.of(cache.read(key));
    final res = await _api.get<Object?>(
      path,
      options: Options(headers: {HttpHeaders.ifNoneMatchHeader: ?kept?.etag}),
    );
    if (res.statusCode == HttpStatus.notModified && kept != null) {
      return kept.data;
    }
    final data = unwrap(res.statusCode, res.data);
    cache.write(key, {
      'etag': ?res.headers.value(HttpHeaders.etagHeader),
      'data': data,
    });
    return data;
  }

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
  /// What the files of [dir] take, and its quota; the user's own, also kept
  /// in [usage], by default.
  Future<LkcUsage> refreshUsage({String? dir}) async {
    final u = LkcUsage.fromJson(
      await _call('GET', '/file/usage', query: {'dir': ?dir})
          as Map<String, dynamic>,
    );
    if (dir == null) usage.value = u;
    return u;
  }

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
    benefits.dispose();
    catalog.dispose();
    usage.dispose();
    _returnListener?.dispose();
    user.dispose();
    entitlements.dispose();
    _api.close();
    _store.close();
  }
}

/// A public reply kept with its ETag.
extension type const _Tagged(Map<String, dynamic> _json) {
  /// Null for none, or a copy kept before ETags were.
  static _Tagged? of(Object? json) =>
      json is Map<String, dynamic> ? _Tagged(json) : null;

  String? get etag => _json['etag'] as String?;
  Object? get data => _json['data'];
}

/// Replies kept in the app's preferences: nothing secret, the tokens are elsewhere.
class LkcCache {
  final String prefix;

  LkcCache({this.prefix = 'lkc_cache_'});

  Object? read(String key) {
    final raw = PrefStore.shared.get<String>('$prefix$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  void write(String key, Object? data) {
    // Not a setting: no backup or sync is due for it.
    unawaited(
      PrefStore.shared.set(
        '$prefix$key',
        jsonEncode(data),
        updateLastUpdateTsOnSet: false,
      ),
    );
  }

  void remove(String key) {
    unawaited(
      PrefStore.shared.remove('$prefix$key', updateLastUpdateTsOnRemove: false),
    );
  }
}

/// A cache held in memory only, for tests and for apps without preferences.
final class LkcMemoryCache extends LkcCache {
  final _data = <String, Object?>{};

  LkcMemoryCache();

  @override
  Object? read(String key) => _data[key];

  @override
  void write(String key, Object? data) => _data[key] = data;

  @override
  void remove(String key) => _data.remove(key);
}
