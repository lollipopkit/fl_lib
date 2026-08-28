import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

/// These decide what a bug report discloses about the machines a user runs.
/// The property that matters is not that the output looks scrambled but that
/// the input cannot be read off it, so each case names the thing that must not
/// appear.
void main() {
  group('id', () {
    test('is stable, so two crumbs can be seen to name the same thing', () {
      expect(Redact.id('server-a'), Redact.id('server-a'));
    });

    test('separates different values', () {
      expect(Redact.id('server-a'), isNot(Redact.id('server-b')));
    });

    test('never contains the input', () {
      expect(Redact.id('secret-host'), isNot(contains('secret')));
    });

    test('a salt breaks correlation between installs', () {
      // What makes a short hash of an IPv4 address safe: the space is small
      // enough to enumerate, so the identity has to stop meaning anything
      // outside the one log it appears in.
      expect(
        Redact.id('10.0.0.1', salt: 'install-a'),
        isNot(Redact.id('10.0.0.1', salt: 'install-b')),
      );
    });

    test('empty and null are not hashed into something that looks real', () {
      expect(Redact.id(null), '-');
      expect(Redact.id(''), '-');
    });
  });

  group('host', () {
    test('keeps which kind of address it was', () {
      expect(Redact.host('127.0.0.1'), startsWith('loopback/'));
      expect(Redact.host('localhost'), startsWith('loopback/'));
      expect(Redact.host('192.168.1.10'), startsWith('private/'));
      expect(Redact.host('10.1.2.3'), startsWith('private/'));
      expect(Redact.host('172.16.0.1'), startsWith('private/'));
      expect(Redact.host('169.254.1.1'), startsWith('private/'));
      expect(Redact.host('8.8.8.8'), startsWith('public/'));
      expect(Redact.host('example.com'), startsWith('name/'));
      expect(Redact.host('fe80::1'), startsWith('ipv6/'));
    });

    test('172.32 is public, so the private range is not read too widely', () {
      expect(Redact.host('172.32.0.1'), startsWith('public/'));
      expect(Redact.host('172.15.0.1'), startsWith('public/'));
    });

    test('drops the address itself', () {
      expect(Redact.host('192.168.1.10'), isNot(contains('192')));
      expect(Redact.host('secret.internal'), isNot(contains('secret')));
    });
  });

  group('path', () {
    test('keeps the shape and drops the names', () {
      // `/home/<user>` names the user; "four deep, a .conf, absolute" is what
      // makes a path bug reproducible.
      expect(Redact.path('/home/alice/etc/nginx.conf'), 'abs:4.conf');
      expect(Redact.path('docs/readme.md'), 'rel:2.md');
      expect(Redact.path(r'C:\Users\alice\file.txt'), 'abs:4.txt');
    });

    test('drops directory names', () {
      expect(Redact.path('/home/alice/secret'), isNot(contains('alice')));
    });

    test('a name with no extension yields none', () {
      expect(Redact.path('/var/log'), 'abs:2');
    });

    test('a dotfile is not read as an extension', () {
      // `.bashrc` is the whole name, not an extension, and treating it as one
      // would publish it as `.bashrc` while claiming to have dropped names.
      expect(Redact.path('/home/alice/.bashrc'), 'abs:3');
    });
  });

  group('command', () {
    test('keeps the program and drops the arguments', () {
      // The arguments are where the hosts, paths and passwords are.
      expect(Redact.command('ssh user@10.0.0.1 -p 2222'), 'ssh');
      expect(Redact.command('/usr/bin/smartctl -a /dev/sda'), 'smartctl');
    });

    test('drops the directories leading to the program', () {
      expect(Redact.command('/home/alice/bin/tool --x'), 'tool');
    });

    test('handles leading whitespace and a bare program', () {
      expect(Redact.command('  uptime'), 'uptime');
      expect(Redact.command('uptime'), 'uptime');
    });
  });

  group('error', () {
    test('keeps the type and drops the message', () {
      // An exception message routinely quotes the path, host or command that
      // caused it, which is exactly what must not be published.
      const e = FormatException('cannot parse /home/alice/secret.conf');
      expect(Redact.error(e), 'FormatException');
      expect(Redact.error(e), isNot(contains('alice')));
    });
  });
}
