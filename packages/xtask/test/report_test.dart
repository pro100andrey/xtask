import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart';

void main() {
  group('`--report` is the run as JSON, versioned', () {
    final run = (
      tasks: [
        const Ended(
          'fmt',
          Result.passed,
          took: Duration(milliseconds: 412),
        ),
        const Ended(
          'test',
          Result.failed,
          took: Duration(milliseconds: 2500),
          code: 1,
          why: 'task `test` at `pkg/a` failed with exit code 1',
          members: [
            Ended(
              'pkg/a',
              Result.failed,
              took: Duration(seconds: 2),
              code: 1,
              why: 'task `test` at `pkg/a` failed with exit code 1',
            ),
            Ended('pkg/b', Result.notRun, why: 'the run stopped'),
          ],
        ),
        const Ended('ship', Result.skipped, why: 'needs `test`'),
      ],
      took: const Duration(milliseconds: 2950),
    );

    test('every task in plan order, members under their task', () {
      expect(runReport('check', run, code: 1), {
        'version': reportVersion,
        'task': 'check',
        'complete': true,
        'code': 1,
        'seconds': 2.95,
        'tasks': [
          {'task': 'fmt', 'result': 'passed', 'seconds': 0.412},
          {
            'task': 'test',
            'result': 'failed',
            'seconds': 2.5,
            'code': 1,
            'why': 'task `test` at `pkg/a` failed with exit code 1',
            'members': [
              {
                'member': 'pkg/a',
                'result': 'failed',
                'seconds': 2.0,
                'code': 1,
                'why': 'task `test` at `pkg/a` failed with exit code 1',
              },
              {
                'member': 'pkg/b',
                'result': 'not-run',
                'why': 'the run stopped',
              },
            ],
          },
          {'task': 'ship', 'result': 'skipped', 'why': 'needs `test`'},
        ],
      });
    });

    test('a run not over yet has no code, and says it is not complete', () {
      final json = runReport('check', run);
      expect(json['complete'], isFalse);
      expect(json.containsKey('code'), isFalse);
    });

    test('a run refused before any task began says why, and has no tasks', () {
      expect(
        runReport('chek', null, code: 2, refusal: 'no task called `chek`'),
        {
          'version': reportVersion,
          'task': 'chek',
          'complete': true,
          'code': 2,
          'why': 'no task called `chek`',
          'tasks': <Object?>[],
        },
      );
    });
  });

  group('the summary is one tree: status, time and why on one line', () {
    // It was two blocks: what each task took, and under it what failed and
    // what was skipped. A task was looked for in both and its time and its
    // fate read from different places, and a skipped task had no time to
    // line up with. One row per task, each saying all three.
    Duration ms(int n) => Duration(milliseconds: n);

    test('every task in plan order, members under their task', () {
      final lines = summary((
        tasks: [
          Ended('format', Result.passed, took: ms(400)),
          Ended('analyze', Result.passed, took: ms(300)),
          Ended(
            'test',
            Result.failed,
            took: ms(14700),
            code: 1,
            why: 'task `test` at `packages/xtask_kit` failed with exit code 1',
            members: [
              Ended('packages/xtask', Result.passed, took: ms(11200)),
              Ended(
                'packages/xtask_kit',
                Result.failed,
                took: ms(3500),
                code: 1,
                why: 'task `test` at `packages/xtask_kit` failed',
              ),
            ],
          ),
          const Ended(
            'publishable',
            Result.skipped,
            why: 'needs `test`, which did not pass',
          ),
          const Ended('install', Result.skipped, why: 'linux only'),
          const Ended(
            'announce',
            Result.notRun,
            why: 'the run stopped at an earlier failure',
          ),
        ],
        took: ms(15400),
      ), concurrent: false);
      expect(lines, [
        '',
        '✓ format                 0.4s',
        '✓ analyze                0.3s',
        '✗ test                  14.7s',
        '  ✓ packages/xtask      11.2s',
        '  ✗ packages/xtask_kit   3.5s  exit 1',
        '⊘ publishable                  needs `test`, which did not pass',
        '⊘ install                      linux only',
        '· announce                     the run stopped at an earlier failure',
        '  total                 15.4s',
      ]);
    });

    test('a lone failure gets its row like any other task', () {
      // It used to get no summary at all — it had printed itself already.
      // That was a rule about a block of failures; a row is the task's time
      // too, which was printed for it anyway, and leaving the one red task
      // out of the tree would make the tree a list of everything but it.
      expect(
        summary((
          tasks: [Ended('a', Result.failed, took: ms(1000), code: 1)],
          took: ms(1000),
        ), concurrent: false),
        ['', '✗ a  1.0s  exit 1'],
      );
    });

    test('a single task gets no total, which would repeat it', () {
      expect(
        summary((
          tasks: [Ended('a', Result.passed, took: ms(1000))],
          took: ms(1000),
        ), concurrent: false),
        ['', '✓ a  1.0s'],
      );
    });

    test('and nothing in the plan, nothing to say', () {
      expect(
        summary((tasks: const [], took: Duration.zero), concurrent: false),
        isEmpty,
      );
    });

    test('a task stopped part-way is told from one never begun', () {
      // Both are `not-run` in the report; what tells them apart is whether
      // the task has a time, which is whether it began.
      final lines = summary((
        tasks: [
          Ended(
            'slow',
            Result.notRun,
            took: ms(2000),
            why: 'stopped part-way: the run received SIGINT',
          ),
          const Ended(
            'next',
            Result.notRun,
            why: 'the run received SIGINT before it began',
          ),
        ],
        took: ms(2000),
      ), concurrent: false);
      expect(lines[1], startsWith('⏹ slow  2.0s  stopped part-way'));
      expect(lines[2], startsWith('· next        the run received'));
    });

    test('members only where there is more than one of them', () {
      // One member is the task, said twice.
      final lines = summary((
        tasks: [
          Ended(
            'a',
            Result.passed,
            took: ms(1000),
            members: const [Ended('packages/a', Result.passed)],
          ),
        ],
        took: ms(1000),
      ), concurrent: false);
      expect(lines, ['', '✓ a  1.0s']);
    });

    test("a task's code is on its own row unless a member's row says it", () {
      // A set changed under a task whose members all passed is the task's
      // failure, and no member row would carry it.
      final lines = summary((
        tasks: [
          Ended(
            'gen',
            Result.failed,
            took: ms(2000),
            code: 1,
            members: [
              Ended('a', Result.passed, took: ms(1000)),
              Ended('b', Result.passed, took: ms(1000)),
            ],
          ),
        ],
        took: ms(2000),
      ), concurrent: false);
      expect(lines[1], '✗ gen  2.0s  exit 1');
    });

    test('a member that never began says why', () {
      final lines = summary((
        tasks: [
          Ended(
            'suite',
            Result.notRun,
            took: ms(1000),
            why: 'stopped after 1 of 2 members, at an earlier failure',
            members: [
              Ended('a', Result.passed, took: ms(1000)),
              const Ended(
                'b',
                Result.notRun,
                why: 'the run stopped at an earlier failure',
              ),
            ],
          ),
        ],
        took: ms(1000),
      ), concurrent: false);
      expect(lines[3], '  · b          the run stopped at an earlier failure');
    });
  });

  group('the total is how much work there was', () {
    Duration s(int n) => Duration(seconds: n);
    List<Ended> four(Duration each) => [
      for (final at in [1, 2, 3, 4]) Ended('m$at', Result.passed, took: each),
    ];

    test('and a fanned-out task contributes its members, not its row', () {
      // It summed the ROWS, and a fanned-out task's row is how long you
      // waited: four members of a second each at `-j 4` is a one-second row
      // and four seconds of work. A plan of two such tasks then reported two
      // seconds spent against two taken, which reads as a run that gained
      // nothing from `-j` when it had done eight seconds of work in two.
      final lines = summary((
        tasks: [
          Ended('a', Result.passed, took: s(1), members: four(s(1))),
          Ended('b', Result.passed, took: s(1), members: four(s(1))),
        ],
        took: s(2),
      ), concurrent: true);
      expect(lines.last, contains('8.0s spent'));
      expect(lines.last, contains('2.0s taken'));
    });

    test('and run together, both numbers, because they answer differently', () {
      // How much work there was, and how long you waited. Printing only the
      // first would report three seconds for a run that took two.
      final lines = summary((
        tasks: [
          Ended('a', Result.passed, took: s(1)),
          Ended('b', Result.passed, took: s(2)),
        ],
        took: s(2),
      ), concurrent: true);
      expect(lines.last, '  total  3.0s spent, 2.0s taken');
    });

    test('and a task that never began adds nothing and is not a total', () {
      final lines = summary((
        tasks: [
          Ended('a', Result.failed, took: s(1), code: 1),
          const Ended(
            'b',
            Result.skipped,
            why: 'needs `a`, which did not pass',
          ),
        ],
        took: s(1),
      ), concurrent: false);
      expect(lines.join('\n'), isNot(contains('total')));
    });
  });

  group('how long each task took', () {
    test('seconds to a tenth, which is what a person compares', () {
      expect(asTime(const Duration(milliseconds: 2340)), '2.3s');
      expect(asTime(Duration.zero), '0.0s');
    });

    test('and minutes once there are any, not 154.0s', () {
      expect(asTime(const Duration(seconds: 94)), '1m 34s');
      expect(asTime(const Duration(minutes: 12, seconds: 5)), '12m 05s');
      expect(asTime(const Duration(minutes: 1)), '1m 00s');
    });

    test('the numbers line up under each other', () {
      final lines = summary((
        tasks: [
          const Ended('a', Result.passed, took: Duration(seconds: 1)),
          const Ended('bbbbbbbb', Result.passed, took: Duration(minutes: 2)),
        ],
        took: const Duration(minutes: 2, seconds: 1),
      ), concurrent: false);
      expect(lines[1], '✓ a           1.0s');
      expect(lines[2], '✓ bbbbbbbb  2m 00s');
    });
  });

  group('why a task did not run', () {
    test('each reason gets a sentence that is true of it', () {
      // They were free text in one map through one template, which produced
      // `skipped third (needs a failure elsewhere)` for a task that needs
      // nothing.
      expect(
        const NeedsStopped('boom').sentence,
        'needs `boom`, which did not pass',
      );
      expect(
        const FollowsStopped('publish').sentence,
        'follows `publish`, which did not pass',
      );
      expect(
        const RunStopped().sentence,
        'the run stopped at an earlier failure',
      );
      expect(
        const NeverStartable().sentence,
        'nothing that would let it start ever finished',
      );
    });
    test('a `then:` is never described as a requirement', () {
      // Opposite answers to "why did this not run", and one wording for both
      // would misdescribe the file.
      expect(
        const FollowsStopped('publish').sentence,
        isNot(contains('needs')),
      );
    });
  });

  group('--list', () {
    test('names and descriptions, in one column', () {
      final file = parseXtaskFile('''
version: 1
tasks:
  analyze: {desc: analyze every package, run: [dart]}
  lake-format: {desc: fail if unformatted, run: [dart]}
''');
      expect(listing(file.tasks.values), [
        'analyze      analyze every package',
        'lake-format  fail if unformatted',
      ]);
    });

    test('and nothing at all for nothing at all', () {
      expect(listing(const []), isEmpty);
    });

    test('marking a task for another OS as the run will skip it here', () {
      final file = parseXtaskFile('''
version: 1
tasks:
  desktop: {desc: install the menu entry, platforms: [linux], run: [d]}
  test: {desc: run the suite, run: [d]}
''');
      expect(listing(file.tasks.values, host: OperatingSystem.macos), [
        'desktop  install the menu entry  ⊘ linux only',
        'test     run the suite',
      ]);
      expect(listing(file.tasks.values, host: OperatingSystem.linux), [
        'desktop  install the menu entry',
        'test     run the suite',
      ]);
    });

    test('and under a gate set too', () {
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  desktop:
    desc: install the menu entry
    gate: [check]
    platforms: [linux, macos]
    run: [d]
''');
      expect(grouping(file, host: OperatingSystem.windows), [
        'gate check',
        '  desktop  install the menu entry  ⊘ linux and macos only',
      ]);
    });
  });

  group('--why', () {
    test('an entry point, then the route to it edge by edge', () {
      expect(
        why('install', {
          'check': const [
            PlanEdge('check', 'needs', 'lint'),
            PlanEdge('lint', 'needs', 'install'),
          ],
        }),
        ['check', '  check needs lint', '  lint needs install'],
      );
    });

    test('an empty route means the task IS where a run starts', () {
      expect(
        why('check', {'check': const []}),
        ['check', '  nothing else names it: `check` is where a run starts'],
      );
    });

    test('and no routes is the answer, not an error', () {
      // A task no run includes looks from the outside exactly like one that
      // is checked.
      expect(why('stranded', const {}), [
        'nothing reaches `stranded` — no run includes it',
      ]);
    });
  });

  group('--graph draws what a name pulls in, as a tree', () {
    /// The members [file]'s sets are given here, as the command line would
    /// find them: the renderer reads no filesystem.
    Fan Function(Task) fans(Map<String, Fan> bySet) =>
        (task) =>
            bySet[task.each] ?? fail('`${task.name}` was not to be asked');

    test('a shared need is drawn once, and `then:` is not a need', () {
      final file = parseXtaskFile(r'''
version: 1
sets:
  pkgs: {values: [packages/a, packages/b, packages/c]}
tasks:
  publish: {desc: p, needs: [build, test], then: [announce], run: [dart]}
  build: {desc: b, each: pkgs, run: [dart, $each]}
  test: {desc: t, needs: [build], run: [dart]}
  announce: {desc: a, run: [dart]}
''');
      expect(
        graph(
          file,
          name: 'publish',
          host: OperatingSystem.linux,
          fanOf: fans({
            'pkgs': const Members(['packages/a', 'packages/b', 'packages/c']),
          }),
        ),
        [
          'publish',
          '├─ needs build ×3  packages/a, packages/b, packages/c',
          '├─ needs test',
          '│  └─ needs build  (see above)',
          '└─ then  announce',
        ],
      );
    });

    test('a gate set runs its members; one for another OS is marked', () {
      final file = parseXtaskFile(r'''
version: 1
gates: [check]
sets:
  pkgs: {values: [a]}
tasks:
  pub-get: {desc: g, run: [dart]}
  format: {desc: f, gate: [check], run: [dart]}
  analyze: {desc: a, gate: [check], needs: [pub-get], run: [dart]}
  desktop:
    desc: d
    gate: [check]
    needs: [pub-get]
    platforms: [linux]
    each: pkgs
    run: [dart, $each]
''');
      // The members of `desktop` are not asked for: the run would not expand
      // its set on this machine, so neither does the picture of the run.
      expect(
        graph(
          file,
          name: 'check',
          host: OperatingSystem.macos,
          fanOf: fans(const {}),
        ),
        [
          'gate check',
          '├─ format',
          '├─ analyze',
          '│  └─ needs pub-get',
          '└─ desktop           ⊘ linux only',
          '   └─ needs pub-get  (see above)',
        ],
      );
    });

    test('a set a task makes cannot be resolved yet, as --dry-run says', () {
      final file = parseXtaskFile(r'''
version: 1
sets:
  generated: {include: [gen/*], produced-by: gen}
tasks:
  gen: {desc: g, run: [dart]}
  lint: {desc: l, needs: [gen], each: generated, run: [dart, $each]}
''');
      expect(
        graph(
          file,
          name: 'lint',
          host: OperatingSystem.linux,
          fanOf: fans({'generated': const MembersNotYet('gen')}),
        ),
        [
          'lint          cannot be resolved yet — task `gen` makes its members',
          '└─ needs gen',
        ],
      );
    });

    test('three members are named, and a fourth rather than "1 more"', () {
      final file = parseXtaskFile(r'''
version: 1
sets:
  four: {values: [a, b, c, d]}
  five: {values: [a, b, c, d, e]}
tasks:
  t4: {desc: x, each: four, run: [dart, $each]}
  t5: {desc: y, each: five, run: [dart, $each]}
''');
      final fanOf = fans({
        'four': const Members(['a', 'b', 'c', 'd']),
        'five': const Members(['a', 'b', 'c', 'd', 'e']),
      });
      List<String> of(String name) => graph(
        file,
        name: name,
        host: OperatingSystem.linux,
        fanOf: fanOf,
      );
      expect(of('t4'), ['t4 ×4  a, b, c, d']);
      expect(of('t5'), ['t5 ×5  a, b, c and 2 more']);
    });

    test('with no name, every gate set and then what none reaches', () {
      final file = parseXtaskFile('''
version: 1
gates: [check, release, docs]
tasks:
  pub-get: {desc: g, run: [dart]}
  analyze: {desc: a, gate: [check], needs: [pub-get], run: [dart]}
  publish:
    desc: p
    gate: [release]
    needs: [pub-get]
    then: [announce]
    run: [dart]
  announce: {desc: n, run: [dart]}
  clean: {desc: c, run: [dart]}
''');
      expect(
        graph(file, host: OperatingSystem.linux, fanOf: fans(const {})),
        [
          'gate check',
          '└─ analyze',
          '   └─ needs pub-get',
          '',
          'gate release',
          '└─ publish',
          '   ├─ needs pub-get   (see above)',
          '   └─ then  announce',
          '',
          'gate docs  no task is in it',
          '',
          'ungated',
          '└─ clean',
        ],
      );
    });

    test('and with no gate sets, each task nothing names is its own', () {
      // No heading over the whole file, as `--list` has none: it would be a
      // grouping the file does not have.
      final file = parseXtaskFile('''
version: 1
tasks:
  build: {desc: b, run: [dart]}
  test: {desc: t, needs: [build], run: [dart]}
  lint: {desc: l, needs: [build], run: [dart]}
''');
      expect(
        graph(file, host: OperatingSystem.linux, fanOf: fans(const {})),
        [
          'test',
          '└─ needs build',
          '',
          'lint',
          '└─ needs build  (see above)',
        ],
      );
    });

    test('a ring is drawn to where it closes, not forever', () {
      // `--validate` reports the ring; this has only to end.
      final file = parseXtaskFile('''
version: 1
tasks:
  a: {desc: x, needs: [b], run: [dart]}
  b: {desc: y, needs: [a], run: [dart]}
''');
      expect(
        graph(file, host: OperatingSystem.linux, fanOf: fans(const {})),
        ['a', '└─ needs b', '   └─ needs a  (see above)'],
      );
    });
  });

  group('--check-ci', () {
    CiReport report({
      List<({CiStep step, String gate})> invocations = const [],
      List<({CiStep step, String mode})> questions = const [],
      List<CiStep> exempted = const [],
      List<CiProblem> problems = const [],
      List<String> unrun = const [],
    }) => CiReport(
      invocations: invocations,
      questions: questions,
      exempted: exempted,
      problems: problems,
      unrun: unrun,
    );

    const ran =
        '.github/workflows/ci.yml: job `analyze` runs the gate set '
        '`ci-analyze`';

    test('each job and the gate set it runs', () {
      expect(
        workflow(
          report(
            invocations: const [
              (
                step: CiStep('.github/workflows/ci.yml', 'analyze', 'x'),
                gate: 'ci-analyze',
              ),
            ],
          ),
        ),
        [ran],
      );
    });

    test('a gate nothing runs is said out loud, and not judged', () {
      // one invocation per job: the gate sets are the jobs PLUS the people, and
      // nothing in the file tells those apart.
      final lines = workflow(report(unrun: const ['ci-web']));
      expect(lines.last, contains('`ci-web`'));
      expect(lines.last, contains('cannot tell those apart'));
    });

    test('a task no job reaches is named, grouped by its gate sets', () {
      final lines = workflow(
        const CiReport(
          invocations: [],
          questions: [],
          exempted: [],
          problems: [],
          unrun: [],
          unreached: [
            (task: 'ext-lint', gates: ['ext-check', 'check-all']),
            // The same membership written the other way round is the same
            // group, not a second one.
            (task: 'ext-test', gates: ['check-all', 'ext-check']),
            (task: 'new-check', gates: ['check']),
          ],
        ),
      );
      expect(lines.skip(2), [
        '  `ext-lint`, `ext-test` — in `check-all`, `ext-check`',
        '  `new-check` — in `check`',
      ]);
    });

    test('and nothing is said about it when something is broken', () {
      // The problems are the answer then; a note about who runs what would
      // bury them.
      expect(
        workflow(
          report(
            problems: const [
              RunsACommand(CiStep('ci.yml', 'analyze', 'dart analyze')),
            ],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('why a step is not a job running a gate set', () {
    const step = CiStep('ci.yml', 'analyze', 'dart run :xtask check -j abc');

    test('a command in the workflow is the duplicate list growing back', () {
      final lines = refusals(
        const CiReport(
          invocations: [],
          questions: [],
          exempted: [],
          problems: [RunsACommand(step)],
          unrun: [],
        ),
      );
      expect(lines.single, startsWith('ci.yml: job `analyze` runs `dart run'));
      expect(lines.single, contains('belongs in the task file'));
    });

    test('and one the command line refuses is quoted, not guessed at', () {
      // "What runs belongs in the task file" is the wrong sentence about a
      // step that names a gate set correctly and would still exit before doing
      // anything: it sends the reader to move a task that is already there.
      final lines = refusals(
        const CiReport(
          invocations: [],
          questions: [],
          exempted: [],
          problems: [
            RunsSomethingRefused(step, '`-j abc` is not a number of jobs'),
          ],
          unrun: [],
        ),
      );
      expect(lines.single, contains('which xtask refuses'));
      expect(lines.single, contains('is not a number of jobs'));
    });

    test('and an undeclared gate set names the ones that are', () {
      final lines = refusals(
        const CiReport(
          invocations: [],
          questions: [],
          exempted: [],
          problems: [
            RunsAnUndeclaredGate(step, 'chekc', {'release', 'check'}),
          ],
          unrun: [],
        ),
      );
      expect(lines.single, contains('`chekc`'));
      expect(lines.single, contains('Declared: check, release'));
    });
  });

  group('--list groups by the gate sets the file declares', () {
    XtaskFile parsed(String yaml) => parseXtaskFile(yaml);

    test('in the declared order, with the tasks under each', () {
      final lines = grouping(
        parsed(
          'version: 1\ngates: [check, release]\ntasks:\n'
          '  format: {desc: f, gate: [check], run: [d]}\n'
          '  test: {desc: t, gate: [check], run: [d]}\n'
          '  publishable: {desc: p, gate: [release], run: [d]}\n',
        ),
      );
      expect(lines.first, 'gate check');
      expect(lines[1], contains('format'));
      expect(lines[2], contains('test'));
      expect(lines, contains('gate release'));
      // Declared order, not alphabetical and not the tasks' order.
      expect(
        lines.indexOf('gate check'),
        lessThan(lines.indexOf('gate release')),
      );
    });

    test('a task in two sets appears under both, which is what it is', () {
      final lines = grouping(
        parsed(
          'version: 1\ngates: [check, ci]\ntasks:\n'
          '  a: {desc: x, gate: [check, ci], run: [d]}\n',
        ),
      );
      expect(lines.where((l) => l.contains('  a ')), hasLength(2));
    });

    test('`ungated` is complete, which is what the declaration buys', () {
      // A gate that existed by being mentioned had no complete list, so a
      // heading saying "nothing runs these" could not be trusted.
      final lines = grouping(
        parsed(
          'version: 1\ngates: [check]\ntasks:\n'
          '  a: {desc: x, gate: [check], run: [d]}\n'
          '  aot: {desc: y, run: [d]}\n',
        ),
      );
      expect(lines, contains('ungated'));
      expect(lines.last, contains('aot'));
    });

    test('a task whose gate set is misspelled still appears', () {
      // It belongs to no declared set, so it matched neither bucket and
      // vanished from the listing entirely — one transposed letter turning
      // this report into a lie by omission. Naming the misspelling is
      // `--validate`'s job; being complete is this one's.
      final lines = grouping(
        parsed(
          'version: 1\ngates: [check]\ntasks:\n'
          '  a: {desc: x, gate: [check], run: [d]}\n'
          '  b: {desc: y, gate: [chekc], run: [d]}\n',
        ),
      );
      expect(lines.join('\n'), contains('b '));
      expect(lines, contains('ungated'));
    });

    test('a file with no gate sets is one flat column, with no heading', () {
      final lines = grouping(
        parsed('version: 1\ntasks:\n  a: {desc: x, run: [d]}\n'),
      );
      expect(lines, ['a  x']);
    });
  });

  group('what a fanned-out task added up to', () {
    Duration s(int n) => Duration(seconds: n);
    List<Ended> four(Duration each) => [
      for (final at in [1, 2, 3, 4]) Ended('m$at', Result.passed, took: each),
    ];

    test('is said beside how long it took, when the members ran together', () {
      final lines = summary((
        tasks: [
          Ended(
            'a',
            Result.passed,
            took: s(3),
            members: four(const Duration(milliseconds: 2250)),
          ),
        ],
        took: s(3),
      ), concurrent: true);
      expect(lines[1], endsWith('3.0s  9.0s over 4 members'));
    });

    test('and one after another it says nothing: the rows below add up', () {
      // Sequentially the members' work IS the task's row, and `0.8s  0.8s
      // over 2 members` was one number printed twice.
      final lines = summary((
        tasks: [Ended('a', Result.passed, took: s(4), members: four(s(1)))],
        took: s(4),
      ), concurrent: false);
      expect(lines[1], '✓ a     4.0s');
    });

    test('and under `--only` it says how much of the set that was', () {
      const narrowed = {'a': (kept: 5, of: 17), 'b': (kept: 2, of: 9)};
      final lines = summary(
        (
          tasks: [
            Ended(
              'a',
              Result.failed,
              took: s(1),
              code: 1,
              members: [
                Ended('m1', Result.failed, took: s(1), code: 1),
                for (final at in [2, 3, 4, 5])
                  Ended('m$at', Result.notRun, why: 'the run stopped'),
              ],
            ),
            Ended('b', Result.passed, took: s(1)),
          ],
          took: s(2),
        ),
        concurrent: false,
        narrowed: narrowed,
      );
      expect(
        lines[1],
        endsWith('  1 of 17 members'),
        reason: 'five were kept and the first failed: one ran',
      );
      expect(
        lines.firstWhere((line) => line.startsWith('✓ b')),
        endsWith('  2 of 9 members'),
        reason: 'without `each:`, the kept members went to one invocation',
      );
    });
  });

  test(
    '--validate says what it read, because silence is what a dead gate says',
    () {
      expect(read('/repo/xtask.yaml', 4, 2, 1), contains('4 tasks'));
      expect(read('/repo/xtask.yaml', 4, 2, 1), contains('2 gate sets'));
      expect(read('/repo/xtask.yaml', 4, 2, 1), contains('1 set,'));
      expect(read('/repo/xtask.yaml', 1, 1, 0), contains('1 task,'));
      expect(read('/repo/xtask.yaml', 1, 1, 0), contains('1 gate set,'));
      expect(read('/repo/xtask.yaml', 1, 0, 0), contains('0 sets'));
      // A file with no gate sets is a legitimate file, and "0 gate sets"
      // reads as something missing rather than as something absent.
      expect(
        read('/repo/xtask.yaml', 1, 0, 0),
        isNot(contains('gate set')),
      );
    },
  );
}
