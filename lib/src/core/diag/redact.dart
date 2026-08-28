/// Turns a value into what it *was*, for a log that will be made public.
///
/// The question a crumb has to answer is almost never "which host" but "the
/// same host as the line above?" and "what kind of thing was it?". These keep
/// the first two and drop the rest.
///
/// Not a security boundary, and it must not be relied on as one: [id] is short
/// enough to brute-force over a small input space, so an IPv4 address hashed
/// with no [salt] is recoverable by someone who cares to. Pass a per-install
/// salt when the value being hidden comes from a space that small — the
/// identity stays stable within one install's log, which is all a report needs,
/// and stops meaning anything outside it.
abstract final class Redact {
  /// A short, stable stand-in for [value].
  ///
  /// Equal values give equal output within a run and across runs, so two
  /// crumbs naming the same server can be seen to name the same server.
  static String id(String? value, {String salt = ''}) {
    if (value == null || value.isEmpty) return '-';
    // FNV-1a, for being short, dependency-free and deterministic across
    // processes — `String.hashCode` is none of the three by contract.
    var hash = 0x811c9dc5;
    for (final unit in '$salt$value'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// What kind of address this is, without saying which one.
  ///
  /// Whether a failure is against loopback, something on the LAN, or something
  /// on the internet is most of what an address contributes to a bug report,
  /// and it is the part that is not the user's infrastructure.
  static String host(String? value, {String salt = ''}) {
    if (value == null || value.isEmpty) return '-';
    final kind = switch (value) {
      'localhost' || '127.0.0.1' || '::1' => 'loopback',
      _ when _isPrivateV4(value) => 'private',
      _ when value.contains(':') => 'ipv6',
      _ when _v4.hasMatch(value) => 'public',
      _ => 'name',
    };
    return '$kind/${id(value, salt: salt)}';
  }

  /// The shape of a path: how deep, what extension, whether it was absolute.
  ///
  /// A directory name is as identifying as a hostname — `/home/<user>` names
  /// the user — while "six levels down, a .conf, absolute" is what makes a
  /// path-handling bug reproducible.
  static String path(String? value) {
    if (value == null || value.isEmpty) return '-';
    final absolute = value.startsWith('/') || _winRoot.hasMatch(value);
    final parts = value.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
    final name = parts.isEmpty ? '' : parts.last;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    return '${absolute ? 'abs' : 'rel'}:${parts.length}$ext';
  }

  /// The first word of a command line, which is the program, with the
  /// arguments — where the hostnames, passwords and paths are — dropped.
  static String command(String? value) {
    if (value == null || value.isEmpty) return '-';
    final trimmed = value.trimLeft();
    final end = trimmed.indexOf(RegExp(r'\s'));
    final program = end == -1 ? trimmed : trimmed.substring(0, end);
    // An absolute path to the program names directories on the way to it.
    final slash = program.lastIndexOf(RegExp(r'[/\\]'));
    return slash == -1 ? program : program.substring(slash + 1);
  }

  /// The type of an error, without the message — which routinely quotes the
  /// path, host or command that caused it.
  static String error(Object? value) {
    if (value == null) return '-';
    return value.runtimeType.toString();
  }

  static final _v4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static final _winRoot = RegExp(r'^[a-zA-Z]:[/\\]');

  static bool _isPrivateV4(String value) {
    if (!_v4.hasMatch(value)) return false;
    final octets = value.split('.').map(int.parse).toList();
    return switch (octets) {
      [10, _, _, _] => true,
      [192, 168, _, _] => true,
      [172, final b, _, _] when b >= 16 && b <= 31 => true,
      // Link-local, which is what an interface with no DHCP lease ends up on.
      [169, 254, _, _] => true,
      _ => false,
    };
  }
}
