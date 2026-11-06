import 'package:fl_lib/src/core/lkc/client.dart';
import 'package:fl_lib/src/core/store/secure.dart';
import 'package:fl_lib/src/rust/api/team.dart';

/// The account's teams on this device: its account key once opened with
/// the LK Cloud key password, and what was verified of its teams (the
/// signing keys met, each team's last epoch), both in the synced keychain,
/// per account. Everything else is Rust's ([LkcTeamKeys]).
final class LkcTeamAccount {
  LkcTeamAccount(this.client);

  final LkcClient client;

  String get _account {
    final id = client.user.value?.id;
    if (id == null) throw StateError('LK Cloud: not signed in');
    return id;
  }

  SecureProp get _keyProp => SecureProp('lkcAccountKey.$_account', storage: SecureStore.synced);

  /// The open keys, and whose.
  (String, LkcTeamKeys)? _open;

  /// One open at a time: each sees the keys the one before opened, so one
  /// account never has two trusts written over each other.
  Future<void> _lock = Future.value();

  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// The teams with the account key kept here; null until [unlock].
  Future<LkcTeamKeys?> open() => _serial(() async {
    if (_open case (final account, final open) when account == _account) return open;
    final text = await _keyProp.read();
    if (text == null) return null;
    return _opened(LkcAccountKey.fromText(text: text));
  });

  /// The account key opened with [passphrase] (made now if no device of the
  /// account's has one), published and kept here; then every team whose keys
  /// are wrapped to an older one of the account's rewrapped. Throws
  /// [LkcTeamError] of [LkcTeamErrorKind.wrongPassphrase] when it does not
  /// open it. Also after [LkcTeamErrorKind.accountKeyReplaced]. Teams whose
  /// rewrap failed are in [LkcTeamKeys.rewrapTeams]' answer, run again later.
  Future<(LkcTeamKeys, List<LkcTeamFailure>)> unlock(String passphrase) async {
    final teams = await _serial(() async {
      final key = await (await client.teams()).accountKey(passphrase: passphrase);
      await _keyProp.write(key.toText());
      return _opened(key);
    });
    return (teams, await teams.rewrapTeams());
  }

  /// New account keys in place of these (a device lost trust), kept here
  /// as soon as LK Cloud has them; then every team's keys rewrapped to them,
  /// each team asked for a new key. One cut short is finished by [unlock].
  Future<(LkcTeamKeys, List<LkcTeamFailure>)> rotate(String passphrase) async {
    final teams = await _serial(() async {
      final key = await (await client.teams()).rotateAccountKey(passphrase: passphrase);
      await _keyProp.write(key.toText());
      return _opened(key);
    });
    return (teams, await teams.rewrapTeams());
  }

  /// Forgets the account key here; it stays on LK Cloud.
  Future<void> forget() => _serial(() async {
    _open = null;
    await _keyProp.write(null);
  });

  /// [key] open: under the keys already open for its account when there
  /// are, so one trust is kept, never two written over each other.
  Future<LkcTeamKeys> _opened(LkcAccountKey key) async {
    if (_open case (final account, final open) when account == key.userId()) {
      final teams = open.withKey(key: key);
      _open = (account, teams);
      return teams;
    }
    // Kept under the account the key is of, whoever is signed in later.
    final trustProp = SecureProp('lkcTeamTrust.${key.userId()}', storage: SecureStore.synced);
    final teams = await (await client.teams()).open(
      key: key,
      trust: await trustProp.read() ?? '',
      save: (json) async {
        try {
          await trustProp.write(json);
          return true;
        } catch (_) {
          return false;
        }
      },
    );
    _open = (key.userId(), teams);
    return teams;
  }
}
