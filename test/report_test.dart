import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart';

void main() {
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
        concurrent: false,
      );
      expect(lines[1], 'a           1.0s');
      expect(lines[2], 'bbbbbbbb  2m 00s');
    });

    test('a single task gets no total, which would repeat it', () {
      final lines = timing(
        {'a': const Duration(seconds: 1)},
        const Duration(seconds: 1),
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
        concurrent: true,
      );
      expect(lines.last, 'total  3.0s spent, 2.0s taken');
    });

    test('nothing ran, nothing to say', () {
      expect(timing(const {}, Duration.zero, concurrent: false), isEmpty);
    });
  });

  group('what failed and what therefore did not run', () {
    test('a lone failure gets no summary — it printed itself already', () {
      expect(stopped(const {'a': 1}, const {}), isEmpty);
    });

    test('but a lone SKIP does: nothing else ever mentions it', () {
      expect(
        stopped(const {}, const {'a': RunStopped()}),
        contains('skipped  a — the run stopped at an earlier failure'),
      );
    });

    test('each reason gets a sentence that is true of it', () {
      // They were free text in one map through one template, which produced
      // `skipped third (needs a failure elsewhere)` for a task that needs
      // nothing.
      final lines = stopped(
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
      List<String> problems = const [],
      List<String> unrun = const [],
    }) => CiReport(
      invocations: invocations,
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
        workflow(report(problems: const ['a job runs a command'])),
        isEmpty,
      );
    });
  });

  test(
    '--validate says what it read, because silence is what a dead gate says',
    () {
      expect(read('/repo/xtask.yaml', 4, 1), contains('4 tasks'));
      expect(read('/repo/xtask.yaml', 4, 1), contains('1 set,'));
      expect(read('/repo/xtask.yaml', 1, 0), contains('1 task,'));
      expect(read('/repo/xtask.yaml', 1, 0), contains('0 sets'));
    },
  );
}
