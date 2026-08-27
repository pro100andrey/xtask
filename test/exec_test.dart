import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/bodies.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/exec.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/markers.dart';
import 'package:xtask/src/parse.dart';

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
    this.timeout,
  );

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final bool runInShell;
  final Duration? timeout;
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

  /// Executables to hold part-way through, by name.
  ///
  /// A held process has started and not finished, which is the only state in
  /// which "are these two running at once" is a question with an answer.
  final holds = <String, Completer<void>>{};

  /// Which executables were given a reason to stop early, by name.
  final stoppable = <String, Future<void>>{};

  /// Executables that cannot be started at all, by name.
  ///
  /// `Process.start` throws rather than answering when the working directory
  /// is not there, so a fake that can only return an exit code cannot reach
  /// the case at all — which is why nothing here caught it for so long.
  final refuses = <String>{};

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? output,
  }) async {
    final name = p.basename(executable);
    if (until != null) {
      // The real starter kills the process; here it is enough to answer the
      // way a stopped one does.
      stoppable[name] = until;
    }
    if (refuses.contains(name)) {
      throw ProcessException(
        executable,
        arguments,
        'No such file or directory',
        2,
      );
    }
    started.add(
      Started(
        executable,
        arguments,
        workingDirectory,
        environment,
        runInShell,
        timeout,
      ),
    );
    // Two lines with a pause between them: enough to tell output that was
    // collected and printed whole from output that arrived interleaved.
    (output ?? (_) {})('$name speaking');
    if (until != null) {
      final stopped = await Future.any([
        holds[name]?.future.then((_) => false) ?? Future.value(false),
        until.then((_) => true),
      ]);
      if (stopped) {
        return SystemProcessStarter.interrupted;
      }
    } else {
      await holds[name]?.future;
    }
    (output ?? (_) {})('$name again');
    return codes[name] ?? ExitCode.success;
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
    int concurrency = 1,
    List<String> passed = const [],
    Map<String, Verb> verbs = const {},
    Map<String, String> environment = const {},
    ExecutableResolver? resolver,
    LogMarkers markers = const PlainMarkers(),
    Duration step = const Duration(milliseconds: 100),
  }) {
    final file = parseXtaskFile(yaml);
    return Executor(
      bodies: BodyResolver(
        root: root.path,
        resolver: resolver ?? resolverFor(),
        sets: file.sets,
        verbs: verbs,
        environment: environment,
        passedThrough: (task: task, arguments: passed),
      ),
      starter: starter,
      log: logged.add,
      markers: markers,
      now: ticking(step),
      keepGoing: keepGoing,
      concurrency: concurrency,
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

    test('`all` puts the resolved members where the marker is', () async {
      given(['a.lake', 'b.lake']);
      await runFile(
        'version: 1\n'
            "sets:\n  srcs: {include: ['**/*.lake']}\n"
            'tasks:\n'
            '  a: {desc: x, run: [fmt, \$all], all: srcs}\n',
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
      expect(logged.join('\n'), contains('at `one`'));
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

    test('the same for `all:`, which fails one step later', () async {
      final code = await runFile(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n  a: {desc: x, all: src, run: [dart, format, \$all]}\n',
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
      expect(failure, contains('at `one`'));
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
    test('after `args:` and after the expanded `all:`', () async {
      // Where a command line belongs: able to add to what the file already
      // said, rather than buried in front of it.
      given(['lib/a.dart']);
      await runFile(
        'version: 1\n'
            'sets:\n  src:\n    include: [lib/*.dart]\n'
            'tasks:\n'
            r'  a: {desc: x, run: [dart, format], args: [--fix, $all],'
            ' all: src}\n',
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
      expect(
        logged.join('\n'),
        contains('skipped  lint — needs `fmt`, which did not pass'),
      );
      expect(
        logged.join('\n'),
        contains('skipped  unit — needs `fmt`, which did not pass'),
      );
    });

    test('skipping carries through a task that was itself skipped', () async {
      starter = FakeStarter({'dart': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(
        logged.join('\n'),
        contains('skipped  all — needs `lint`, which did not pass'),
      );
    });

    test('the summary lists what failed and what did not run', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      await runFile(three, 'all', keepGoing: true);
      expect(logged, contains('failed   lint (exit 1)'));
      expect(logged, contains('failed   unit (exit 1)'));
      expect(
        logged,
        contains('skipped  all — needs `lint`, which did not pass'),
      );
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
      'a lone skip IS reported — nothing else ever mentions it',
      () async {
        // A failure prints itself where it happens; a skip does not. Counting
        // the two together suppressed the only line that would have said a
        // task did not run, in a run that then answered 0.
        starter = FakeStarter({'dart': 1});
        await runFile(
          'version: 1\ntasks:\n'
              '  fmt: {desc: a, run: [dart]}\n'
              '  lint: {desc: b, needs: [fmt], run: [ruff]}\n',
          'lint',
          keepGoing: true,
        );
        expect(
          logged.join('\n'),
          contains('skipped  lint — needs `fmt`, which did not pass'),
        );
      },
    );

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
      expect(
        logged.join('\n'),
        contains('skipped  announce — follows `publish`, which did not pass'),
      );
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

  group('`timeout:` reaches the starter, which is the only thing that can '
      'enforce it', () {
    test('as a duration on the process it limits', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, timeout: 300, run: [dart]}\n',
        'a',
      );
      expect(starter.started.single.timeout, const Duration(seconds: 300));
    });

    test('and nothing at all when the task set none', () async {
      await runFile('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      expect(starter.started.single.timeout, isNull);
    });

    test(
      'under `each:` it is a limit per member, not for all of them',
      () async {
        // Six packages with a limit of five minutes is thirty minutes of
        // patience, not five: the question the key answers is whether one of
        // them has hung.
        await runFile(
          'version: 1\n'
              'sets:\n  pkgs: [one, two]\n'
              'tasks:\n'
              r'  a: {desc: x, each: pkgs, in: $each, timeout: 60,'
              ' run: [dart, test]}'
              '\n',
          'a',
        );
        expect(
          starter.started.map((s) => s.timeout),
          [const Duration(seconds: 60), const Duration(seconds: 60)],
        );
      },
    );
  });

  group('a killed task is reported as killed, not as a number', () {
    test('the message names the limit it overran', () async {
      // 124 is what a killed process answers with and what a shell wrapping
      // this already checks for — and it is a number nobody reads as "it
      // hung".
      starter = FakeStarter({'dart': SystemProcessStarter.timedOut});
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, timeout: 30, run: [dart]}\n',
        'a',
      );
      final failure = logged.firstWhere((l) => l.contains('task `a`'));
      expect(failure, contains('timeout: 30'));
      expect(failure, contains('killed'));
    });

    test('and the same code without a limit is just a failure', () async {
      // Not a claim the engine cannot support: without a `timeout:` there is
      // no reason to read 124 as anything but what the program returned.
      starter = FakeStarter({'dart': SystemProcessStarter.timedOut});
      await runFile('version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n', 'a');
      final failure = logged.firstWhere((l) => l.contains('task `a`'));
      expect(failure, contains('exit code 124'));
      expect(failure, isNot(contains('killed')));
    });
  });

  group('one walk, whether or not it runs things at once', () {
    const three =
        'version: 1\ntasks:\n'
        '  boom: {desc: a, run: [ruff]}\n'
        '  other: {desc: b, run: [pytest]}\n'
        '  all: {desc: c, needs: [boom, other]}\n';

    test('at one task in flight, nothing is held back', () async {
      // §5.2's promise, and the only way this merge could have done harm: the
      // parallel walk collects a task's lines and prints them when it ends,
      // and doing that at one task a time would have silently stopped a long
      // run being watchable.
      //
      // What is watched is the ENGINE's own lines — the section header and the
      // command. A body's own output never passes through here unbuffered:
      // §5.2 gets that by inheriting the terminal, which is why the fake
      // starter writes to the `output` sink only when it is given one.
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(three, 'all');
      await pumpEventQueue();
      expect(
        logged,
        containsAllInOrder(['── boom ──', 'boom: /bin/ruff']),
        reason: 'they arrived while the task was still running',
      );
      starter.holds['ruff']!.complete();
      await running;
    });

    test('but a plan of one task is not made to wait for itself', () async {
      // Buffering exists because two tasks writing to one terminal produce a
      // transcript belonging to neither. One task cannot do that, so asking
      // for `-j` above 1 on a single task used to cost §5.2's live output and
      // buy nothing — and announce a width it had no use for.
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(three, 'boom', concurrency: 2);
      await pumpEventQueue();
      expect(
        logged,
        containsAllInOrder(['── boom ──', 'boom: /bin/ruff']),
        reason: 'it arrived while the only task was still running',
      );
      expect(
        logged.where((line) => line.contains('up to')),
        isEmpty,
        reason: 'nothing is running beside it to explain',
      );
      starter.holds['ruff']!.complete();
      await running;
    });

    test('and at two, everything waits for the task to end', () async {
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>();
      final running = runFile(three, 'all', concurrency: 2);
      await pumpEventQueue();
      expect(
        // The announcement and its blank line are what a parallel run says
        // BEFORE it goes quiet, and dropping them here is the point: what is
        // asserted is that no TASK has said anything, and a header written
        // before the first one started is not a task saying anything.
        logged.skip(2),
        isEmpty,
        reason: 'two tasks are in flight and neither has finished',
      );
      expect(
        logged.first,
        contains('up to 2 at once'),
        reason: 'and the silence it is about was announced first',
      );
      starter.holds['ruff']!.complete();
      starter.holds['pytest']!.complete();
      await running;
      expect(logged, contains('── boom ──'));
    });

    test('a sequential run says what it did not get to', () async {
      // **A behaviour change, and the one this merge makes.** The sequential
      // walk used to return the moment something failed, saying nothing about
      // the tasks it never reached; the parallel one named them. Which report
      // you got depended on a flag that is about speed. Now it does not — and
      // a task that did not run is worth a line either way.
      starter = FakeStarter({'ruff': 1});
      final code = await runFile(three, 'all');
      expect(code, ExitCode.taskFailed);
      expect(starter.started, hasLength(1), reason: 'it still stops');
      expect(
        logged.join('\n'),
        contains('skipped  other — the run stopped at an earlier failure'),
      );
    });
  });

  group('`-j` runs what does not depend on anything else', () {
    // The one place a documented promise is deliberately broken, and only when
    // asked: §5.2 wants a task's output as it arrives, and two tasks arriving
    // at once make a transcript belonging to neither.
    const three =
        'version: 1\ntasks:\n'
        '  fmt: {desc: a, run: [dart]}\n'
        '  lint: {desc: b, needs: [fmt], run: [ruff]}\n'
        '  unit: {desc: c, needs: [fmt], run: [pytest]}\n'
        '  all: {desc: d, needs: [lint, unit]}\n';

    test('two independent tasks are in flight together', () async {
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>();
      final running = runFile(three, 'all', concurrency: 2);
      await pumpEventQueue();
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['dart', 'ruff', 'pytest'],
        reason: 'both started while neither had finished',
      );
      starter.holds['ruff']!.complete();
      starter.holds['pytest']!.complete();
      expect(await running, ExitCode.success);
    });

    test('and a task that needs one still waits for it', () async {
      starter = FakeStarter()..holds['dart'] = Completer<void>();
      final running = runFile(three, 'all', concurrency: 4);
      await pumpEventQueue();
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['dart'],
        reason: 'nothing may start before what it needs has finished',
      );
      starter.holds['dart']!.complete();
      expect(await running, ExitCode.success);
    });

    test('the limit is a limit', () async {
      // Three tasks could run at once here; two are allowed to.
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>()
        ..holds['mypy'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  lint: {desc: a, run: [ruff]}\n'
            '  unit: {desc: b, run: [pytest]}\n'
            '  types: {desc: c, run: [mypy]}\n'
            '  all: {desc: d, needs: [lint, unit, types]}\n',
        'all',
        concurrency: 2,
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(2), reason: 'the third is waiting');
      for (final hold in starter.holds.values) {
        hold.complete();
      }
      await running;
      expect(starter.started, hasLength(3));
    });

    test("each task's output is printed whole, not interleaved", () async {
      // The price §5.2 is charged. Both bodies speak, pause, and speak again
      // with the other in between — and each still reads as one block.
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>();
      final running = runFile(three, 'all', concurrency: 2);
      await pumpEventQueue();
      starter.holds['pytest']!.complete();
      await pumpEventQueue();
      starter.holds['ruff']!.complete();
      await running;

      final first = logged.indexOf('ruff speaking');
      expect(first, isNot(-1));
      expect(logged[first + 1], 'ruff again');
    });

    test('a failure stops what has not started, and says so', () async {
      // Three tasks that need NOTHING, so being blocked is not what stops the
      // third: two run, one of them fails, and the third must not begin. The
      // first form of this test used dependents of the failing task, which
      // `_blockedBy` would have stopped anyway — it passed with the rule
      // removed, and a mutation said so.
      //
      // What is already running is left alone: killing it would leave whatever
      // it was half-way through in whatever state that half is.
      starter = FakeStarter({'ruff': 1})..holds['pytest'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  lint: {desc: a, run: [ruff]}\n'
            '  unit: {desc: b, run: [pytest]}\n'
            '  types: {desc: c, run: [mypy]}\n'
            '  all: {desc: d, needs: [lint, unit, types]}\n',
        'all',
        concurrency: 2,
      );
      await pumpEventQueue();
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['ruff', 'pytest'],
        reason: '`mypy` must not have begun after `ruff` failed',
      );
      starter.holds['pytest']!.complete();
      expect(await running, ExitCode.taskFailed);
      expect(starter.started, hasLength(2));
      expect(
        logged.join('\n'),
        contains('skipped  types — the run stopped at an earlier failure'),
      );
    });

    test('a plan that is not in order is named, not spun on', () async {
      // Unreachable through `planRun`, which emits every requirement before
      // the task that needs it — so the plan is built by hand. The guard is
      // against a hang, and a hang is the one failure with nothing to read
      // afterwards.
      final file = parseXtaskFile(
        'version: 1\ntasks:\n'
        '  early: {desc: a, needs: [late], run: [dart]}\n'
        '  late: {desc: b, run: [dart]}\n',
      );
      final code = await Executor(
        bodies: BodyResolver(root: root.path, resolver: resolverFor()),
        starter: starter,
        log: logged.add,
        now: ticking(const Duration(milliseconds: 100)),
        concurrency: 2,
      ).run(Plan([PlanStep(file.tasks['early']!)]));

      expect(code, ExitCode.success, reason: 'nothing failed; nothing ran');
      expect(starter.started, isEmpty);
      expect(
        logged.join('\n'),
        contains(
          'skipped  early — nothing that would let it start ever '
          'finished',
        ),
      );
    });

    test('a failure stops what has not started, and says so', () async {
      // Three tasks that need NOTHING, so being blocked is not what stops the
      // third: two run, one of them fails, and the third must not begin. The
      // first form of this test used dependents of the failing task, which
      // `_blockedBy` would have stopped anyway — it passed with the rule
      // removed, and a mutation said so.
      //
      // What is already running is left alone: killing it would leave whatever
      // it was half-way through in whatever state that half is.
      starter = FakeStarter({'ruff': 1})..holds['pytest'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  lint: {desc: a, run: [ruff]}\n'
            '  unit: {desc: b, run: [pytest]}\n'
            '  types: {desc: c, run: [mypy]}\n'
            '  all: {desc: d, needs: [lint, unit, types]}\n',
        'all',
        concurrency: 2,
      );
      await pumpEventQueue();
      expect(
        starter.started.map((s) => p.basename(s.executable)),
        ['ruff', 'pytest'],
        reason: '`mypy` must not have begun after `ruff` failed',
      );
      starter.holds['pytest']!.complete();
      expect(await running, ExitCode.taskFailed);
      expect(starter.started, hasLength(2));
      expect(
        logged.join('\n'),
        contains('skipped  types — the run stopped at an earlier failure'),
      );
    });

    test('a plan that is not in order is named, not spun on', () async {
      // Unreachable through `planRun`, which emits every requirement before
      // the task that needs it — so the plan is built by hand. The guard is
      // against a hang, and a hang is the one failure with nothing to read
      // afterwards.
      final file = parseXtaskFile(
        'version: 1\ntasks:\n'
        '  early: {desc: a, needs: [late], run: [dart]}\n'
        '  late: {desc: b, run: [dart]}\n',
      );
      final code = await Executor(
        bodies: BodyResolver(root: root.path, resolver: resolverFor()),
        starter: starter,
        log: logged.add,
        now: ticking(const Duration(milliseconds: 100)),
        concurrency: 2,
      ).run(Plan([PlanStep(file.tasks['early']!)]));

      expect(code, ExitCode.success, reason: 'nothing failed; nothing ran');
      expect(starter.started, isEmpty);
      expect(
        logged.join('\n'),
        contains(
          'skipped  early — nothing that would let it start ever '
          'finished',
        ),
      );
    });

    test('and --keep-going still runs everything independent', () async {
      starter = FakeStarter({'ruff': 1, 'pytest': 1});
      final code = await runFile(
        three,
        'all',
        concurrency: 4,
        keepGoing: true,
      );
      expect(code, ExitCode.taskFailed);
      expect(starter.started, hasLength(3));
    });

    test('the summary says both what was spent and what was taken', () async {
      // Sequentially they are the same number. Run together they answer
      // different questions, and printing only the sum would report three
      // minutes for a run that took one.
      await runFile(three, 'all', concurrency: 2);
      expect(logged.last, contains('spent'));
      expect(logged.last, contains('taken'));
    });

    test(
      'and says neither of those things when it ran one at a time',
      () async {
        await runFile(three, 'all');
        expect(logged.last, isNot(contains('spent')));
      },
    );
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

    test(r'`in: $each` without an `each:` set is refused when read', () {
      // Refused by the parser now, before a plan exists — earlier than this
      // used to be caught, and with the line it was written on.
      expect(
        () => runFile(
          'version: 1\ntasks:\n'
              r'  a: {desc: x, in: $each, run: [dart]}'
              '\n',
          'a',
        ),
        throwsA(isA<XtaskFormatException>()),
      );
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
    test('the verb is called, with args and `all:` resolved', () async {
      given(['x.lake']);
      late VerbContext seen;
      final code = await runFile(
        'version: 1\n'
            "sets:\n  srcs: {include: ['**/*.lake']}\n"
            'tasks:\n'
            '  a: {desc: x, do: fmt, args: [--write, \$all], all: srcs}\n',
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
      // The title always said this; the assertion used to say the opposite,
      // and the opposite is what shipped. A verb is the project's own Dart
      // written against §5.3 — R1 already trusts it with the logic, and
      // trusting the number it returns is the same trust. Flattening it threw
      // away what the built-in `remove` deliberately says: `invalidFile` for a
      // path outside the repository is "the FILE is wrong", and arrives as
      // "a task ran and failed" only if somebody discards it.
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: nope}\n',
        'a',
        verbs: {'nope': (_) async => ExitCode.missingTool},
      );
      expect(code, ExitCode.missingTool);
    });

    test('and a built-in primitive is a verb like any other', () async {
      // `remove` answers `invalidFile` for a path outside the repository (§6),
      // and that answer used to reach the process as 1 while the message on
      // the same run said 2.
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: nope}\n',
        'a',
        verbs: {'nope': (_) async => ExitCode.invalidFile},
      );
      expect(code, ExitCode.invalidFile);
      expect(logged.join('\n'), contains('failed with exit code 2'));
    });

    test(
      'while an external program answers with data, not a verdict',
      () async {
        // A program has never heard of §5.3: its 2 means whatever its author
        // meant. The number goes in the message and the run answers 1.
        starter = FakeStarter({'flake8': ExitCode.invalidFile});
        final code = await runFile(
          'version: 1\ntasks:\n  a: {desc: x, run: [flake8]}\n',
          'a',
        );
        expect(code, ExitCode.taskFailed);
        expect(logged.join('\n'), contains('failed with exit code 2'));
      },
    );

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

  group('a process that cannot be started at all', () {
    test('is a task failure, not an unhandled exception', () async {
      starter.refuses.add('dart');
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n',
        'a',
      );
      expect(code, ExitCode.taskFailed);
      expect(
        logged.join('\n'),
        contains('task `a` could not be started: No such file or directory'),
      );
    });

    test('names the member it was at', () async {
      given(['packages/one/x', 'packages/two/x']);
      starter.refuses.add('dart');
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [packages/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [dart, test]}'
            '\n',
        'a',
      );
      expect(logged.join('\n'), contains('at `packages/one`'));
    });

    test('leaves no section open on a host that folds', () async {
      // The half of this nobody could see from a terminal: only a
      // `RunFailure` reaches the annotation, and the annotation is what emits
      // `::endgroup::`. An escaping exception left the group open, so the rest
      // of the job folded into a task that had already died.
      starter.refuses.add('dart');
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n',
        'a',
        markers: const GitHubMarkers(),
      );
      final marks = logged.where((l) => l.startsWith('::')).toList();
      expect(marks.where((l) => l == '::group::a'), hasLength(1));
      expect(marks.where((l) => l == '::endgroup::'), hasLength(1));
      expect(marks.last, startsWith('::error::'));
    });
  });

  group('`-j` reaches the members of an `each:`', () {
    test('which is the shape the flag exists for', () async {
      // The budget used to gate which TASKS were admitted, so `-j 4` over one
      // fanned-out task admitted the task and ran its members in turn: the
      // flag did nothing at all on its commonest case.
      given(['pkg/a/x', 'pkg/b/x', 'pkg/c/x']);
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
        concurrency: 3,
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(3), reason: 'all three at once');
      starter.holds['ruff']!.complete();
      await running;
    });

    test('and the budget is a budget, not a promise', () async {
      given(['pkg/a/x', 'pkg/b/x', 'pkg/c/x']);
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
        concurrency: 2,
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(2), reason: 'the third is waiting');
      starter.holds['ruff']!.complete();
      await running;
      expect(starter.started, hasLength(3));
    });

    test('and one member at a time is still one member at a time', () async {
      // §5.2 unchanged where it was never in question.
      given(['pkg/a/x', 'pkg/b/x']);
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(1));
      starter.holds['ruff']!.complete();
      await running;
    });
  });

  group('a run that is about to go quiet says so first', () {
    test('including when the two things at once are members', () async {
      // This asked only whether the PLAN had two steps, so `xtask fmt -j 4`
      // over one `each:` task buffered every member and printed nothing at
      // all until the first ended — with no announcement, because the
      // announcement asked the same question.
      given(['pkg/a/x', 'pkg/b/x']);
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
        concurrency: 2,
      );
      expect(logged.first, contains('up to 2 at once'));
    });

    test('and says nothing when there is nothing to wait through', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [ruff]}\n',
        'a',
        concurrency: 2,
      );
      expect(logged.first, isNot(contains('at once')));
    });
  });

  group('which member the run answers for does not depend on scheduling', () {
    test('it is the earliest in the set, not the first to finish', () async {
      // A `do:` verb's code is a deliberate decision, so two members
      // answering 2 and 1 made the same command line answer differently run
      // to run once members could overlap.
      given(['pkg/a/x', 'pkg/b/x']);
      final code = await runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, do: pick}'
            '\n',
        'a',
        concurrency: 2,
        keepGoing: true,
        verbs: {
          'pick': (context) async =>
              context.workingDirectory.endsWith('a') ? 2 : 1,
        },
      );
      expect(code, 2, reason: '`pkg/a` is first in the set');
    });
  });

  group('`interruptible:` gives back what parallelism costs', () {
    test('a task that says so is stopped when the answer is known', () async {
      // Sequentially, a format failure at 0.4s means the rest never run. In
      // parallel they run to the end anyway and the machine spends the whole
      // budget to learn what it knew in a tenth of a second.
      starter = FakeStarter({'ruff': 1})..holds['pytest'] = Completer<void>();
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  fmt: {desc: a, run: [ruff]}\n'
            '  slow: {desc: b, interruptible: true, run: [pytest]}\n'
            '  all: {desc: c, needs: [fmt, slow]}\n',
        'all',
        concurrency: 2,
      );
      expect(code, ExitCode.taskFailed);
      expect(
        logged.join('\n'),
        contains('task `slow` was stopped'),
        reason: 'stopped, and not reported as a second failure',
      );
      expect(logged.join('\n'), isNot(contains('failed   slow')));
    });

    test('a task exiting 130 on its own is a failure, not a stop', () async {
      // 130 is what a shell reports for SIGINT and what plenty of programs
      // exit with by themselves. Reading it as "stopped" wherever the key
      // appeared turned a real failure into a green result nobody checked.
      starter = FakeStarter({'ruff': SystemProcessStarter.interrupted});
      final code = await runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, interruptible: true, run: [ruff]}\n',
        'a',
      );
      expect(code, ExitCode.taskFailed);
      expect(logged.join('\n'), isNot(contains('was stopped')));
    });

    test('a task that does not say so is left alone', () async {
      starter = FakeStarter({'ruff': 1})..holds['pytest'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  fmt: {desc: a, run: [ruff]}\n'
            '  slow: {desc: b, run: [pytest]}\n'
            '  all: {desc: c, needs: [fmt, slow]}\n',
        'all',
        concurrency: 2,
      );
      await pumpEventQueue();
      expect(logged.join('\n'), isNot(contains('was stopped')));
      starter.holds['pytest']!.complete();
      await running;
    });

    test(
      'and `--keep-going` stops nothing at all, which is what it says',
      () async {
        starter = FakeStarter({'ruff': 1})..holds['pytest'] = Completer<void>();
        final running = runFile(
          'version: 1\ntasks:\n'
              '  fmt: {desc: a, run: [ruff]}\n'
              '  slow: {desc: b, interruptible: true, run: [pytest]}\n'
              '  all: {desc: c, needs: [fmt, slow]}\n',
          'all',
          concurrency: 2,
          keepGoing: true,
        );
        await pumpEventQueue();
        expect(logged.join('\n'), isNot(contains('was stopped')));
        starter.holds['pytest']!.complete();
        await running;
      },
    );
  });

  group('the file says whether, the flag says how many', () {
    test("`serial:` keeps a task's members from overlapping", () async {
      // One shared `pub` cache, one git index: getting this wrong makes a run
      // flaky rather than slow, and it is the same on every machine.
      given(['pkg/a/x', 'pkg/b/x', 'pkg/c/x']);
      starter = FakeStarter()..holds['ruff'] = Completer<void>();
      final running = runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, serial: true, run: [ruff]}'
            '\n',
        'a',
        concurrency: 3,
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(1), reason: 'one at a time, at -j 3');
      starter.holds['ruff']!.complete();
      await running;
      expect(starter.started, hasLength(3));
    });

    test('`exclusive:` keeps apart two tasks the graph does not', () async {
      // Nothing in the plan says these two are related; the machine says so.
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, exclusive: [port], run: [ruff]}\n'
            '  b: {desc: y, exclusive: [port], run: [pytest]}\n'
            '  all: {desc: z, needs: [a, b]}\n',
        'all',
      );
      await pumpEventQueue();
      expect(starter.started, hasLength(1), reason: 'the token is held');
      starter.holds['ruff']!.complete();
      await pumpEventQueue();
      expect(starter.started, hasLength(2));
      starter.holds['pytest']!.complete();
      await running;
    });

    test(
      "a token-blocked task does not occupy one of `-j`'s places",
      () async {
        // The check ran a microtask after admission, so the walk's synchronous
        // pass always saw an empty set: three tasks sharing a browser were all
        // admitted, two blocked, and every independent task stayed out behind
        // them.
        starter = FakeStarter()
          ..holds['ruff'] = Completer<void>()
          ..holds['mypy'] = Completer<void>();
        final running = runFile(
          'version: 1\ntasks:\n'
              '  a: {desc: x, exclusive: [browser], run: [ruff]}\n'
              '  b: {desc: y, exclusive: [browser], run: [pytest]}\n'
              '  quick: {desc: z, run: [mypy]}\n'
              '  all: {desc: w, needs: [a, b, quick]}\n',
          'all',
          concurrency: 2,
        );
        await pumpEventQueue();
        expect(
          starter.started.map((s) => p.basename(s.executable)),
          ['ruff', 'mypy'],
          reason: '`b` is blocked, so its place went to `quick`',
        );
        for (final hold in starter.holds.values) {
          hold.complete();
        }
        await running;
      },
    );

    test('and two tasks sharing no token still run together', () async {
      starter = FakeStarter()
        ..holds['ruff'] = Completer<void>()
        ..holds['pytest'] = Completer<void>();
      final running = runFile(
        'version: 1\ntasks:\n'
            '  a: {desc: x, exclusive: [one, two], run: [ruff]}\n'
            '  b: {desc: y, exclusive: [two, one], run: [pytest]}\n'
            '  c: {desc: z, run: [mypy]}\n'
            '  all: {desc: w, needs: [a, b, c]}\n',
        'all',
        concurrency: 3,
      );
      await pumpEventQueue();
      // `c` holds nothing, and `a`/`b` name the same pair in opposite
      // orders — which is how two holders of one pair deadlock if the
      // order is the one they wrote.
      expect(starter.started.map((s) => p.basename(s.executable)), [
        'ruff',
        'mypy',
      ]);
      for (final hold in starter.holds.values) {
        hold.complete();
      }
      await running;
      expect(starter.started, hasLength(3));
    });
  });

  group('a failing member does not silence the rest', () {
    Future<int> overThree({required bool keepGoing}) {
      given(['pkg/one/x', 'pkg/two/x', 'pkg/three/x']);
      starter = FakeStarter({'ruff': 1});
      return runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
        keepGoing: keepGoing,
      );
    }

    test('--keep-going runs every one and names them all', () async {
      // The loop this ends: the first bad file abandoned the rest, so a run
      // reported one problem and a person fixed, reran, fixed, reran.
      expect(await overThree(keepGoing: true), ExitCode.taskFailed);
      expect(starter.started, hasLength(3));
      final said = logged.join('\n');
      expect(said, contains('3 of 3 members failed'));
      expect(said, contains('`pkg/one`'));
      expect(said, contains('`pkg/three`'));
    });

    test('and without it, what did not run is said out loud', () async {
      // A member that never ran read exactly like one that passed.
      expect(await overThree(keepGoing: false), ExitCode.taskFailed);
      expect(starter.started, hasLength(1));
      expect(logged.join('\n'), contains('2 of 3 not attempted'));
    });

    test('one member says nothing about counts', () async {
      given(['pkg/one/x']);
      starter = FakeStarter({'ruff': 1});
      await runFile(
        'version: 1\n'
            'sets:\n  pkgs:\n    include: [pkg/*]\n'
            'tasks:\n'
            r'  a: {desc: x, each: pkgs, in: $each, run: [ruff]}'
            '\n',
        'a',
      );
      expect(logged.join('\n'), isNot(contains('of 1')));
    });
  });

  group('a body that raises rather than answering', () {
    test("closes its section even when the failure is not this one's to "
        'answer', () async {
      // `XtaskFormatException` leaves through a rethrow, past the annotation
      // that emits `::endgroup::` — reintroducing, for one exception type,
      // the failure this whole block was written to remove.
      await expectLater(
        runFile(
          'version: 1\ntasks:\n  a: {desc: x, do: boom}\n',
          'a',
          verbs: {'boom': (_) => throw XtaskFormatException('nope')},
          markers: const GitHubMarkers(),
        ),
        throwsA(isA<XtaskFormatException>()),
      );
      expect(
        logged.where((l) => l == '::endgroup::'),
        hasLength(1),
      );
    });

    test('is a task failure, not exit 255', () async {
      final code = await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: boom}\n',
        'a',
        verbs: {'boom': (_) => throw StateError('nope')},
      );
      expect(code, ExitCode.taskFailed);
      expect(logged.join('\n'), contains('task `a` threw StateError'));
    });

    test('closes its section on a host that folds', () async {
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: boom}\n',
        'a',
        verbs: {'boom': (_) => throw StateError('nope')},
        markers: const GitHubMarkers(),
      );
      final marks = logged.where((l) => l.startsWith('::')).toList();
      expect(marks.where((l) => l == '::endgroup::'), hasLength(1));
      expect(marks.last, startsWith('::error::'));
    });

    test("a verb's own ProcessException is not read as this body failing "
        'to start', () async {
      // A verb that shells out to something absent raises the same exception
      // a body does. Reported as "could not be started" it would print
      // `do <verb>` underneath, sending the reader at the wrong command.
      await runFile(
        'version: 1\ntasks:\n  a: {desc: x, do: boom}\n',
        'a',
        verbs: {
          'boom': (_) => throw const ProcessException('git', ['log']),
        },
      );
      final said = logged.join('\n');
      expect(said, contains('threw ProcessException'));
      expect(said, isNot(contains('could not be started')));
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

    test('a missing working directory throws rather than answering', () {
      // What makes the wrapper above necessary rather than defensive: the
      // real starter cannot report this as a code, because there is no
      // process to get a code from.
      const starter = SystemProcessStarter();
      expect(
        () => starter.start(
          Platform.resolvedExecutable,
          ['--version'],
          workingDirectory: p.join(Directory.current.path, 'no_such_dir_9f2'),
          environment: Platform.environment,
          runInShell: false,
        ),
        throwsA(isA<ProcessException>()),
      );
    });

    test('a process is stopped when the run gives up on it', () async {
      // The one thing no fake can answer: whether the process actually dies.
      const starter = SystemProcessStarter();
      final giveUp = Completer<void>();
      final began = DateTime.now();
      final running = starter.start(
        Platform.resolvedExecutable,
        ['run', p.join('test', 'fixtures', 'hangs.dart')],
        workingDirectory: Directory.current.path,
        environment: Platform.environment,
        runInShell: false,
        until: giveUp.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      giveUp.complete();
      expect(await running, SystemProcessStarter.interrupted);
      expect(
        DateTime.now().difference(began),
        lessThan(const Duration(seconds: 20)),
        reason: 'it was stopped, not waited out',
      );
    });

    test('a process that overstays is killed, and says so', () async {
      // The one thing no fake can answer: whether the process actually dies.
      // A Dart that reads stdin forever is portable and needs no `sleep`.
      const starter = SystemProcessStarter();
      final began = DateTime.now();
      final code = await starter.start(
        Platform.resolvedExecutable,
        ['run', p.join('test', 'fixtures', 'hangs.dart')],
        workingDirectory: Directory.current.path,
        environment: Platform.environment,
        runInShell: false,
        timeout: const Duration(seconds: 2),
      );
      expect(code, SystemProcessStarter.timedOut);
      expect(
        DateTime.now().difference(began),
        lessThan(const Duration(seconds: 30)),
        reason: 'it waited for the process instead of ending it',
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test(
      'and one that ignores being asked is killed anyway',
      () async {
        // SIGTERM is a request. The escalation is what makes `timeout:` a limit
        // rather than a suggestion, and only a process that refuses the request
        // can tell the two apart.
        const starter = SystemProcessStarter(grace: Duration(seconds: 2));
        final code = await starter.start(
          Platform.resolvedExecutable,
          ['run', p.join('test', 'fixtures', 'ignores_sigterm.dart')],
          workingDirectory: Directory.current.path,
          environment: Platform.environment,
          runInShell: false,
          timeout: const Duration(seconds: 2),
        );
        expect(code, SystemProcessStarter.timedOut);
      },
      timeout: const Timeout(Duration(seconds: 30)),
      testOn: '!windows',
    );

    test('and one that finishes in time is not touched', () async {
      const starter = SystemProcessStarter();
      final code = await starter.start(
        Platform.resolvedExecutable,
        ['--version'],
        workingDirectory: Directory.current.path,
        environment: Platform.environment,
        runInShell: false,
        timeout: const Duration(seconds: 60),
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
