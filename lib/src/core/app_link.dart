import 'package:flutter/widgets.dart';

/// Signature for deep link handlers.
///
/// - [uri]: The incoming deep link URI.
/// - [context]: Optional build context for navigations or dialogs.
typedef DeepLinkHandler = void Function(Uri uri, [BuildContext? context]);

/// Central dispatcher for handling app deep links.
///
/// Register handlers via [register]. There are no built-in ones: the only one
/// there ever was routed an OAuth callback to a backend this library no longer
/// talks to.
abstract final class DeepLinks {
  static final _handlers = <DeepLinkHandler>{};

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
}
