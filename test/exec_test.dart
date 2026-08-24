import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/exec.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/reporting.dart';
import 'package:xtask/src/resolve.dart';

/// A clock that advances by [step] every time it is read.
///
/// Every task reads it twice — once before and once after — so each takes
/// exactly [step], and a summary a test can assert to the tenth of a second.
DateTime Function() ticking(Duration step) {
  var at = DateTime.utc(2026);
  return () {
    final was = at;
    at = at.add(step);
    return was;
  };
}

/// One process the executor asked for.
final class Started {
  Started(
    this.executable,
    this.arguments,
    this.workingDirectory,
    this.environment,
    this.runInShell,
  );

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final bool runInShell;
}

/// A starter that records instead of spawning.
///
/// Everything worth asserting here is WHICH processes would start and with
/// what — the order, the directory, the environment, what happens after a
/// failure, which member of an `each:` was reached. None of that needs a real
/// process, and a suite that started one would depend on a toolchain to say
/// anything at all.
final class FakeStarter implements ProcessStarter {
  FakeStarter([this.codes = const {}]);

  /// Exit code per executable name; anything unlisted succeeds.
  final Map<String, int> codes;
  final started = <Started>[];

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) async {
    started.add(
      Started(executable, arguments, workingDirectory, environment, runInShell),
    );
    return codes[p.basename(executable)] ?? ExitCode.success;
  }
}

void main() {
  late Directory root;
  late FakeStarter starter;
  late List<String> logged;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_exec_');
    starter = FakeStarter();
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

  /// A resolver that finds every bare name at `/bin/<name>`, so the cases
  /// below are about execution rather than about §5.4.
  ExecutableResolver resolverFor({Set<String> shims = const {}}) =>
      ExecutableResolver(
        environment: const {'PATH': '/bin'},
        windows: shims.isNotEmpty,
        isRunnable: (path) => !p.basename(path).startsWith('missing'),
      );

  Future<int> runFile(
    String yaml,
    String task, {
    bool keepGoing = false,
    List<String> passed = const [],
    Map<String, Verb> verbs = const {},
    Map<String, String> environment = const {},
    ExecutableResolver? resolver,
    LogMarkers markers = const PlainMarkers(),
    Duration step = const Duration(milliseconds: 100),
  }) {
    final file = parseXtaskFile(yaml);
    return Executor(
      file: file,
      root: root.path,
      resolver: resolver ?? resolverFor(),
      starter: starter,
      log: logged.add,
      verbs: verbs,
      environment: environment,
      markers: markers,
      now: ticking(step),
      passedThrough: (task: task, arguments: passed),
      keepGoing: keepGoing,
    ).run(planRun(file, task));
  }

  group('a `run:` body becomes one process, as argv', () {
    test('argv is not a string anybody splits', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, analyze, --fatal-infos]}\n',
        'a',
      );
      expect(code, ExitCode.success);
      expect(starter.started.single.arguments, ['analyze', '--fatal-infos']);
    });

    test('`args:` are appended to the body', () async {
      await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, format],'
            ' args: [--set-exit-if-changed]}\n',
        'a',
      );
      expect(starter.started.single.arguments, [
        'format',
        '--set-exit-if-changed',
      ]);
    });

    test('`argv-from` appends the resolved members', () async {
      given(['a.lake', 'b.lake']);
      await runFile(
        'version: 1\n'
            "sets:\n  srcs: {include: ['**/*.lake']}\n"
            'tasks:\n'
            '  a: {desc: x, run: [fmt], argv-from: srcs}\n',
        'a',
      );
      expect(starter.started.single.arguments, ['a.lake', 'b.lake']);
    });

    test(
      'an unresolvable executable is a MISSING TOOL, not a failure',
      () async {
        // §5.3 gives it its own code because "Dart is not installed" and "the
        // code is broken" are repaired by different people.
        final code = await runFile(
          'version: 1\ntasks:\n  a: {desc: x, run: [missing-tool]}\n',
          'a',
        );
        expect(code, ExitCode.missingTool);
        expect(starter.started, isEmpty, reason: 'asked before it is started');
        expect(logged.join('\n'), contains('not installed'));
      },
    );
  });

  group('the run stops at the first failure', () {
    test('and the tasks after it do not run', () async {
      starter = FakeStarter({'boom': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, needs: [b], run: [after]}\n'
            '  b: {desc: y, run: [boom]}\n',
        'a',
      );
      expect(code, ExitCode.taskFailed);
      expect(starter.started.map((s) => s.executable), ['/bin/boom']);
    });

    test('the report names the task and the code', () async {
      starter = FakeStarter({'boom': 7});
      await runFile('version: 1\ntasks:\n  a: {desc: x, run: [boom]}\n', 'a');
      expect(logged.join('\n'), contains('task `a` failed with exit code 7'));
    });
  });

  group('`each:` runs the body once per member, sequentially', () {
    test('in the order the set gives', () async {
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs: [one, two, three]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      expect(
        starter.started.map((s) => p.basename(s.workingDirectory)),
        ['one', 'two', 'three'],
      );
    });

    test(
      'and the member is named as it goes, not only when it fails',
      () async {
        // Six identical lines from one `each:` over six packages is a log that
        // makes somebody run all six again to find out which one is which.
        await runFile(
          'version: 1\n'
              'sets:\n  pkgs: [one, two]\n'
              'tasks:\n'
              r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
              '\n',
          'a',
        );
        expect(logged.join('\n'), contains('a [one]: '));
        expect(logged.join('\n'), contains('a [two]: '));
      },
    );

    test('a failure stops at that member, and the member is NAMED', () async {
      // §5.2 asks for the member by name. "The tests failed" over six
      // packages is a report that makes somebody run all six again by hand.
      starter = FakeStarter({'dart': 1});
      final code = await runFile(
        'version: 1\n'
            'sets:\n  pkgs: [one, two, three]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      expect(code, ExitCode.taskFailed);
      expect(starter.started, hasLength(1), reason: 'stopped at the first');
      expect(logged.join('\n'), contains('failed at `one`'));
    });
  });

  group('a set that expands to nothing stops the task, not the process', () {
    // §4.2 makes it an error and §8 catches it without running anything — but
    // somebody who did not validate first reaches it here, and it used to
    // escape `run` altogether: past the exit code and past the section
    // markers, leaving a group open around a task that had already stopped.
    test('and answers 2, because the file is what is wrong', () async {
      final code = await runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [packages/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
      expect(logged.join('\n'), contains('task `a` cannot run'));
      expect(starter.started, isEmpty);
    });

    test('the same for `argv-from`, which fails one step later', () async {
      final code = await runFile(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n  a: {desc: x, argv-from: src, run: [dart, format]}\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
      expect(logged.join('\n'), contains('task `a` cannot run'));
    });
  });

  group('what each task took, after everything, outside every section', () {
    // §7.1 has a CI job run one invocation, so the job's own duration is the
    // duration of the whole gate and "which task took four minutes" has no
    // answer anywhere else.
    test('one line per task that ran, in the order it ran', () async {
      await runFile(
        'version: 1\ntasks:\n'
            '  install: {desc: x, run: [dart, pub, get]}\n'
            '  build: {desc: x, needs: [install], run: [dart, compile]}\n',
        'build',
      );
      expect(logged, containsAllInOrder(['install  0.1s', 'build    0.1s']));
    });

    test('and a total, once there is more than one of them', () async {
      await runFile(
        'version: 1\ntasks:\n'
            '  install: {desc: x, run: [dart, pub, get]}\n'
            '  build: {desc: x, needs: [install], run: [dart, compile]}\n',
        'build',
      );
      expect(logged.last, 'total    0.2s');
    });

    test(
      'but no total for a single task, which would just repeat it',
      () async {
        await runFile('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
        expect(logged.last, 'a  0.1s');
        expect(logged.join('\n'), isNot(contains('total')));
      },
    );

    test('the task that FAILED is timed too', () async {
      // Where a run spent itself before it broke is most of what somebody
      // wants from a red job, and it is the one the naive version drops.
      starter = FakeStarter({'dart': 1});
      await runFile(
        'version: 1\ntasks:\n  boom: {desc: x, run: [dart, test]}\n',
        'boom',
      );
      expect(logged.last, 'boom  0.1s');
    });

    test('a long one is minutes and seconds, not 154.0s', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n',
        'a',
        step: const Duration(seconds: 94),
      );
      expect(logged.last, 'a  1m 34s');
    });

    test('and it lands AFTER the last section closes', () async {
      // A line inside a `::group::` is folded away with it, and the moment
      // somebody wants a duration is exactly the moment they have expanded
      // nothing.
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n',
        'a',
        markers: const GitHubMarkers(),
      );
      expect(
        logged.lastIndexOf('::endgroup::'),
        lessThan(logged.indexWhere((l) => l.startsWith('a  '))),
      );
    });
  });

  group('the line that says it broke is the line that reproduces it', () {
    test('the command and the directory, not just the exit code', () async {
      starter = FakeStarter({'dart': 1});
      await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, in: sub, run: [dart, test],'
            ' args: ["--name", "two words"]}\n',
        'a',
      );
      final failure = logged.firstWhere((l) => l.contains('failed'));
      expect(failure, contains("run  /bin/dart test --name 'two words'"));
      expect(failure, contains('in   ${p.join(root.path, 'sub')}'));
    });

    test("and under `each:` it is that member's directory", () async {
      starter = FakeStarter({'dart': 1});
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs: [one, two]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      final failure = logged.firstWhere((l) => l.contains('failed'));
      expect(failure, contains('failed at `one`'));
      expect(failure, contains('in   ${p.join(root.path, 'one')}'));
    });

    test('a verb reports the name written in the file', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: regen, args: [--all]}\n',
        'a',
        verbs: {'regen': (context) async => 3},
      );
      final failure = logged.firstWhere((l) => l.contains('failed'));
      expect(failure, contains('do   regen --all'));
    });

    test('and it is rendered by the same code `--dry-run` prints', () async {
      // Two renderings of one value would drift, and the drift shows up as a
      // dry run promising a command a failure then reports differently.
      starter = FakeStarter({'dart': 1});
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n',
        'a',
      );
      final failure = logged.firstWhere((l) => l.contains('failed'));
      expect(failure, endsWith('  in   ${root.path}'));
      // And the task's name is not repeated under itself: `describe`'s first
      // line is a header for a plan listing, and the failure already said
      // which task this is.
      expect(failure.split('\n')[1], startsWith('  run  '));
    });
  });

  group('arguments from the command line land last', () {
    test('after `args:` and after the expanded `argv-from`', () async {
      // Where a command line belongs: able to add to what the file already
      // said, rather than buried in front of it.
      given(['lib/a.dart']);
      await runFile(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n'
            '  a: {desc: x, run: [dart, format], args: [--fix],'
            ' argv-from: src}\n',
        'a',
        passed: ['--line-length', '100'],
      );
      expect(starter.started.single.arguments, [
        'format',
        '--fix',
        'lib/a.dart',
        '--line-length',
        '100',
      ]);
    });

    test('every member of an `each:` gets them', () async {
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs: [one, two]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
        passed: ['-n', 'x'],
      );
      expect(starter.started.map((s) => s.arguments), [
        ['test', '-n', 'x'],
        ['test', '-n', 'x'],
      ]);
    });

    test('and a verb is handed them like any other argument', () async {
      late List<String> seen;
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: regen, args: [--all]}\n',
        'a',
        passed: ['--only', 'x'],
        verbs: {
          'regen': (context) async {
            seen = context.args;
            return ExitCode.success;
          },
        },
      );
      expect(seen, ['--all', '--only', 'x']);
    });
  });

  group('--keep-going reports every failure, not the first', () {
    // §8's own argument, applied where it also holds: "a gate that reports one
    // problem per run makes somebody fix, rerun, fix, rerun" is word for word
    // `xtask check` — formatting red, fix, analyser red, fix, tests red.
    const three =
        'version: 1\ntasks:\n'
        '  fmt: {desc: a, run: [dart, format]}\n'
        '  lint: {desc: b, needs: [fmt], run: [ruff]}\n'
        '  unit: {desc: c, needs: [fmt], run: [pytest]}\n'
        '  all: {desc: d, needs: [lint, unit]}\n';

    test(
      'without it, the run stops at the first — still the default',
      () async {
        starter = FakeStarter({'ruff': 1, 'pytest': 1});
        expect(await runFile(three, 'all'), ExitCode.taskFailed);
        expect(
          starter.started.map((s) => p.basename(s.executable)),
          ['dart', 'ruff'],
          reason: 'pytest must not have been reached',
        );
      },
    );

    test('with it, the independent ones still run', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      expect(
        await runFile(three, 'all', keepGoing: true),
        ExitCode.taskFailed,
      );
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['dart', 'ruff', 'pytest'],
      );
    });

    test('and every one of them is reported where it happened', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged.join('\n'), contains('task `lint` failed'));
      expect(logged.join('\n'), contains('task `unit` failed'));
    });

    test('a task whose requirement failed does NOT run', () async {
      // Its own failure would be a consequence of the first one, and a mode
      // that reported both would bury the cause in its own noise.
      starter = FakeStarter({'dart': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(starter.started, hasLength(1), reason: 'only `fmt` was reached');
    });

    test('and it is NAMED, because a task that silently did not happen '
        'reads exactly like one that passed', () async {
      starter = FakeStarter({'dart': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged.join('\n'), contains('skipped  lint (needs fmt)'));
      expect(logged.join('\n'), contains('skipped  unit (needs fmt)'));
    });

    test('skipping carries through a task that was itself skipped', () async {
      starter = FakeStarter({'dart': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged.join('\n'), contains('skipped  all (needs lint)'));
    });

    test('the summary lists what failed and what did not run', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged, contains('failed   lint (exit 1)'));
      expect(logged, contains('failed   unit (exit 1)'));
      expect(logged, contains('skipped  all (needs lint)'));
    });

    test('and it is the last thing printed, after the timing', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged.last, startsWith('skipped'));
      expect(
        logged.indexWhere((l) => l.startsWith('total')),
        lessThan(logged.indexWhere((l) => l.startsWith('failed'))),
      );
    });

    test(
      'a single failure gets no summary, which would summarise nothing',
      () async {
        starter = FakeStarter({'dart': 1});
        await runFile(
          'version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n',
          'a',
          keepGoing: true,
        );
        expect(logged.join('\n'), isNot(contains('failed   a')));
      },
    );

    test('the exit code is the FIRST failure, however many follow', () async {
      // A code is §5.3's shortest possible bug report about one failure, and a
      // run with two cannot honestly claim to be about both. Here the first is
      // a missing tool (3) and the second a task that ran and failed (1).
      starter = FakeStarter({'pytest': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  lint: {desc: a, run: [missing-linter]}\n'
            '  unit: {desc: b, run: [pytest]}\n'
            '  all: {desc: c, needs: [lint, unit]}\n',
        'all',
        keepGoing: true,
      );
      expect(code, ExitCode.missingTool);
      expect(logged.join('\n'), contains('failed   unit (exit 1)'));
    });

    test('a failed publish is not announced anyway', () async {
      // The `then:` rule does not change: a continuation runs after a body
      // that SUCCEEDED, and --keep-going does not turn it into "run it either
      // way".
      starter = FakeStarter({'publish': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  publish: {desc: a, then: [announce], run: [publish]}\n'
            '  announce: {desc: b, run: [announce]}\n',
        'publish',
        keepGoing: true,
      );
      expect(code, ExitCode.taskFailed);
      expect(starter.started.map((s) => p.basename(s.executable)), ['publish']);
      expect(logged.join('\n'), contains('skipped  announce'));
    });

    test('and a continuation that fails on its own is still 4', () async {
      starter = FakeStarter({'announce': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  publish: {desc: a, then: [announce], run: [publish]}\n'
            '  announce: {desc: b, run: [announce]}\n',
        'publish',
        keepGoing: true,
      );
      expect(code, ExitCode.continuationFailed);
      expect(logged.join('\n'), contains(ExitCode.continuationNotice));
    });
  });

  group('where a body runs', () {
    test('the repository root, when `in:` is not written', () async {
      await runFile('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      expect(starter.started.single.workingDirectory, root.path);
    });

    test('`in:` is taken relative to the root, never to the shell', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, in: packages/lake, run: [dart]}\n',
        'a',
      );
      expect(
        starter.started.single.workingDirectory,
        p.join(root.path, 'packages/lake'),
      );
    });

    test(r'`in: $each` without an `each:` set is refused', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            r'  a: {desc: x, in: $each, run: [dart]}'
            '\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
      expect(logged.join('\n'), contains(r'`in: $each` without an `each:`'));
    });
  });

  group('`env:` is a key, not shell syntax', () {
    test(
      'it is added to the ambient environment, not swapped for it',
      () async {
        await runFile(
          'version: 1\ntasks:\n'
              "  a: {desc: x, run: [dart], env: {UPDATE_GOLDENS: '1'}}\n",
          'a',
          environment: {'PATH': '/bin', 'HOME': '/home'},
        );
        final env = starter.started.single.environment;
        expect(env['UPDATE_GOLDENS'], '1');
        expect(env['HOME'], '/home', reason: 'the ambient one survives');
      },
    );

    test('a task value wins over the ambient one', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart], env: {K: task}}\n',
        'a',
        environment: {'K': 'ambient'},
      );
      expect(starter.started.single.environment['K'], 'task');
    });
  });

  group('`env-required` is checked before the body, and installs nothing', () {
    test('a missing variable stops the task before it starts', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, env-required: [CHROMEDRIVER], run: [dart]}\n',
        'a',
      );
      expect(code, ExitCode.taskFailed);
      expect(starter.started, isEmpty);
      // The whole value of the key: not "a browser test failed somewhere
      // inside" but the name of the thing that is missing.
      expect(logged.join('\n'), contains('requires the environment variable'));
      expect(logged.join('\n'), contains('CHROMEDRIVER'));
    });

    test('a variable that is set lets the body run', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, env-required: [CHROMEDRIVER], run: [dart]}\n',
        'a',
        environment: {'CHROMEDRIVER': '/usr/bin/chromedriver'},
      );
      expect(code, ExitCode.success);
      expect(starter.started, hasLength(1));
    });

    test('a variable set to nothing counts as missing', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, env-required: [CHROMEDRIVER], run: [dart]}\n',
        'a',
        environment: {'CHROMEDRIVER': ''},
      );
      expect(code, ExitCode.taskFailed);
    });
  });

  group("a `do:` body is the project's own Dart", () {
    test('the verb is called, with args and argv-from resolved', () async {
      given(['x.lake']);
      late VerbContext seen;
      final code = await runFile(
        'version: 1\n'
            "sets:\n  srcs: {include: ['**/*.lake']}\n"
            'tasks:\n'
            '  a: {desc: x, do: fmt, args: [--write], argv-from: srcs}\n',
        'a',
        verbs: {
          'fmt': (context) async {
            seen = context;
            return ExitCode.success;
          },
        },
      );
      expect(code, ExitCode.success);
      expect(seen.args, ['--write', 'x.lake']);
      expect(seen.workingDirectory, root.path);
    });

    test('what the verb answers is what the task answers', () async {
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: nope}\n',
        'a',
        verbs: {'nope': (_) async => 3},
      );
      expect(code, ExitCode.taskFailed);
    });

    test('an unregistered verb is a file defect, not a task failure', () async {
      // The engine ships no project verbs (§9), so naming one it does not have
      // is the file being wrong — code 2, not 1.
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: ghost}\n',
        'a',
      );
      expect(code, ExitCode.invalidFile);
      expect(logged.join('\n'), contains('has not registered'));
    });
  });

  group('a continuation that fails is the third outcome, not a failure', () {
    test('exit 4, and the notice the Makefile already printed', () async {
      starter = FakeStarter({'verify': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  publish: {desc: x, run: [upload], then: [verify]}\n'
            '  verify: {desc: y, run: [verify]}\n',
        'publish',
      );
      expect(code, ExitCode.continuationFailed);
      expect(logged.join('\n'), contains(ExitCode.continuationNotice));
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['upload', 'verify'],
        reason: 'the upload happened first, and that is the point',
      );
    });

    test('a body that fails is still exit 1, continuation or not', () async {
      starter = FakeStarter({'upload': 1});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  publish: {desc: x, run: [upload], then: [verify]}\n'
            '  verify: {desc: y, run: [verify]}\n',
        'publish',
      );
      expect(code, ExitCode.taskFailed);
      expect(logged.join('\n'), isNot(contains(ExitCode.continuationNotice)));
    });

    test('a missing tool INSIDE a continuation still answers 4', () async {
      // The code carries where, not what. The publish happened either way, and
      // that is the fact a pipeline must not lose.
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  publish: {desc: x, run: [upload], then: [verify]}\n'
            '  verify: {desc: y, run: [missing-tool]}\n',
        'publish',
      );
      expect(code, ExitCode.continuationFailed);
    });
  });

  group('§5.4 rule 3: arguments to a batch shim', () {
    ExecutableResolver windowsShims() => ExecutableResolver(
      environment: const {'PATH': r'C:\bin', 'PATHEXT': '.BAT'},
      windows: true,
      isRunnable: (path) => path.toLowerCase().endsWith('.bat'),
    );

    test('a plain argument goes through the shell, because it must', () async {
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, analyze]}\n',
        'a',
        resolver: windowsShims(),
      );
      expect(code, ExitCode.success);
      expect(starter.started.single.runInShell, isTrue);
      expect(starter.started.single.executable, r'C:\bin\dart.BAT');
    });

    test(
      'an argument the shell would reinterpret is REFUSED, not passed',
      () async {
        // The honest answer to an obligation that cannot be verified from a
        // machine that is not Windows. Passing `&` through means cmd.exe ends
        // the command and starts another one, silently — the worst outcome
        // available. Refusing names the character and says what it would do.
        final code = await runFile(
          'version: 1\ntasks:\n'
              '  a: {desc: x, run: [dart, "--name=a&b"]}\n',
          'a',
          resolver: windowsShims(),
        );
        expect(code, ExitCode.invalidFile);
        expect(starter.started, isEmpty);
        final message = logged.join('\n');
        expect(message, contains('batch file'));
        expect(message, contains('shell operator'));
      },
    );

    test('every character cmd acts on is covered', () async {
      for (final bad in ['a&b', 'a|b', 'a<b', 'a>b', 'a^b', 'a(b', 'a)b']) {
        starter = FakeStarter();
        logged = [];
        final code = await runFile(
          'version: 1\ntasks:\n  a: {desc: x, run: [dart, "$bad"]}\n',
          'a',
          resolver: windowsShims(),
        );
        expect(code, ExitCode.invalidFile, reason: bad);
      }
    });

    test('the same argument is fine when no shell is involved', () async {
      // On POSIX, and on Windows for a real executable, nothing reinterprets
      // it — so the limit applies exactly where the risk is and nowhere else.
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, run: [dart, "--name=a&b"]}\n',
        'a',
      );
      expect(code, ExitCode.success);
      expect(starter.started.single.arguments, ['--name=a&b']);
      expect(starter.started.single.runInShell, isFalse);
    });
  });

  group('a composite has nothing of its own to run', () {
    test('its needs run and it does not start a process', () async {
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  check: {desc: x, needs: [a]}\n'
            '  a: {desc: y, run: [dart]}\n',
        'check',
      );
      expect(code, ExitCode.success);
      expect(starter.started, hasLength(1));
      expect(logged.join('\n'), contains('nothing of its own to run'));
    });
  });

  group('the real starter, against a real process', () {
    // The one thing the fake cannot answer. Everything else above is about
    // which processes would start; this is about a process actually starting.
    test('runs it and reports its code', () async {
      const starter = SystemProcessStarter();
      final code = await starter.start(
        Platform.resolvedExecutable,
        ['--version'],
        workingDirectory: Directory.current.path,
        environment: Platform.environment,
        runInShell: false,
      );
      expect(code, 0);
    });

    test('a non-zero exit comes back as itself', () async {
      const starter = SystemProcessStarter();
      final code = await starter.start(
        Platform.resolvedExecutable,
        ['run', 'no_such_file_4f3a9.dart'],
        workingDirectory: Directory.current.path,
        environment: Platform.environment,
        runInShell: false,
      );
      expect(code, isNot(0));
    });
  }, testOn: 'vm');
}
