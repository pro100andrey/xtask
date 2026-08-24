import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/dry_run.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/primitives.dart';
import 'package:xtask/src/resolve.dart';

void main() {
  late Directory root;
  late List<String> logged;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_dry_');
    logged = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

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
    return dryRun(
      file: file,
      root: root.path,
      plan: planRun(file, task),
      resolver: resolver ?? resolverFor(),
      log: logged.add,
      verbs: verbs,
      environment: environment,
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
        expect(output(), contains('in   ${p.join(root.path, 'packages/one')}'));
        expect(output(), contains('in   ${p.join(root.path, 'packages/two')}'));
      },
    );

    test('`argv-from` is on the command line, already expanded', () async {
      given(['lib/a.dart', 'lib/b.dart']);
      await dry(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n'
            '  a: {desc: x, run: [dart, format], argv-from: src}\n',
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
      expect(output(), contains('in   ${p.join(root.path, 'packages/lake')}'));
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
    test('the starter is not a stub — it refuses', () {
      // If the seam ever leaks, a dry run starts a real process. A stub
      // answering 0 would make that look like a plan that printed nothing.
      expect(
        () => const RefusingProcessStarter().start(
          '/bin/dart',
          const [],
          workingDirectory: '/',
          environment: const {},
          runInShell: false,
        ),
        throwsStateError,
      );
    });

    test('a `run:` body reaches it in neither of its two forms', () async {
      // Both branches of `_perform` are past the dry-run return; a leak in
      // either one would come back as the StateError above rather than as a
      // green run.
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
        'version: 1\ntasks:\n  a: {desc: x, each: absent, run: [dart]}\n',
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

    test('a body that is not a shim says nothing about a shell', () async {
      await dry('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      expect(output(), isNot(contains('cmd.exe')));
    });
  });
}
