import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/dry_run.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/primitives.dart';

import 'helpers.dart';

void main() {
  late Directory root;
  late List<String> logged;

  setUp(() {
    root = tempRepo('dry');
    logged = [];
  });

  void given(List<String> paths) {
    for (final path in paths) {
      File(p.join(root.path, p.joinAll(p.posix.split(path))))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
    }
  }

  /// A resolver that finds every bare name at `/bin/<name>`, so these cases
  /// are about the report rather than about §5.4.
  ExecutableResolver resolverFor() => ExecutableResolver(
    environment: const {'PATH': '/bin'},
    windows: false,
    isRunnable: (path) => !p.basename(path).startsWith('missing'),
  );

  /// The Windows shape §5.4 rule 3 is about: every tool is a batch shim.
  ExecutableResolver windowsShims() => ExecutableResolver(
    environment: const {'PATH': r'C:\bin', 'PATHEXT': '.BAT'},
    windows: true,
    isRunnable: (path) => path.toLowerCase().endsWith('.bat'),
  );

  Future<int> dry(
    String yaml,
    String task, {
    Map<String, Verb> verbs = const {},
    Map<String, String> environment = const {},
    ExecutableResolver? resolver,
  }) {
    final file = parseXtaskFile(yaml);
    // The same value a run is given, built the same way — which is the point
    // of the module: `--dry-run` prints what a run performs because it is
    // handed the thing that works it out, rather than making its own.
    return dryRun(
      plan: planRun(file, task),
      bodies: BodyResolver(
        root: root.path,
        resolver: resolver ?? resolverFor(),
        sets: file.sets,
        verbs: verbs,
        environment: environment,
      ),
      log: logged.add,
    );
  }

  String output() => logged.join('\n');

  group('it prints what will happen, not what is written', () {
    test('the program is the path §5.4 found, not the word in the file', () {
      // The distinction the whole slice rests on. `dart` is what somebody
      // typed; `/bin/dart` is what this machine will start, and only one of
      // the two can be checked against a machine that has not got it.
      expect(
        dry('version: 1\ntasks:\n  a: {desc: x, run: [dart, analyze]}\n', 'a'),
        completion(ExitCode.success),
      );
      expect(output(), contains('run  /bin/dart analyze'));
      expect(output(), isNot(contains('run  dart analyze')));
    });

    test(
      'a glob set is expanded, and each member gets its own block',
      () async {
        given(['packages/one/pubspec.yaml', 'packages/two/pubspec.yaml']);
        await dry(
          'version: 1\n'
              'sets:\n  pkgs:\n    include: [packages/*]\n'
              'tasks:\n'
              r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
              '\n',
          'a',
        );
        expect(output(), contains('a  [packages/one]'));
        expect(output(), contains('a  [packages/two]'));
        // Joined segment by segment, as the engine joins it. Written
        // `packages/one`, `p.join` leaves the inner `/` alone — so on Windows
        // this asserted `C:\…\packages/one`, a spelling of the path that the
        // engine no longer produces and never meant to.
        expect(
          output(),
          contains('in   ${p.join(root.path, 'packages', 'one')}'),
        );
        expect(
          output(),
          contains('in   ${p.join(root.path, 'packages', 'two')}'),
        );
      },
    );

    test('`all` is on the command line, already expanded', () async {
      given(['lib/a.dart', 'lib/b.dart']);
      await dry(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n'
            '  a: {desc: x, run: [dart, format, \$all], all: src}\n',
        'a',
      );
      expect(output(), contains('run  /bin/dart format lib/a.dart lib/b.dart'));
    });

    test('`in:` is absolute, resolved against the repository root', () async {
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, in: packages/lake, run: [dart, test]}\n',
        'a',
      );
      expect(
        output(),
        contains('in   ${p.join(root.path, 'packages', 'lake')}'),
      );
    });
  });

  group('the order comes first, because it is what survives a failure', () {
    test('every task the plan reaches, in the order it reaches it', () async {
      await dry(
        'version: 1\ntasks:\n'
            '  install: {desc: x, run: [dart, pub, get]}\n'
            '  build: {desc: x, needs: [install], run: [dart, compile]}\n'
            '  publish: {desc: x, needs: [build], then: [announce],'
            ' run: [dart, pub, publish]}\n'
            '  announce: {desc: x, run: [dart, run, announce.dart]}\n',
        'publish',
      );
      expect(logged.first, 'plan: install, build, publish, announce');
    });

    test('and it survives a task that cannot resolve', () async {
      // Printed before anything that can fail, deliberately: a plan whose
      // second task names a program this machine has not got is exactly when
      // somebody wants to see the order.
      final code = await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart]}\n'
            '  b: {desc: x, needs: [a], run: [missing-tool]}\n',
        'b',
      );
      expect(code, ExitCode.missingTool);
      expect(logged.first, 'plan: a, b');
    });
  });

  group('and nothing runs', () {
    test('a dry run has no process starter to leak through', () async {
      // This used to be guarded at run time, by a `ProcessStarter` whose only
      // job was to throw if anything ever reached it. There is nothing to
      // guard now: `dryRun` takes no starter, because a dry run resolves and
      // renders and never performs. The guarantee moved from a refusal into
      // the shape of the call, which is the better place for it — so what is
      // left to assert is that resolving several tasks answers cleanly.
      expect(
        await dry(
          'version: 1\ntasks:\n'
              '  a: {desc: x, run: [dart, test]}\n'
              '  b: {desc: x, needs: [a], in: sub, run: [dart, analyze]}\n',
          'b',
        ),
        ExitCode.success,
      );
    });

    test('and it stops at the first thing that will not resolve', () async {
      // The plan stops where a run would stop. A dry run that listed every
      // unresolvable task would be a different answer to the same question,
      // and it is one loop precisely so it cannot become one.
      final code = await dry(
        'version: 1\ntasks:\n'
            '  one: {desc: a, run: [missing-one]}\n'
            '  two: {desc: b, run: [missing-two]}\n'
            '  all: {desc: c, needs: [one, two]}\n',
        'all',
      );
      expect(code, ExitCode.missingTool);
      expect(output(), contains('missing-one'));
      expect(output(), isNot(contains('missing-two')));
    });

    test('and `remove` says what it would delete, not just its pattern', () {
      // The engine ships one verb and it deletes recursively. Every other body
      // is fully worked out by the time it is described — a `run:` prints the
      // argv the child gets — and this block used to print the PATTERN, so the
      // one operation a reader most needs to check was the one they could not.
      given(['build/out/a.o', 'keep.txt']);
      expect(
        dry(
          'version: 1\n'
              "sets:\n  outs: ['build', 'coverage']\n"
              'tasks:\n'
              r'  clean: {desc: x, do: remove, all: outs, args: [$all]}'
              '\n',
          'clean',
          verbs: builtInVerbs(root: root.path),
        ),
        completion(ExitCode.success),
      );
      expect(output(), contains('do   remove build coverage'));
      expect(output(), contains('del  build'));
      expect(
        output(),
        isNot(contains('del  coverage')),
        reason: 'coverage is not there, and a missing path is not deleted',
      );
      expect(
        File(p.join(root.path, 'build', 'out', 'a.o')).existsSync(),
        isTrue,
        reason: 'a dry run deleted something',
      );
    });

    test('and says so out loud when there is nothing there', () {
      // Silence reads as "nothing was worked out". The answer — there is
      // nothing there, which is not an error — is the one a person running
      // `clean` a second time needs.
      expect(
        dry(
          'version: 1\n'
              "sets:\n  outs: ['build']\n"
              'tasks:\n'
              r'  clean: {desc: x, do: remove, all: outs, args: [$all]}'
              '\n',
          'clean',
          verbs: builtInVerbs(root: root.path),
        ),
        completion(ExitCode.success),
      );
      expect(output(), contains('nothing of these is on disk'));
    });

    test('a verb is looked up and NOT called', () async {
      var called = false;
      final code = await dry(
        'version: 1\ntasks:\n  a: {desc: x, do: publish}\n',
        'a',
        verbs: {
          'publish': (context) async {
            called = true;
            return ExitCode.success;
          },
        },
      );
      expect(code, ExitCode.success);
      expect(called, isFalse);
      expect(output(), contains('do   publish'));
    });

    test('so `remove` does not remove anything', () async {
      // The primitive of §6 deletes recursively and a missing path is not an
      // error, which is the worst combination to be wrong about here.
      given(['build/out.js']);
      final code = await dry(
        'version: 1\ntasks:\n  clean: {desc: x, do: remove, args: [build]}\n',
        'clean',
        verbs: builtInVerbs(root: root.path),
      );
      expect(code, ExitCode.success);
      expect(Directory(p.join(root.path, 'build')).existsSync(), isTrue);
      expect(output(), contains('do   remove build'));
    });
  });

  group("a failure is the run's failure, with the run's exit code", () {
    test('a program nothing on PATH answers to is still 3', () async {
      final code = await dry(
        'version: 1\ntasks:\n  a: {desc: x, run: [missing-tool, --help]}\n',
        'a',
      );
      expect(code, ExitCode.missingTool);
      expect(output(), contains('missing-tool'));
    });

    test('a verb the project did not register is still 2', () async {
      final code = await dry(
        'version: 1\ntasks:\n  a: {desc: x, do: nobody-registered-this}\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
      expect(output(), contains('nobody-registered-this'));
    });

    test('a set that does not exist is still 2', () async {
      final code = await dry(
        'version: 1\ntasks:\n'
            r'  a: {desc: x, each: absent, in: $each, run: [dart]}'
            '\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
    });

    test('an unset `env-required` is still 1, before anything else', () async {
      // Debatable and decided: a dry run reports it. §7.1 gives the key its
      // value by turning "something failed inside" into a named message, and
      // skipping the check here would need a second code path — the very
      // thing this slice exists not to have.
      final code = await dry(
        'version: 1\ntasks:\n'
            '  web: {desc: x, env-required: [CHROMEDRIVER],'
            ' run: [dart, test]}\n',
        'web',
      );
      expect(code, ExitCode.taskFailed);
      expect(output(), contains('CHROMEDRIVER'));
    });

    test('and inside a `then:` it is still 4', () async {
      // §5.3's third outcome. The code is about WHERE the failure is, not
      // what it was, so a dry run answers it the same way a run would.
      final code = await dry(
        'version: 1\ntasks:\n'
            '  publish: {desc: x, then: [announce],'
            ' run: [dart, pub, publish]}\n'
            '  announce: {desc: x, run: [missing-tool]}\n',
        'publish',
      );
      expect(code, ExitCode.continuationFailed);
    });
  });

  group('the report can be checked against what somebody meant', () {
    test('an argument with a space is one argument, visibly', () async {
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, test],'
            ' args: ["--name", "two words"]}\n',
        'a',
      );
      expect(output(), contains("run  /bin/dart test --name 'two words'"));
    });

    test('and an empty argument does not disappear', () async {
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, test], args: ["--name", ""]}\n',
        'a',
      );
      expect(output(), contains("run  /bin/dart test --name ''"));
    });

    test("the env printed is the task's own, not the machine's", () async {
      // The merged map is this machine's environment with one entry changed.
      // Printing it would bury the one line that is part of the plan under a
      // hundred that are part of the terminal.
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, test], env: {COVERAGE: "1"}}\n',
        'a',
        environment: const {'HOME': '/Users/somebody', 'PATH': '/bin'},
      );
      expect(output(), contains('env  COVERAGE=1'));
      expect(output(), isNot(contains('HOME')));
    });

    test(r'with $each already standing for the member', () async {
      // Every other line of this block was substituted, so it promised
      // `FLAVOR=$each` while the run exported `FLAVOR=dev`.
      await dry(
        'version: 1\n'
            'sets:\n  f:\n    values: [dev, prod]\n'
            'tasks:\n'
            r'  a: {desc: x, each: f, env: {FLAVOR: $each}, run: [d, $each]}'
            '\n',
        'a',
      );
      expect(output(), contains('env  FLAVOR=dev'));
      expect(output(), contains('env  FLAVOR=prod'));
      expect(output(), isNot(contains(r'FLAVOR=$each')));
    });

    test('and no task is wrapped in a section', () async {
      // §7.1's markers exist to fold a task's OUTPUT, and a dry run produces
      // none: its own report is the plan, and a header above each block would
      // say the name twice. Asserted against the plain marker rather than the
      // GitHub one, because plain is what a dry run uses on either host —
      // checking only for `::group::` would pass with sections turned on.
      await dry(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n',
        'a',
        environment: const {'GITHUB_ACTIONS': 'true'},
      );
      expect(output(), isNot(contains('──')));
      expect(output(), isNot(contains('::group::')));
      expect(logged.first, 'plan: a');
    });

    test('and nothing is timed, because nothing took any time', () async {
      // The run prints what each task took. A dry run performs nothing, so a
      // duration there would be a number measuring the printing of a plan.
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, test]}\n'
            '  b: {desc: x, needs: [a], run: [dart, analyze]}\n',
        'b',
      );
      expect(output(), isNot(contains('total')));
      expect(output(), isNot(matches(RegExp(r'\d\.\ds'))));
    });

    test('a composite says it has nothing of its own to run', () async {
      await dry(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, test]}\n'
            '  check: {desc: x, needs: [a]}\n',
        'check',
      );
      expect(output(), contains('check: nothing of its own to run'));
    });

    test('a limit on a task is part of what will happen', () async {
      // A dry run that hid it would promise a command with no deadline and
      // then run one with a deadline.
      await dry(
        'version: 1\ntasks:\n  a: {desc: x, timeout: 90, run: [dart, test]}\n',
        'a',
      );
      expect(output(), contains('for  at most 90s'));
    });

    test('and a task without one says nothing about time', () async {
      await dry('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      expect(output(), isNot(contains('at most')));
    });

    test('and a Windows shim says the shell is coming', () async {
      // The one thing §5.4 rule 3 makes visible, and the reason an argument
      // can be refused on one platform and not another.
      await dry(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, analyze]}\n',
        'a',
        resolver: windowsShims(),
      );
      expect(output(), contains(r'run  C:\bin\dart.BAT analyze'));
      expect(output(), contains('via  cmd.exe'));
    });

    group('a set another task produces is not called wrong here either', () {
      test('it says the timing rather than answering 2', () async {
        given(['build/keep/x']);
        final code = await dry(
          'version: 1\n'
              "sets:\n  made:\n    include: ['build/*.txt']\n"
              '    produced: true\n'
              'tasks:\n'
              '  make: {desc: p, run: [touch, build/a.txt]}\n'
              r'  use: {desc: c, needs: [make], all: made, run: [echo, $all]}'
              '\n',
          'use',
        );
        expect(code, ExitCode.success);
        expect(output(), contains('cannot be resolved yet'));
        // The original reason is printed under it, so nothing is hidden if the
        // cause turns out to be something other than the timing.
        expect(output(), contains('is empty'));
      });

      test('and a failure that is not the timing still stops the print', () {
        // Guessing from the exit code and the task's set names called a
        // boundary violation and an unknown verb premature too, and answered 0.
        const escaping =
            '  use: {desc: c, needs: [make], all: made, in: "../..", '
            r'run: [echo, $all]}';
        const unknownVerb = '  use: {desc: c, needs: [make], do: no-such-verb}';
        for (final task in [escaping, unknownVerb]) {
          expect(
            () async {
              given(['build/keep/x']);
              final code = await dry(
                'version: 1\n'
                    "sets:\n  made:\n    include: ['build/*.txt']\n"
                    '    produced: true\n'
                    'tasks:\n'
                    '  make: {desc: p, run: [touch, build/a.txt]}\n'
                    '$task\n',
                'use',
              );
              expect(code, ExitCode.invalidFile, reason: task);
            },
            returnsNormally,
          );
        }
      });

      test('and a task nothing runs before still stops the print', () async {
        final code = await dry(
          'version: 1\n'
              "sets:\n  src:\n    include: ['nothing-matches/*']\n"
              'tasks:\n'
              r'  a: {desc: x, all: src, run: [echo, $all]}'
              '\n',
          'a',
        );
        expect(code, ExitCode.invalidFile);
      });
    });

    test('a body that is not a shim says nothing about a shell', () async {
      await dry('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      expect(output(), isNot(contains('cmd.exe')));
    });
  });
}
