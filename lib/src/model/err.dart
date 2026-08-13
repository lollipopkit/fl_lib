import 'package:fl_lib/fl_lib.dart';

/// {@template fllib_err}
/// An abstract class representing an error with a type and an optional message.
/// {@endtemplate}
abstract class Err<T extends Enum> {
  /// The type of the error, represented as an enum.
  final T type;

  /// An optional message providing additional information about the error.
  final String? message;

  /// The solution for the error, if available.
  ///
  /// ```dart
  /// String? get solution => switch (type) {
  ///   ErrType.network => 'Check your internet connection.',
  ///   ErrType.timeout => 'Try again later.',
  /// };
  /// ```
  String? get solution;

  /// {@macro fllib_err}
  const Err({required this.type, this.message});

  @override
  String toString() {
    return '$runtimeType<${type.name.capitalize}>: $message';
  }

  /// Two errors describing the same thing are the same error.
  ///
  /// Without this, an operation that retries and fails the same way produces a
  /// new instance every time, and anything holding one in state — a Riverpod
  /// state class, a `ValueNotifier` — reports a change on every attempt. A page
  /// showing the error then rebuilds on a timer and visibly flickers, for a
  /// failure that never changed.
  ///
  /// [runtimeType] is part of it so two error families with the same enum
  /// index do not collide.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Err<T> &&
          other.runtimeType == runtimeType &&
          other.type == type &&
          other.message == message;

  @override
  int get hashCode => Object.hash(runtimeType, type, message);
}
