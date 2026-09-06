import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/executables.dart';

import 'helpers.dart';

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
  required Set<String> runnable,
}) {
  final present = windows
      ? runnable.map((f) => f.toLowerCase()).toSet()
      : runnable;
  return ExecutableResolver(
    environment: environment,
    windows: windows,
    isRunnable: (path) => present.contains(windows ? path.toLowerCase() : path),
  );
}

void main() {
  group('POSIX', () {
    ExecutableResolver withPath(String path, Set<String> runnable) => resolver(
      windows: false,
      environment: {'PATH': path},
      runnable: runnable,
    );

    test('finds a bare name in the first directory that has it', () {
      final r = withPath('/a:/b', {'/b/dart', '/a/other'});
      expect(r.resolve('dart', from: '/repo'), '/b/dart');
    });

    test('prefers the earlier directory', () {
      final r = withPath('/a:/b', {'/a/dart', '/b/dart'});
      expect(r.resolve('dart', from: '/repo'), '/a/dart');
    });

    test('answers null when nothing has it', () {
      expect(
        withPath('/a:/b', {'/a/other'}).resolve('dart', from: '/repo'),
        isNull,
      );
    });

    test('skips empty PATH entries rather than searching the root', () {
      expect(withPath('/a::', {'dart'}).resolve('dart', from: '/repo'), isNull);
    });

    test('never appends a suffix', () {
      expect(
        withPath('/a', {'/a/dart.exe'}).resolve('dart', from: '/repo'),
        isNull,
      );
    });

    test('walks past a name-match that cannot be started', () {
      // The whole reason the predicate asks about runnability rather than
      // existence. `execvp` and `which` skip a file with no execute bit and
      // keep going; stopping there hands back a stale wrapper and never
      // reaches the toolchain further along, then fails as `Permission
      // denied` — exit 1, where §5.3 wanted 3 or a working program.
      final r = ExecutableResolver(
        environment: const {'PATH': '/stale:/real'},
        windows: false,
        isRunnable: (path) => path == '/real/dart',
      );
      expect(r.resolve('dart', from: '/repo'), '/real/dart');
    });
  });

  group('a name that is already a path', () {
    test('is read from the directory the body will run in', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        runnable: {'/repo/tool/gen', '/a/gen'},
      );
      expect(r.resolve('./tool/gen', from: '/repo'), '/repo/tool/gen');
    });

    test('and it comes back in the separators the machine writes', () {
      // The file speaks POSIX and the machine may not. Joined onto a native
      // directory without re-splitting, `./tool/gen` came back as
      // `C:\repo/tool/gen` — which Windows accepts, which `--dry-run` printed
      // back at a reader as the plan, and which matches no path this engine
      // builds any other way. `boundary.dart` draws that line for `in:` and
      // for `remove`; this was the one place that joined without it.
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.EXE'},
        runnable: {r'C:\repo\tool\gen'},
      );
      expect(r.resolve('./tool/gen', from: r'C:\repo'), r'C:\repo\tool\gen');
      expect(r.resolve('tool/gen', from: r'C:\repo'), r'C:\repo\tool\gen');
    });

    test('so the same name under two directories is two programs', () {
      // The cache is keyed on the pair for this reason. Keyed on the name
      // alone, the second task here answered with the first one's program —
      // silently, and with a plausible-looking run.
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        runnable: {'/repo/a/x', '/repo/b/x'},
      );
      expect(r.resolve('./x', from: '/repo/a'), '/repo/a/x');
      expect(r.resolve('./x', from: '/repo/b'), '/repo/b/x');
    });

    test('an absolute one is not joined to anything', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        runnable: {'/opt/gen'},
      );
      expect(r.resolve('/opt/gen', from: '/repo'), '/opt/gen');
    });

    test('missing is missing — PATH is not consulted as a fallback', () {
      // §5.4 rule 1: the author said where it is. Falling back to PATH would
      // run a different program than the one named, silently.
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        runnable: {'/a/gen'},
      );
      expect(r.resolve('./tool/gen', from: '/repo'), isNull);
    });

    test('a Windows backslash path counts as a path', () {
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin'},
        runnable: {r'C:\repo\tool\gen.bat'},
      );
      expect(
        r.resolve(r'tool\gen.bat', from: r'C:\repo'),
        r'C:\repo\tool\gen.bat',
      );
    });
  });

  group('Windows', () {
    ExecutableResolver windowsWith(
      Set<String> runnable, {
      Map<String, String>? environment,
    }) => resolver(
      windows: true,
      environment: environment ?? {'PATH': r'C:\bin;C:\sdk'},
      runnable: runnable,
    );

    test('a bare name matches a batch shim — the case that broke §5.2', () {
      final r = windowsWith({r'C:\sdk\dart.bat'});
      // `.BAT`, not `.bat`: the suffix comes from PATHEXT, not from disk.
      expect(r.resolve('dart', from: r'C:\repo'), r'C:\sdk\dart.BAT');
    });

    test('splits PATH on `;`, not `:` — a drive letter is not a separator', () {
      final r = windowsWith({r'C:\sdk\dart.exe'});
      expect(r.resolve('dart', from: r'C:\repo'), r'C:\sdk\dart.EXE');
    });

    test('honours the machine PATHEXT over the default', () {
      final r = windowsWith(
        {r'C:\bin\tool.ps1'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.PS1'},
      );
      expect(r.resolve('tool', from: r'C:\repo'), r'C:\bin\tool.PS1');
    });

    test('a PATHEXT that omits .BAT means .bat does not resolve', () {
      final r = windowsWith(
        {r'C:\bin\tool.bat'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.EXE'},
      );
      expect(r.resolve('tool', from: r'C:\repo'), isNull);
    });

    test('falls back to the documented default when PATHEXT is unset', () {
      final r = windowsWith(
        {r'C:\bin\tool.CMD'},
        environment: {'PATH': r'C:\bin'},
      );
      expect(r.resolve('tool', from: r'C:\repo'), r'C:\bin\tool.CMD');
    });

    test('an EMPTY PATHEXT also means the default, as it does to Windows', () {
      // `??` reads only null as absent. An empty string is not null, so
      // without this the suffix list collapses to the bare name and `dart` is
      // reported not installed with `dart.bat` sitting right there — exit 3,
      // "not installed", for a tool that is present. A CI image, or a
      // Process.start forwarding PATH but not PATHEXT, reproduces it.
      final r = windowsWith(
        {r'C:\bin\dart.bat'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': ''},
      );
      expect(r.resolve('dart', from: r'C:\repo'), r'C:\bin\dart.BAT');
    });

    test('tries PATHEXT in the order the machine gives', () {
      final r = windowsWith(
        {r'C:\bin\tool.CMD', r'C:\bin\tool.EXE'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.CMD;.EXE'},
      );
      expect(r.resolve('tool', from: r'C:\repo'), r'C:\bin\tool.CMD');
    });

    test("the answer carries PATHEXT's spelling, not the disk's", () {
      // Observable: --dry-run prints resolved command lines (§7), and this is
      // what appears there. Harmless — NTFS does not care — but a surprise
      // nobody wrote down is a bug report waiting to happen.
      final r = windowsWith(
        {r'C:\bin\tool.bat'},
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.BAT'},
      );
      expect(r.resolve('tool', from: r'C:\repo'), r'C:\bin\tool.BAT');
    });

    test('a name written with its extension resolves to itself', () {
      // Not `tool.exe.COM`. The reference this was ported from tries only the
      // PATHEXT suffixes and would miss `run: [tool.exe, ...]`.
      final r = windowsWith({r'C:\bin\tool.exe'});
      expect(r.resolve('tool.exe', from: r'C:\repo'), r'C:\bin\tool.exe');
    });

    test('a bare name does NOT match an extensionless file beside a shim', () {
      // The Flutter SDK ships `bin\flutter` (a POSIX sh script) beside
      // `bin\flutter.bat`; nodejs ships `npm` beside `npm.cmd`. Trying the
      // empty suffix first hands back the sh script, `needsShell` then says
      // false, and CreateProcess answers ERROR_BAD_EXE_FORMAT — on exactly the
      // two tools §5.4 names as the reason it exists. cmd.exe's rule is that a
      // name carrying no extension is tried only with PATHEXT entries.
      final r = windowsWith(
        {r'C:\src\flutter\bin\flutter', r'C:\src\flutter\bin\flutter.bat'},
        environment: {'PATH': r'C:\src\flutter\bin'},
      );
      expect(
        r.resolve('flutter', from: r'C:\repo'),
        r'C:\src\flutter\bin\flutter.BAT',
      );
    });

    test('reads `Path`, which is how Windows actually spells it', () {
      final r = windowsWith(
        {r'C:\bin\dart.bat'},
        environment: {'Path': r'C:\bin'},
      );
      expect(r.resolve('dart', from: '/repo'), r'C:\bin\dart.BAT');
    });
  });

  group('needsShell', () {
    ExecutableResolver on({required bool windows}) =>
        resolver(windows: windows, environment: {}, runnable: {});

    test('only .exe and .com start directly on Windows', () {
      final r = on(windows: true);
      expect(r.needsShell(r'C:\sdk\dart.exe'), isFalse);
      expect(r.needsShell(r'C:\sdk\dart.COM'), isFalse);
    });

    test('a batch shim does not', () {
      final r = on(windows: true);
      expect(r.needsShell(r'C:\sdk\dart.bat'), isTrue);
      expect(r.needsShell(r'C:\sdk\dart.CMD'), isTrue);
    });

    test('nor does anything else a stock PATHEXT admits', () {
      // A stock PATHEXT holds .VBS .VBE .JS .JSE .WSF .WSH .MSC, and this
      // suite itself pins that `.PS1` resolves. CreateProcess can no more
      // start a `.ps1` than a `.bat`: it needs `powershell -File`, as `.vbs`
      // needs `wscript`. Answering false for those was a closed set of shims
      // checked against an open PATHEXT.
      final r = on(windows: true);
      for (final path in [
        r'C:\bin\tool.ps1',
        r'C:\bin\tool.VBS',
        r'C:\bin\tool.js',
        r'C:\bin\tool.WSF',
        r'C:\bin\tool.msc',
      ]) {
        expect(r.needsShell(path), isTrue, reason: path);
      }
    });

    test('an extensionless program on Windows still goes through a shell', () {
      expect(on(windows: true).needsShell(r'C:\bin\tool'), isTrue);
    });

    test('nothing on POSIX does — there are no shims to accommodate', () {
      final r = on(windows: false);
      expect(r.needsShell('/usr/bin/dart'), isFalse);
      expect(r.needsShell('/usr/bin/dart.bat'), isFalse);
    });
  });

  group('the message a missing tool gets', () {
    test('names the tool and says where it looked', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a:/b:/c'},
        runnable: {},
      );
      final message = r.missingToolMessage('dart', from: '/repo');
      expect(message, contains('`dart`'));
      expect(message, contains('3 directories'));
    });

    test('on Windows it also says which suffixes were tried', () {
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin', 'PATHEXT': '.EXE;.BAT'},
        runnable: {},
      );
      expect(
        r.missingToolMessage('dart', from: '/repo'),
        contains('.EXE, .BAT'),
      );
    });

    test('and does not trail off when PATHEXT is empty', () {
      // It used to end mid-clause: "... on PATH, with any of ".
      final r = resolver(
        windows: true,
        environment: {'PATH': r'C:\bin', 'PATHEXT': ''},
        runnable: {},
      );
      final message = r.missingToolMessage('dart', from: '/repo');
      expect(message, isNot(endsWith('with any of ')));
      expect(message, contains('.BAT'));
    });

    test('a path that is not there says so, without mentioning PATH', () {
      final r = resolver(
        windows: false,
        environment: {'PATH': '/a'},
        runnable: {},
      );
      final message = r.missingToolMessage('./tool/gen', from: '/repo');
      expect(message, contains('no file at `./tool/gen` under `/repo`'));
      expect(message, isNot(contains('directories on PATH')));
    });
  });

  group('the host resolver, against the real machine', () {
    // The review found the previous version of this group vacuous: it stayed
    // green with `environment: const {}` or with `windows: true` on macOS,
    // because every case hit either the already-a-path branch or a null
    // answer. These walk a real PATH, so the wiring is actually exercised.
    late Directory dir;

    setUp(() => dir = tempRepo('resolve'));

    void write(String name, {required bool executable}) {
      final file = File(p.join(dir.path, name))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      if (executable) {
        Process.runSync('chmod', ['+x', file.path]);
      }
    }

    ExecutableResolver hostWithPath() => ExecutableResolver(
      environment: {...Platform.environment, 'PATH': dir.path},
      windows: Platform.isWindows,
      isRunnable: ExecutableResolver.forHost().isRunnable,
    );

    test('finds a real executable by bare name on a real PATH', () {
      write('xtask-probe', executable: true);
      expect(
        hostWithPath().resolve('xtask-probe', from: dir.path),
        p.join(dir.path, 'xtask-probe'),
      );
    });

    test('skips a real file that is not executable', () {
      // The failure this is about, on an actual filesystem rather than a fake
      // one: a stale non-executable wrapper is not a program.
      write('xtask-probe', executable: false);
      expect(hostWithPath().resolve('xtask-probe', from: dir.path), isNull);
    });

    test('a directory on PATH is not a program', () {
      Directory(p.join(dir.path, 'xtask-probe')).createSync();
      expect(hostWithPath().resolve('xtask-probe', from: dir.path), isNull);
    });

    test('finds the Dart running this test, given as a path', () {
      final dart = Platform.resolvedExecutable;
      expect(ExecutableResolver.forHost().resolve(dart, from: dir.path), dart);
    });

    test('does not find a name nothing answers to', () {
      expect(
        ExecutableResolver.forHost().resolve(
          'xtask-no-such-program-4f3a9',
          from: dir.path,
        ),
        isNull,
      );
    });
  }, skip: Platform.isWindows ? 'these pin POSIX execute bits' : null);
}
