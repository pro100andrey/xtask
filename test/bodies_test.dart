import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/parse.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xtask_resolution_'));
  tearDown(() => root.deleteSync(recursive: true));

  ExecutableResolver posix() => ExecutableResolver(
    environment: const {'PATH': '/bin'},
    windows: false,
    isRunnable: (path) => !p.basename(path).startsWith('missing'),
  );

  ExecutableResolver windowsShims() => ExecutableResolver(
    environment: const {'PATH': r'C:\bin', 'PATHEXT': '.BAT'},
    windows: true,
    isRunnable: (path) => path.toLowerCase().endsWith('.bat'),
  );

  /// Everything one task comes to, resolved.
  ///
  /// A whole `Executor`, a fake process starter and a plan used to stand
  /// between a test and this answer — for facts that are about neither.
  List<Resolved> resolve(
    String yaml,
    String task, {
    ExecutableResolver? resolver,
    Map<String, Verb> verbs = const {},
    Map<String, String> environment = const {},
    List<String> passed = const [],
  }) {
    final file = parseXtaskFile(yaml);
    return BodyResolver(
      root: root.path,
      resolver: resolver ?? posix(),
      sets: file.sets,
      verbs: verbs,
      environment: environment,
      passedThrough: (task: task, arguments: passed),
    ).resolveTask(file.tasks[task]!);
  }

  group('a task comes to a list of bodies', () {
    test('one, for an ordinary `run:`', () {
      final bodies = resolve(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, analyze]}\n',
        'a',
      );
      final body = bodies.single as ResolvedProcess;
      expect(body.executable, '/bin/dart');
      expect(body.arguments, ['analyze']);
      expect(body.workingDirectory, root.path);
      expect(body.member, isNull);
    });

    test("one per member under `each:`, in the set's order", () {
      final bodies = resolve(
        'version: 1\n'
            'sets:\n  pkgs: [one, two]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      expect(bodies.map((b) => b.member), ['one', 'two']);
      expect(
        bodies.map((b) => b.workingDirectory),
        [p.join(root.path, 'one'), p.join(root.path, 'two')],
      );
    });

    test('and NONE for a task with no body, not a special case', () {
      // An empty list says "nothing of its own" without the caller needing to
      // ask a second question about the body.
      expect(
        resolve(
          'version: 1\ntasks:\n'
              '  c: {desc: x, needs: [d]}\n'
              '  d: {desc: y, run: [dart]}\n',
          'c',
        ),
        isEmpty,
      );
    });

    test('a verb is found and not called', () {
      var called = false;
      final body =
          resolve(
                'version: 1\ntasks:\n  a: {desc: x, do: regen}\n',
                'a',
                verbs: {
                  'regen': (_) async {
                    called = true;
                    return 0;
                  },
                },
              ).single
              as ResolvedVerb;
      expect(body.verb, 'regen');
      expect(called, isFalse, reason: 'resolving is not running');
    });

    test('and a verb is given the three sources in one list, in order', () {
      // Asked of the document by a reviewer and answerable only here: `args:`,
      // then the expanded `all:`, then whatever the command line passed
      // after `--`. A verb is reached by `--` exactly as a process is, and
      // nothing said so — `VerbContext.args` was documented as the first two.
      for (final member in ['pkg/a', 'pkg/b']) {
        Directory(p.join(root.path, member)).createSync(recursive: true);
      }
      final body =
          resolve(
                'version: 1\n'
                    'sets:\n  packages:\n    include: [pkg/*]\n'
                    'tasks:\n'
                    r'  a: {desc: x, do: regen, args: [--first, $all], '
                    'all: packages}\n',
                'a',
                verbs: {'regen': (_) async => 0},
                passed: ['--last'],
              ).single
              as ResolvedVerb;
      expect(body.arguments, ['--first', 'pkg/a', 'pkg/b', '--last']);
    });
  });

  group('everything that makes a task unrunnable is found here', () {
    Matcher refused(int code, Object message) => throwsA(
      isA<RunFailure>()
          .having((f) => f.code, 'code', code)
          .having((f) => f.message, 'message', message),
    );

    test('an unset `env-required`, before anything else', () {
      expect(
        () => resolve(
          'version: 1\ntasks:\n'
              '  web: {desc: x, env-required: [CHROMEDRIVER], run: [dart]}\n',
          'web',
        ),
        refused(ExitCode.taskFailed, contains('CHROMEDRIVER')),
      );
    });

    test('a program nothing on PATH answers to', () {
      expect(
        () => resolve(
          'version: 1\ntasks:\n  a: {desc: x, run: [missing-tool]}\n',
          'a',
        ),
        refused(ExitCode.missingTool, contains('missing-tool')),
      );
    });

    test('a verb this project did not register', () {
      expect(
        () => resolve('version: 1\ntasks:\n  a: {desc: x, do: ghost}\n', 'a'),
        refused(ExitCode.invalidFile, contains('ghost')),
      );
    });

    test('a set that does not exist', () {
      expect(
        () => resolve(
          'version: 1\ntasks:\n  a: {desc: x, each: absent, run: [dart]}\n',
          'a',
        ),
        refused(ExitCode.invalidFile, contains('absent')),
      );
    });

    test('a set that expands to nothing', () {
      expect(
        () => resolve(
          'version: 1\n'
              'sets:\n  pkgs:\n    include: [packages/*]\n'
              'tasks:\n  a: {desc: x, each: pkgs, run: [dart]}\n',
          'a',
        ),
        refused(ExitCode.invalidFile, contains('cannot run')),
      );
    });

    test('`in:` that leaves the repository', () {
      // Nothing checked this until now: `in: ../..` started a body two levels
      // above the root and the run answered 0.
      for (final where in ['../..', '/etc']) {
        expect(
          () => resolve(
            'version: 1\ntasks:\n'
                '  a: {desc: x, in: "$where", run: [dart]}\n',
            'a',
          ),
          refused(ExitCode.invalidFile, contains('reaches outside')),
          reason: where,
        );
      }
    });

    test(r'`in: $each` with no `each:`', () {
      expect(
        () => resolve(
          'version: 1\ntasks:\n'
              r'  a: {desc: x, in: $each, run: [dart]}'
              '\n',
          'a',
        ),
        refused(ExitCode.invalidFile, contains(r'$each')),
      );
    });
  });

  group('§5.4 rule 3, without a run to reach it through', () {
    // Seven whole executions used to stand between this suite and a check on
    // a seven-element set.
    test('every character cmd.exe acts on is refused', () {
      for (final bad in ['a&b', 'a|b', 'a<b', 'a>b', 'a^b', 'a(b', 'a)b']) {
        expect(
          () => resolve(
            'version: 1\ntasks:\n  a: {desc: x, run: [dart, "$bad"]}\n',
            'a',
            resolver: windowsShims(),
          ),
          throwsA(isA<RunFailure>()),
          reason: bad,
        );
      }
    });

    test('and an ordinary argument to a shim goes through the shell', () {
      final body =
          resolve(
                'version: 1\ntasks:\n  a: {desc: x, run: [dart, analyze]}\n',
                'a',
                resolver: windowsShims(),
              ).single
              as ResolvedProcess;
      expect(body.runInShell, isTrue);
      expect(body.executable, r'C:\bin\dart.BAT');
    });

    test('while the same task on POSIX starts no shell', () {
      final body =
          resolve(
                'version: 1\ntasks:\n  a: {desc: x, run: [dart, "a&b"]}\n',
                'a',
              ).single
              as ResolvedProcess;
      expect(body.runInShell, isFalse);
      expect(body.arguments, ['a&b']);
    });
  });

  group('what a command line adds', () {
    test('lands after `args:` and the expanded `all:`', () {
      File(p.join(root.path, 'a.dart')).writeAsStringSync('');
      final body =
          resolve(
                'version: 1\n'
                    'sets:\n  src:\n    include: ["*.dart"]\n'
                    'tasks:\n'
                    r'  a: {desc: x, run: [dart, format], args: [--fix, $all],'
                    ' all: src}\n',
                'a',
                passed: ['--line-length', '100'],
              ).single
              as ResolvedProcess;
      expect(body.arguments, [
        'format',
        '--fix',
        'a.dart',
        '--line-length',
        '100',
      ]);
    });

    test('and reaches only the task that was named', () {
      final file = parseXtaskFile(
        'version: 1\ntasks:\n'
        '  install: {desc: a, run: [dart, pub, get]}\n'
        '  test: {desc: b, needs: [install], run: [dart, test]}\n',
      );
      final bodies = BodyResolver(
        root: root.path,
        resolver: posix(),
        sets: file.sets,
        passedThrough: (task: 'test', arguments: ['-n', 'x']),
      );
      expect(
        (bodies.resolveTask(file.tasks['install']!).single as ResolvedProcess)
            .arguments,
        ['pub', 'get'],
      );
      expect(
        (bodies.resolveTask(file.tasks['test']!).single as ResolvedProcess)
            .arguments,
        ['test', '-n', 'x'],
      );
    });
  });

  group('`all:` puts its members where the marker stands', () {
    test('in the middle of argv, which `argv-from:` could not do', () {
      // The whole reason the key changed: a set could only ever be appended,
      // so `cp <files> dest/` was unwritable.
      for (final name in ['a.dart', 'b.dart']) {
        File(p.join(root.path, name)).writeAsStringSync('');
      }
      final body = resolve(
        'version: 1\n'
            'sets:\n  src:\n    include: ["*.dart"]\n'
            'tasks:\n'
            r'  a: {desc: x, all: src, run: [cp, $all, dest/]}'
            '\n',
        'a',
      ).single;
      expect(
        (body as ResolvedProcess).arguments,
        ['a.dart', 'b.dart', 'dest/'],
      );
    });

    test('and in `args:`, which is where a verb reads them', () {
      File(p.join(root.path, 'a.dart')).writeAsStringSync('');
      final body = resolve(
        'version: 1\n'
            'sets:\n  src:\n    include: ["*.dart"]\n'
            'tasks:\n'
            r'  a: {desc: x, do: v, all: src, args: [--in, $all]}'
            '\n',
        'a',
        verbs: {'v': (_) async => 0},
      ).single;
      expect(body.arguments, ['--in', 'a.dart']);
    });
  });

  group('the environment a body sees', () {
    test("is the ambient one with the task's `env:` on top", () {
      final body = resolve(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart], env: {COVERAGE: "1", HOME: "/tmp"}}\n',
        'a',
        environment: const {'HOME': '/Users/somebody', 'PATH': '/bin'},
      ).single;
      expect(body.environment['COVERAGE'], '1');
      expect(body.environment['HOME'], '/tmp', reason: 'the task wins');
      expect(body.environment['PATH'], '/bin');
    });
  });
}
