import 'dart:io';

import 'package:test/test.dart';
import 'package:xtask/src/resolve.dart';

/// A resolver over a made-up filesystem.
///
/// The whole point of the seam: every case below runs identically on macOS,
/// Linux and Windows, and the Windows cases are the ones worth having.
///
/// **The fake filesystem is case-insensitive when [windows] is**, and that is
/// not a convenience. `PATHEXT` is spelled in capitals, files are named in
/// lower case, and the reason `dart` finds `dart.bat` at all is that NTFS does
/// not care. A case-sensitive fake would model a platform that does not exist
/// and would fail every Windows case here for a reason Windows does not have.
ExecutableResolver resolver({
  required bool windows,
  required Map<String, String> environment,
  required Set<String> files,
}) {
  final present = windows ? files.map((f) => f.toLowerCase()).toSet() : files;
  return ExecutableResolver(
    environment: environment,
    windows: windows,
    exists: (path) => present.contains(windows ? path.toLowerCase() : path),
  );
}

void main() {
  group('POSIX', () {
    ExecutableResolver withPath(String path, Set<String> files) =>
        resolver(windows: false, environment: {'PATH': path}, files: files);

    test('finds a bare name in the first directory that has it', () {
      final r = withPath('/a:/b', {'/b/dart', '/a/other'});
      expect(r.resolve('dart'), '/b/dart');
    });

    test('prefers the earlier directory', () {
      final r = withPath('/a:/b', {'/a/dart', '/b/dart'});
      expect(r.resolve('dart'), '/a/dart');
    });

    test('answers null when nothing has it', () {
      expect(withPath('/a:/b', {'/a/other'}).resolve('dart'), isNull);
    });

    test('skips empty PATH entries rather than searching the root', () {
      // A trailing colon is common and means "and the current directory" to
      // some shells. Searching '' would join to a bare relative name.
      final r = withPath('/a::', {'dart'});
      expect(r.resolve('dart'), isNull);
    });

    test('never appends a suffix', () {
      expect(withPath('/a', {'/a/dart.exe'}).resolve('dart'), isNull);
    });

    test('an empty name resolves to nothing', () {
      expect(withPath('/a', {'/a/'}).resolve(''), isNull);
    });
  });

  group('a name that is already a path', () {
    test('is used as given, not searched for', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        files: {'./tool/gen', '/a/gen'},
      );
      expect(r.resolve('./tool/gen'), './tool/gen');
    });

    test('missing is missing — PATH is not consulted as a fallback', () {
      // §5.4 rule 1: the author said where it is. Falling back to PATH would
      // run a different program than the one named, silently.
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        files: {'/a/gen'},
      );
      expect(r.resolve('./tool/gen'), isNull);
    });

    test('a Windows backslash path counts as a path', () {
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin'},
        files: {r'tool\gen.bat'},
      );
      expect(r.resolve(r'tool\gen.bat'), r'tool\gen.bat');
    });
  });

  group('Windows', () {
    ExecutableResolver windowsWith(
      Set<String> files, {
      Map<String, String>? environment,
    }) => resolver(
      windows: true,
      environment: environment ?? {'PATH': r'C:\bin;C:\sdk'},
      files: files,
    );

    test('a bare name matches a batch shim — the case that broke §5.2', () {
      // `run: [dart, analyze]`, the very first example in xtask.md, with no
      // dart.exe anywhere: on Windows `dart` is `dart.bat`.
      final r = windowsWith({r'C:\sdk\dart.bat'});
      // `.BAT`, not `.bat`: the suffix comes from PATHEXT, not from disk.
      expect(r.resolve('dart'), r'C:\sdk\dart.BAT');
    });

    test('splits PATH on `;`, not `:` — a drive letter is not a separator', () {
      final r = windowsWith({r'C:\sdk\dart.exe'});
      expect(r.resolve('dart'), r'C:\sdk\dart.EXE');
    });

    test('honours the machine PATHEXT over the default', () {
      final r = windowsWith(
        {r'C:\bin\tool.ps1'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.PS1'},
      );
      expect(r.resolve('tool'), r'C:\bin\tool.PS1');
    });

    test('a PATHEXT that omits .BAT means .bat does not resolve', () {
      final r = windowsWith(
        {r'C:\bin\tool.bat'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.EXE'},
      );
      expect(r.resolve('tool'), isNull);
    });

    test('falls back to the documented default when PATHEXT is unset', () {
      final r = windowsWith(
        {r'C:\bin\tool.CMD'},
        environment: {
          'PATH': r'C:\bin',
        },
      );
      expect(r.resolve('tool'), r'C:\bin\tool.CMD');
    });

    test('tries PATHEXT in the order the machine gives', () {
      final r = windowsWith(
        {r'C:\bin\tool.CMD', r'C:\bin\tool.EXE'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.CMD;.EXE'},
      );
      expect(r.resolve('tool'), r'C:\bin\tool.CMD');
    });

    test("the answer carries PATHEXT's spelling, not the disk's", () {
      // Stated as its own case because it is observable: --dry-run prints
      // resolved command lines (§7), and this is what appears there. It is
      // harmless — NTFS does not care — but somebody will read it and wonder,
      // and a surprise nobody wrote down is a bug report waiting to happen.
      final r = windowsWith(
        {r'C:\bin\tool.bat'},
        environment: {
          'PATH': r'C:\bin',
          'PATHEXT': '.BAT',
        },
      );
      expect(r.resolve('tool'), r'C:\bin\tool.BAT');
    });

    test('a name written with its extension resolves to itself', () {
      // Not `tool.exe.COM`. The reference this was ported from tries only the
      // PATHEXT suffixes and would miss `run: [tool.exe, ...]`.
      final r = windowsWith({r'C:\bin\tool.exe'});
      expect(r.resolve('tool.exe'), r'C:\bin\tool.exe');
    });

    test('reads `Path`, which is how Windows actually spells it', () {
      // `Platform.environment` hides the case on Windows; an injected map does
      // not, and a rule that works on the machine but not in its test is worse
      // than either.
      final r = windowsWith(
        {r'C:\bin\dart.bat'},
        environment: {'Path': r'C:\bin'},
      );
      expect(r.resolve('dart'), r'C:\bin\dart.BAT');
    });
  });

  group('needsShell', () {
    test('a batch shim on Windows does', () {
      final r = resolver(windows: true, environment: {}, files: {});
      expect(r.needsShell(r'C:\sdk\dart.bat'), isTrue);
      expect(r.needsShell(r'C:\sdk\dart.CMD'), isTrue);
    });

    test('a real executable on Windows does not', () {
      final r = resolver(windows: true, environment: {}, files: {});
      expect(r.needsShell(r'C:\sdk\dart.exe'), isFalse);
    });

    test('nothing on POSIX does — there are no shims to accommodate', () {
      final r = resolver(windows: false, environment: {}, files: {});
      expect(r.needsShell('/usr/bin/dart'), isFalse);
      expect(r.needsShell('/usr/bin/dart.bat'), isFalse);
    });
  });

  group('the message a missing tool gets', () {
    test('names the tool and says where it looked', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a:/b:/c'},
        files: {},
      );
      final message = r.missingToolMessage('dart');
      expect(message, contains('`dart`'));
      expect(message, contains('3 directories'));
    });

    test('on Windows it also says which suffixes were tried', () {
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.EXE;.BAT'},
        files: {},
      );
      expect(r.missingToolMessage('dart'), contains('.EXE, .BAT'));
    });

    test('a path that is not there says so, without mentioning PATH', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        files: {},
      );
      final message = r.missingToolMessage('./tool/gen');
      expect(message, contains('no file at `./tool/gen`'));
      expect(message, isNot(contains('directories on PATH')));
    });
  });

  group('the host resolver', () {
    test('finds the Dart running this test', () {
      // The one case the seam cannot cover: that the injected rules and the
      // real machine agree. `Platform.resolvedExecutable` is a program known
      // to exist, so a null here means the host wiring is wrong.
      final dart = File(Platform.resolvedExecutable);
      expect(ExecutableResolver.forHost().resolve(dart.path), dart.path);
    });

    test('does not find a name nothing answers to', () {
      final r = ExecutableResolver.forHost();
      expect(r.resolve('xtask-no-such-program-4f3a9'), isNull);
    });
  });
}
