import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/resolution.dart';
import 'package:xtask/src/resolve.dart';

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

    test('and NONE for a composite, which is not a special case', () {
      // An empty list says "nothing of its own" without the caller needing to
      // ask a second question about the body.
      expect(
        resolve('version: 1\ntasks:\n  c: {desc: x, collects: g}\n', 'c'),
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
    test('lands after `args:` and the expanded `argv-from`', () {
      File(p.join(root.path, 'a.dart')).writeAsStringSync('');
      final body =
          resolve(
                'version: 1\n'
                    'sets:\n  src:\n    include: ["*.dart"]\n'
                    'tasks:\n'
                    '  a: {desc: x, run: [dart, format], args: [--fix],'
                    ' argv-from: src}\n',
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
