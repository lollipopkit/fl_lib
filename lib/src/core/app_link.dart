import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/widgets.dart';

/// Signature for deep link handlers.
///
/// - [uri]: The incoming deep link URI.
/// - [context]: Optional build context for navigations or dialogs.
typedef DeepLinkHandler = void Function(Uri uri, [BuildContext? context]);

/// Central dispatcher for handling app deep links.
///
/// Register custom handlers via [register]. The first built‑in handler
/// dispatches by URI scheme and routes known links to internal actions.
abstract final class DeepLinks {
  static final _handlers = <DeepLinkHandler>{_dispatchScheme};

  /// Your app identifier used to validate incoming hosts (e.g. bundle id).
  static String? appId;

  /// Register a [handler] to receive incoming deep links.
  static void register(DeepLinkHandler handler) {
    _handlers.add(handler);
  }

  /// Remove a previously registered [handler].
  static void remove(DeepLinkHandler handler) {
    _handlers.remove(handler);
  }

  /// Dispatch an incoming [uri] to all registered handlers.
  ///
  /// Handlers are invoked in insertion order. Provide [context] when you need
  /// to perform navigations or UI operations.
  static void process(Uri uri, [BuildContext? context]) async {
    for (final handler in _handlers) {
      handler(uri, context);
    }
  }

  /// Internal dispatcher based on URI scheme and configured [appId].
  static void _dispatchScheme(Uri uri, [BuildContext? context]) {
    if (appId == null) {
      throw StateError('[this.appId] is not set');
    }

    switch (uri.scheme) {
      case 'lpkt.cn':
        _lpktcnHandler(uri, context);
        break;
    }
  }

  /// Handler for `lpkt.cn://<appId>/...` deep links.
  static void _lpktcnHandler(Uri uri, [BuildContext? context]) {
    if (uri.host == appId!) {
      _generalHandler(uri, context);
    } else {
      Loggers.app.warning('[AppLinksHandler] Unknown host: ${uri.host}');
    }
  }

  /// General path dispatcher for recognized links.
  static void _generalHandler(Uri uri, [BuildContext? context]) async {
    final params = uri.queryParameters;

    switch (uri.path) {
      case '/oauth-callback':
        final token = params['token'];
        if (token == null) return;
        await UserApi.tokenProp.set(token);
        await UserApi.refresh();
        break;
      default:
        Loggers.app.warning('[AppLinksHandler] Unknown path: ${uri.path}');
    }
  }
}
