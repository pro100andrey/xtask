import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/model.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart';

void main() {
  group('the total is how much work there was', () {
    test('and a fanned-out task contributes its members, not its row', () {
      // It summed the ROWS, and a fanned-out task's row is how long you
      // waited: four members of a second each at `-j 4` is a one-second row
      // and four seconds of work. A plan of two such tasks then reported two
      // seconds spent against two taken, which reads as a run that gained
      // nothing from `-j` when it had done eight seconds of work in two.
      final lines = timing(
        {'a': const Duration(seconds: 1), 'b': const Duration(seconds: 1)},
        const Duration(seconds: 2),
        {
          'a': (spent: const Duration(seconds: 4), members: 4),
          'b': (spent: const Duration(seconds: 4), members: 4),
        },
        concurrent: true,
      );
      expect(lines.last, contains('8.0s spent'));
      expect(lines.last, contains('2.0s taken'));
    });

    test('and a task with one member is its row, said once', () {
      final lines = timing(
        {'a': const Duration(seconds: 1), 'b': const Duration(seconds: 3)},
        const Duration(seconds: 4),
        const {},
        concurrent: false,
      );
      expect(lines.last, 'total  4.0s');
    });
  });

  group('how long each task took', () {
    // A whole `Executor`, a temporary directory, a YAML parse, a plan, a fake
    // resolver and a fake process starter used to stand between this suite and
    // a `Duration → String`.
    test('seconds to a tenth, which is what a person compares', () {
      expect(asTime(const Duration(milliseconds: 2340)), '2.3s');
      expect(asTime(Duration.zero), '0.0s');
    });

    test('and minutes once there are any, not 154.0s', () {
      expect(asTime(const Duration(seconds: 94)), '1m 34s');
      expect(asTime(const Duration(minutes: 12, seconds: 5)), '12m 05s');
      expect(asTime(const Duration(minutes: 1)), '1m 00s');
    });

    test('one line per task, in the order they ran', () {
      final lines = timing(
        {
          'install': const Duration(seconds: 1),
          'build': const Duration(seconds: 2),
        },
        const Duration(seconds: 3),
        const {},
        concurrent: false,
      );
      expect(lines, ['', 'install  1.0s', 'build    2.0s', 'total    3.0s']);
    });

    test('the numbers line up under each other', () {
      final lines = timing(
        {
          'a': const Duration(seconds: 1),
          'bbbbbbbb': const Duration(minutes: 2),
        },
        const Duration(minutes: 2, seconds: 1),
        const {},
        concurrent: false,
      );
      expect(lines[1], 'a           1.0s');
      expect(lines[2], 'bbbbbbbb  2m 00s');
    });

    test('a single task gets no total, which would repeat it', () {
      final lines = timing(
        {'a': const Duration(seconds: 1)},
        const Duration(seconds: 1),
        const {},
        concurrent: false,
      );
      expect(lines, ['', 'a  1.0s']);
    });

    test('and run together, both numbers, because they answer differently', () {
      // How much work there was, and how long you waited. Printing only the
      // first would report three seconds for a run that took two.
      final lines = timing(
        {'a': const Duration(seconds: 1), 'b': const Duration(seconds: 2)},
        const Duration(seconds: 2),
        const {},
        concurrent: true,
      );
      expect(lines.last, 'total  3.0s spent, 2.0s taken');
    });

    test('nothing ran, nothing to say', () {
      expect(
        timing(const {}, Duration.zero, const {}, concurrent: false),
        isEmpty,
      );
    });
  });

  group('what failed and what therefore did not run', () {
    test('a lone failure gets no summary — it printed itself already', () {
      expect(summary(const {'a': 1}, const {}), isEmpty);
    });

    test('but a lone SKIP does: nothing else ever mentions it', () {
      expect(
        summary(const {}, const {'a': RunStopped()}),
        contains('skipped  a — the run stopped at an earlier failure'),
      );
    });

    test('each reason gets a sentence that is true of it', () {
      // They were free text in one map through one template, which produced
      // `skipped third (needs a failure elsewhere)` for a task that needs
      // nothing.
      final lines = summary(
        const {'boom': 1},
        const {
          'dependent': NeedsStopped('boom'),
          'announcement': FollowsStopped('publish'),
          'untouched': RunStopped(),
          'stranded': NeverStartable(),
        },
      );
      expect(lines, [
        '',
        'failed   boom (exit 1)',
        'skipped  dependent — needs `boom`, which did not pass',
        'skipped  announcement — follows `publish`, which did not pass',
        'skipped  untouched — the run stopped at an earlier failure',
        'skipped  stranded — nothing that would let it start ever finished',
      ]);
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
      // §7.1: the gate sets are the jobs PLUS the people, and nothing in the
      // file tells those apart.
      final lines = workflow(report(unrun: const ['ci-web']));
      expect(lines.last, contains('`ci-web`'));
      expect(lines.last, contains('cannot tell those apart'));
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
    test('is said beside how long it took', () {
      final lines = timing(
        {'a': const Duration(seconds: 3)},
        const Duration(seconds: 3),
        const {'a': (spent: Duration(seconds: 9), members: 4)},
        concurrent: true,
      );
      expect(lines[1], contains('9.0s over 4 members'));
    });

    test('and one member says nothing — it is the row already', () {
      // A task whose first member failed without `--keep-going` has exactly
      // one attempted, and `over 1 members` is not a sentence.
      final lines = timing(
        {'a': const Duration(seconds: 1)},
        const Duration(seconds: 1),
        const {'a': (spent: Duration(seconds: 1), members: 1)},
        concurrent: false,
      );
      expect(lines, ['', 'a  1.0s']);
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
