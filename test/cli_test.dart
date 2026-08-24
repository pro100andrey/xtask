import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart';
import 'package:xtask/src/context.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/resolve.dart';
import 'package:xtask/src/schema.dart';
import 'package:xtask/src/version.dart';

/// One process the CLI asked for.
final class Started {
  Started(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

final class FakeStarter implements ProcessStarter {
  FakeStarter([this.codes = const {}]);

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
    started.add(Started(executable, arguments, workingDirectory));
    return codes[p.basename(executable)] ?? ExitCode.success;
  }
}

void main() {
  group('the invocation is a value before anything is touched', () {
    // Every refusal §7 implies, asserted without a filesystem, a plan or a
    // process anywhere near it.
    test('nothing at all is not a request', () {
      expect(parseArguments([]), isA<ShowUsage>());
      expect((parseArguments([]) as ShowUsage).problem, isNotNull);
    });

    test('the usage can be asked for, which is not an error', () {
      for (final flag in ['--help', '-h']) {
        expect((parseArguments([flag]) as ShowUsage).problem, isNull);
      }
    });

    test('a bare name is a task to run', () {
      expect((parseArguments(['ci-analyze']) as RunTask).task, 'ci-analyze');
    });

    test('each mode of §7 is its own request', () {
      expect(parseArguments(['--list']), isA<ListTasks>());
      expect(parseArguments(['--validate']), isA<Validate>());
      expect(
        (parseArguments(['--gates', 'ci-web']) as GateMembers).gate,
        'ci-web',
      );
      expect((parseArguments(['--dry-run', 'a']) as DryRunTask).task, 'a');
    });

    test('`--gate` narrows `--list`, spelled either way', () {
      expect(
        (parseArguments(['--list', '--gate', 'ci-web']) as ListTasks).gate,
        'ci-web',
      );
      expect(
        (parseArguments(['--list', '--gate=ci-web']) as ListTasks).gate,
        'ci-web',
      );
      expect((parseArguments(['--list']) as ListTasks).gate, isNull);
    });

    test('and on its own it is refused, pointing at the other name', () {
      // `--gate` and `--gates` differ by one letter and mean opposite kinds
      // of thing. Ignoring the flag, or listing everything as though it had
      // not been written, is the answer that costs somebody an afternoon.
      final usage = parseArguments(['--gate', 'ci-web']) as ShowUsage;
      expect(usage.problem, contains('--gates'));
    });

    test('two modes ask for different things', () {
      final usage = parseArguments(['--list', '--validate']) as ShowUsage;
      expect(usage.problem, contains('--list'));
      expect(usage.problem, contains('--validate'));
    });

    test('an option xtask has not got is named, not ignored', () {
      final usage = parseArguments(['--emit-ci']) as ShowUsage;
      expect(usage.problem, contains('--emit-ci'));
    });

    test('a mode that needs a name and is given none', () {
      expect((parseArguments(['--gates']) as ShowUsage).problem, isNotNull);
      expect((parseArguments(['--dry-run']) as ShowUsage).problem, isNotNull);
      expect((parseArguments(['--gate']) as ShowUsage).problem, isNotNull);
    });

    group('`--` hands the rest to one task', () {
      test('a task and its arguments', () {
        final request =
            parseArguments(['test', '--', '-n', 'a name']) as RunTask;
        expect(request.task, 'test');
        expect(request.arguments, ['-n', 'a name']);
      });

      test('and --dry-run takes them too, or it would print a lie', () {
        final request =
            parseArguments(['--dry-run', 'test', '--', '-n', 'x'])
                as DryRunTask;
        expect(request.task, 'test');
        expect(request.arguments, ['-n', 'x']);
      });

      test('everything after it is taken as written, options included', () {
        // The whole point of the separator: a parser still looking at these
        // would refuse `--list` as a second mode and `-n` as an unknown flag.
        final request =
            parseArguments(['test', '--', '--list', '-n', '--']) as RunTask;
        expect(request.arguments, ['--list', '-n', '--']);
      });

      test('a mode that runs nothing has nowhere to put them', () {
        for (final mode in ['--list', '--validate', '--gates']) {
          expect(
            parseArguments([mode, 'x', '--', '-n']),
            isA<ShowUsage>(),
            reason: '$mode took arguments for a body it never reaches',
          );
        }
      });

      test('and neither does an invocation that named no task', () {
        // The message is the whole point here, not the refusal: without the
        // guard this still refuses, with the message "xtask runs one task at
        // a time, and it was given" and nothing after it.
        final usage = parseArguments(['--', '-n']) as ShowUsage;
        expect(usage.problem, contains('--'));
        expect(usage.problem, contains('no task was named'));
      });

      test('a bare `--` is simply no arguments', () {
        expect((parseArguments(['test', '--']) as RunTask).arguments, isEmpty);
      });
    });

    test('--why is a mode, and needs exactly one task', () {
      expect((parseArguments(['--why', 'install']) as WhyTask).task, 'install');
      expect(parseArguments(['--why']), isA<ShowUsage>());
      expect(parseArguments(['--why', 'a', 'b']), isA<ShowUsage>());
    });

    group('--keep-going', () {
      test('it is a modifier on a run, not a mode of its own', () {
        final request = parseArguments(['check', '--keep-going']) as RunTask;
        expect(request.task, 'check');
        expect(request.keepGoing, isTrue);
        expect((parseArguments(['check']) as RunTask).keepGoing, isFalse);
      });

      test('and either side of the task name', () {
        expect(
          (parseArguments(['--keep-going', 'check']) as RunTask).keepGoing,
          isTrue,
        );
      });

      test('a mode that runs nothing has no failure to keep going past', () {
        for (final mode in ['--list', '--validate', '--dry-run']) {
          final usage = parseArguments([mode, 'x', '--keep-going']);
          expect(usage, isA<ShowUsage>(), reason: '$mode accepted it');
        }
      });
    });

    test('--version is a mode, and takes nothing else', () {
      expect(parseArguments(['--version']), isA<ShowVersion>());
      expect(parseArguments(['--version', 'a']), isA<ShowUsage>());
    });

    test('--emit-schema is a mode, and takes nothing else', () {
      expect(parseArguments(['--emit-schema']), isA<EmitSchema>());
      expect(parseArguments(['--emit-schema', 'a']), isA<ShowUsage>());
    });

    test('a mode that takes no name and is given one', () {
      expect(parseArguments(['--list', 'a']), isA<ShowUsage>());
      expect(parseArguments(['--validate', 'a']), isA<ShowUsage>());
    });

    test('and one task at a time, because run-once is per invocation', () {
      final usage = parseArguments(['a', 'b']) as ShowUsage;
      expect(usage.problem, contains('`a`'));
      expect(usage.problem, contains('`b`'));
    });
  });

  group('with a file', () {
    late Directory root;
    late List<String> out;
    late List<String> err;
    late FakeStarter starter;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xtask_cli_');
      out = [];
      err = [];
      starter = FakeStarter();
    });

    tearDown(() => root.deleteSync(recursive: true));

    void writeFile(String yaml) =>
        File(p.join(root.path, xtaskFileName)).writeAsStringSync(yaml);

    Future<int> run(
      List<String> args, {
      String? from,
      Map<String, String> environment = const {},
      Map<String, Verb> verbs = const {},
    }) => runCli(
      args,
      workingDirectory: from ?? root.path,
      environment: environment,
      out: out.add,
      err: err.add,
      resolver: ExecutableResolver(
        environment: const {'PATH': '/bin'},
        windows: false,
        isRunnable: (path) => !p.basename(path).startsWith('missing'),
      ),
      starter: starter,
      verbs: verbs,
    );

    String printed() => out.join('\n');
    String complained() => err.join('\n');

    const lake = '''
version: 1
tasks:
  analyze:
    desc: analyze every package
    gate: [check, ci-analyze]
    run: [dart, analyze]
  lake-format:
    desc: fail if a .lake file is unformatted
    gate: [check, ci-analyze]
    run: [dart, run, format.dart]
  web-e2e:
    desc: browser e2e for the web binding
    gate: [ci-web]
    run: [dart, test]
  check:
    desc: reproduce CI locally
    collects: check
  ci-analyze:
    desc: the analyze job
    collects: ci-analyze
  ci-web:
    desc: the web job
    collects: ci-web
''';

    group('found from wherever the command was run', () {
      test('the directory holding it is the root', () async {
        writeFile(
          'version: 1\ntasks:\n  a: {desc: x, in: sub, run: [dart]}\n',
        );
        expect(await run(['a']), ExitCode.success);
        expect(
          starter.started.single.workingDirectory,
          p.join(root.path, 'sub'),
        );
      });

      test('including from several directories down inside it', () async {
        // Not a convenience. Every path in the file is relative to the root,
        // so taking the current directory as the root would resolve `in:`,
        // a set's globs and what `remove` may touch against the wrong place
        // — without saying so.
        writeFile(
          'version: 1\ntasks:\n  a: {desc: x, in: sub, run: [dart]}\n',
        );
        final deep = Directory(p.join(root.path, 'packages', 'lake'))
          ..createSync(recursive: true);
        expect(await run(['a'], from: deep.path), ExitCode.success);
        expect(
          starter.started.single.workingDirectory,
          p.join(root.path, 'sub'),
          reason: 'the root is the repository, not the terminal',
        );
      });

      test('and its absence names where it looked', () async {
        final empty = Directory(p.join(root.path, 'nothing-here'))
          ..createSync();
        expect(await run(['a'], from: empty.path), ExitCode.invalidFile);
        expect(complained(), contains(empty.path));
        expect(complained(), contains(xtaskFileName));
      });
    });

    group('--list', () {
      test('every task, with what it is for', () async {
        writeFile(lake);
        expect(await run(['--list']), ExitCode.success);
        expect(printed(), contains('analyze every package'));
        expect(printed(), contains('browser e2e for the web binding'));
      });

      test("in the file's order, with the names in a column", () async {
        writeFile(lake);
        await run(['--list']);
        expect(out.first, startsWith('analyze  '));
        expect(out.map((l) => l.split(' ').first).take(3), [
          'analyze',
          'lake-format',
          'web-e2e',
        ]);
        // Where each description starts: past the name and its padding.
        final column = RegExp(r'^\S+\s+');
        expect(
          out.map((l) => column.firstMatch(l)!.end).toSet(),
          hasLength(1),
          reason: 'one column, so the descriptions line up',
        );
      });

      test('and `--gate` narrows it to one gate set', () async {
        writeFile(lake);
        await run(['--list', '--gate', 'ci-web']);
        expect(printed(), contains('web-e2e'));
        expect(printed(), isNot(contains('analyze')));
      });
    });

    group('--gates', () {
      test('the members, one per line and nothing else', () async {
        writeFile(lake);
        expect(await run(['--gates', 'check']), ExitCode.success);
        expect(out, ['analyze', 'lake-format']);
      });

      test("in the file's order, which is the run order (§4.3)", () async {
        writeFile('''
version: 1
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  alpha: {desc: slow, gate: [check], run: [dart]}
  check: {desc: c, collects: check}
''');
        await run(['--gates', 'check']);
        expect(out, ['zebra', 'alpha']);
      });
    });

    group('a gate set nobody has heard of is a typo, not an empty set', () {
      // The answer to a misspelt gate must not be an empty list: `--gates
      // ci-analize` printing nothing reads as "that job checks nothing",
      // which is the failure this tool is about.
      test('--gates says so, and names the ones there are', () async {
        writeFile(lake);
        expect(await run(['--gates', 'ci-analize']), ExitCode.invalidFile);
        expect(complained(), contains('ci-analize'));
        expect(complained(), contains('ci-analyze'));
        expect(out, isEmpty);
      });

      test('and so does `--list --gate`', () async {
        writeFile(lake);
        expect(
          await run(['--list', '--gate', 'ci-nothing']),
          ExitCode.invalidFile,
        );
        expect(out, isEmpty);
      });
    });

    group('--validate', () {
      test(
        'says what it read, because silence is what a dead gate prints',
        () async {
          writeFile(lake);
          expect(await run(['--validate']), ExitCode.success);
          expect(printed(), contains(p.join(root.path, xtaskFileName)));
          expect(printed(), contains('6 tasks'));
        },
      );

      test('and counts one thing as one, not as "1 sets"', () async {
        writeFile(
          'version: 1\nsets:\n  s: [a]\n'
          'tasks:\n  a: {desc: x, argv-from: s, run: [dart]}\n',
        );
        await run(['--validate']);
        expect(printed(), contains('1 task,'));
        expect(printed(), contains('1 set,'));
      });

      test('reports every problem at once, not the first', () async {
        writeFile('''
version: 1
tasks:
  a: {desc: x, do: nobody-registered-this}
  b: {desc: x, gate: [orphaned], run: [dart]}
''');
        expect(await run(['--validate']), ExitCode.invalidFile);
        expect(complained(), contains('nobody-registered-this'));
        expect(complained(), contains('orphaned'));
      });

      test('a cycle a `collects:` closes is caught', () async {
        // Why the validator is given the COLLECTED file. The edges a gate set
        // creates do not exist until the rewrite, so validating what was
        // written would miss a ring that a run walks straight into.
        writeFile('''
version: 1
tasks:
  a: {desc: x, needs: [check], gate: [check], run: [dart]}
  check: {desc: c, collects: check}
''');
        expect(await run(['--validate']), ExitCode.invalidFile);
        expect(complained(), contains('need each other'));
      });

      test('a file that does not parse is refused with its span', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart], do: y}\n');
        expect(await run(['--validate']), ExitCode.invalidFile);
        expect(complained(), contains('line'));
        expect(out, isEmpty);
      });

      test('a project verb counts as known', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, do: regen}\n');
        expect(
          await run(
            ['--validate'],
            verbs: {'regen': (context) async => ExitCode.success},
          ),
          ExitCode.success,
        );
      });
    });

    group('running a task', () {
      test('runs it and everything it needs', () async {
        writeFile('''
version: 1
tasks:
  install: {desc: x, run: [dart, pub, get]}
  build: {desc: x, needs: [install], run: [dart, compile]}
''');
        expect(await run(['build']), ExitCode.success);
        expect(starter.started.map((s) => s.arguments.first), [
          'pub',
          'compile',
        ]);
        expect(
          starter.started.first.executable,
          '/bin/dart',
          reason: 'the resolved path §5.4 found, not the word in the file',
        );
      });

      test('a composite gathers its gate set', () async {
        writeFile(lake);
        expect(await run(['ci-analyze']), ExitCode.success);
        expect(starter.started, hasLength(2));
      });

      test('a failing task answers 1 and names itself', () async {
        starter = FakeStarter({'dart': 1});
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n');
        expect(await run(['a']), ExitCode.taskFailed);
        expect(printed(), contains('`a`'));
      });

      test('a name no task answers to is 2, not 1', () async {
        writeFile(lake);
        expect(await run(['analize']), ExitCode.invalidFile);
        expect(complained(), contains('analize'));
      });

      test('a project verb is reachable through `do:`', () async {
        var ran = false;
        writeFile('version: 1\ntasks:\n  a: {desc: x, do: regen}\n');
        final code = await run(
          ['a'],
          verbs: {
            'regen': (context) async {
              ran = true;
              return ExitCode.success;
            },
          },
        );
        expect(code, ExitCode.success);
        expect(ran, isTrue);
      });

      test('and one shadowing a primitive is refused, not preferred', () async {
        // §6 is a closed list so that "what does this verb do" has one
        // answer. A silent shadow of `remove` costs somebody a directory.
        writeFile('version: 1\ntasks:\n  a: {desc: x, do: remove}\n');
        final code = await run(
          ['a'],
          verbs: {'remove': (context) async => ExitCode.success},
        );
        expect(code, ExitCode.invalidFile);
        expect(complained(), contains('remove'));
        expect(complained(), contains('§6'));
      });
    });

    group('a task is a section on a host that folds one (§7.1)', () {
      test('GitHub gets its markers, around each task', () async {
        writeFile('''
version: 1
tasks:
  install: {desc: x, run: [dart, pub, get]}
  build: {desc: x, needs: [install], run: [dart, compile]}
''');
        await run(['build'], environment: {'GITHUB_ACTIONS': 'true'});
        expect(out.where((l) => l.startsWith('::group::')), [
          '::group::install',
          '::group::build',
        ]);
        expect(out.where((l) => l == '::endgroup::'), hasLength(2));
      });

      test('and a failure closes the section BEFORE annotating', () async {
        // An `::error::` inside a group is folded away with it, so the one
        // line somebody needs would be the one they have to expand to reach.
        starter = FakeStarter({'dart': 1});
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n');
        await run(['a'], environment: {'GITHUB_ACTIONS': 'true'});
        final error = out.indexWhere((l) => l.startsWith('::error::'));
        expect(error, greaterThan(0));
        expect(out[error - 1], '::endgroup::');
      });

      test(
        'a section is closed even when the file is what stopped it',
        () async {
          // A set expanding to nothing is an error §8 catches without running
          // anything — but reached here it must still close the group it
          // opened, or everything after it folds into a task that has stopped.
          writeFile('''
version: 1
sets:
  pkgs:
    include: [packages/*]
tasks:
  a: {desc: x, each: pkgs, run: [dart, test]}
''');
          final code = await run(
            ['a'],
            environment: {'GITHUB_ACTIONS': 'true'},
          );
          expect(code, ExitCode.invalidFile);
          expect(printed(), contains('::group::a'));
          expect(printed(), contains('::endgroup::'));
          expect(printed(), contains('::error::'));
          expect(
            printed(),
            isNot(contains('::error::task `a` cannot run:\n')),
            reason: 'a newline would truncate the annotation',
          );
        },
      );

      test('anywhere else the task is still named, without markers', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n');
        await run(['a']);
        expect(printed(), contains('a'));
        expect(printed(), isNot(contains('::group::')));
      });
    });

    group('arguments after `--`', () {
      test('reach the named task, and the plan shows them', () async {
        writeFile('''
version: 1
tasks:
  install: {desc: x, run: [dart, pub, get]}
  test: {desc: x, needs: [install], run: [dart, test]}
''');
        expect(
          await run(['test', '--', '-n', 'one test']),
          ExitCode.success,
        );
        expect(starter.started.last.arguments, ['test', '-n', 'one test']);
      });

      test('and only it — a dependency gets what the file says', () async {
        writeFile('''
version: 1
tasks:
  install: {desc: x, run: [dart, pub, get]}
  test: {desc: x, needs: [install], run: [dart, test]}
''');
        await run(['test', '--', '-n', 'x']);
        expect(starter.started.first.arguments, ['pub', 'get']);
      });

      test('a task with nothing of its own to run is refused', () async {
        // A composite gathers other tasks. Handing it arguments that reach
        // nothing is a command that looks as though it did what was asked.
        writeFile(lake);
        expect(await run(['check', '--', '-n', 'x']), ExitCode.invalidFile);
        expect(complained(), contains('`-n`'));
        expect(starter.started, isEmpty);
      });

      test('but the same composite runs fine without them', () async {
        writeFile(lake);
        expect(await run(['check']), ExitCode.success);
      });

      test('and --dry-run prints what will actually be run', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n');
        await run(['--dry-run', 'a', '--', '-n', 'two words']);
        expect(printed(), contains("run  /bin/dart test -n 'two words'"));
      });
    });

    group('running with --keep-going', () {
      test(
        'the whole gate is attempted and the summary says what broke',
        () async {
          starter = FakeStarter({'ruff': 1, 'pytest': 1});
          writeFile('''
version: 1
tasks:
  lint: {desc: a, gate: [check], run: [ruff]}
  unit: {desc: b, gate: [check], run: [pytest]}
  check: {desc: c, collects: check}
''');
          expect(await run(['check', '--keep-going']), ExitCode.taskFailed);
          expect(starter.started, hasLength(2));
          expect(printed(), contains('failed   lint (exit 1)'));
          expect(printed(), contains('failed   unit (exit 1)'));
          expect(printed(), contains('skipped  check (needs lint)'));
        },
      );

      test('and without it the same gate stops at the first', () async {
        starter = FakeStarter({'ruff': 1, 'pytest': 1});
        writeFile('''
version: 1
tasks:
  lint: {desc: a, gate: [check], run: [ruff]}
  unit: {desc: b, gate: [check], run: [pytest]}
  check: {desc: c, collects: check}
''');
        expect(await run(['check']), ExitCode.taskFailed);
        expect(starter.started, hasLength(1));
      });

      test(
        'every failure is its own annotation on a host that has them',
        () async {
          starter = FakeStarter({'ruff': 1, 'pytest': 1});
          writeFile('''
version: 1
tasks:
  lint: {desc: a, gate: [check], run: [ruff]}
  unit: {desc: b, gate: [check], run: [pytest]}
  check: {desc: c, collects: check}
''');
          await run(
            ['check', '--keep-going'],
            environment: {'GITHUB_ACTIONS': 'true'},
          );
          expect(out.where((l) => l.startsWith('::error::')), hasLength(2));
        },
      );
    });

    group('--why', () {
      const chain = '''
version: 1
tasks:
  install: {desc: a, run: [dart]}
  lint: {desc: b, gate: [check], needs: [install], run: [dart]}
  check: {desc: c, collects: check}
  publish: {desc: d, then: [announce], run: [dart]}
  announce: {desc: e, run: [dart]}
''';

      test('names each entry point and the edges that reach it', () async {
        writeFile(chain);
        expect(await run(['--why', 'install']), ExitCode.success);
        expect(printed(), contains('check'));
        expect(printed(), contains('check needs lint'));
        expect(printed(), contains('lint needs install'));
      });

      test('and it asks the file with `collects:` already resolved', () async {
        // Otherwise every member of a gate looks like an entry point: it is
        // the composite naming them that makes them not one.
        writeFile(chain);
        await run(['--why', 'install']);
        expect(
          out.where((l) => !l.startsWith(' ')),
          isNot(contains('lint')),
          reason: '`lint` is named by `check`, so it is not where a run starts',
        );
      });

      test('a `then:` is reported as one, not as a requirement', () async {
        writeFile(chain);
        await run(['--why', 'announce']);
        expect(printed(), contains('publish then announce'));
      });

      test('an entry point is told it is one', () async {
        writeFile(chain);
        await run(['--why', 'check']);
        expect(printed(), contains('where a run starts'));
      });

      test('a task in no plan at all gets the answer, not an error', () async {
        // The only way to be in the file and in no plan: named by something,
        // and everything that names it is in a ring with it. `--validate`
        // reports the ring; the answer here is that no run includes it, which
        // looks from the outside exactly like a task that is checked.
        writeFile('''
version: 1
tasks:
  a: {desc: x, needs: [b], run: [dart]}
  b: {desc: y, needs: [a], run: [dart]}
  c: {desc: z, run: [dart]}
''');
        expect(await run(['--why', 'a']), ExitCode.success);
        expect(printed(), contains('nothing reaches `a`'));
      });

      test('while a lone task IS an entry point, not an orphan', () async {
        writeFile('''
version: 1
tasks:
  a: {desc: x, run: [dart]}
  lonely: {desc: y, run: [dart]}
''');
        await run(['--why', 'lonely']);
        expect(printed(), contains('where a run starts'));
      });

      test('and a name no task answers to is refused', () async {
        writeFile(chain);
        expect(await run(['--why', 'instal']), ExitCode.invalidFile);
        expect(complained(), contains('instal'));
      });
    });

    group('--version', () {
      // No `writeFile`: the first thing a bug report needs is no use if it
      // only works in a directory that already works.
      test('answers with no file at all', () async {
        expect(await run(['--version']), ExitCode.success);
        expect(out, ['xtask $packageVersion']);
        expect(err, isEmpty);
      });

      test('and names the tool, not just a number', () async {
        // `0.1.0` on its own says nothing in a bug report pasted out of a
        // terminal that also ran three other commands.
        await run(['--version']);
        expect(out.single, startsWith('xtask '));
      });
    });

    group('--emit-schema', () {
      // No `writeFile` in either of these, deliberately.
      test(
        'answers with no file at all, which is how a repository gets one',
        () async {
          expect(await run(['--emit-schema']), ExitCode.success);
          expect(err, isEmpty);
          expect(printed(), startsWith('{'));
        },
      );

      test('and what it prints is the schema, whole and once', () async {
        // Including the trailing newline the redirect writes: a file that
        // ends without one, or with two, is a diff every editor argues with.
        await run(['--emit-schema']);
        expect('${printed()}\n', xtaskJsonSchema());
      });
    });

    group('--dry-run', () {
      test('prints the plan and starts nothing', () async {
        writeFile('''
version: 1
tasks:
  install: {desc: x, run: [dart, pub, get]}
  build: {desc: x, needs: [install], in: sub, run: [dart, compile]}
''');
        expect(await run(['--dry-run', 'build']), ExitCode.success);
        expect(out.first, 'plan: install, build');
        expect(printed(), contains('run  /bin/dart compile'));
        expect(printed(), contains(p.join(root.path, 'sub')));
        expect(starter.started, isEmpty);
      });

      test('and no sections, because it folds nothing', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, run: [dart, test]}\n');
        await run(['--dry-run', 'a'], environment: {'GITHUB_ACTIONS': 'true'});
        expect(printed(), isNot(contains('::group::')));
        expect(
          printed(),
          isNot(contains('──')),
          reason: 'nor the plain section header, which is what it would use',
        );
      });
    });

    group('the usage', () {
      test('is the error message a refused invocation gets', () async {
        expect(await run(['--emit-ci']), ExitCode.invalidFile);
        expect(complained(), contains('usage:'));
        expect(complained(), contains('--emit-ci'));
      });

      test('and asking for it is not an error', () async {
        expect(await run(['--help']), ExitCode.success);
        expect(printed(), contains('xtask --validate'));
        expect(err, isEmpty);
      });

      test('it names every mode §7 lists, and no other', () async {
        // Two lists of the flags — the parser's and this text — is exactly
        // the drift §1 is about, and they sit ten lines apart.
        await run(['--help']);
        for (final mode in {...modes, '--gate'}) {
          expect(printed(), contains(mode), reason: '$mode is missing');
        }
      });
    });
  });
}
