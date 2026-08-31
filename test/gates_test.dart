import 'package:test/test.dart';
import 'package:xtask/src/gates.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/markers.dart';
import 'package:xtask/src/parse.dart';

/// Lake's own shape, abbreviated: six gate sets, five of them one CI job.
const _lake = '''
version: 1
gates: [check, ci-analyze, ci-test, ci-web]
tasks:
  analyze:
    desc: analyze every package
    gate: [check, ci-analyze]
    run: [dart, analyze]

  lake-format:
    desc: fail if a .lake file is unformatted
    gate: [check, ci-analyze]
    do: lake-format

  test:
    desc: run every package's tests
    gate: [check, ci-test]
    run: [dart, test]

  web-e2e:
    desc: browser e2e
    gate: [ci-web]
    run: [dart, test]
''';

void main() {
  group('a gate set is its members, in declaration order', () {
    test("the order is the file's, and the file's is not alphabetical", () {
      // The fixture is deliberately anti-alphabetical. The previous version of
      // this test used tasks whose declaration order HAPPENED to be
      // alphabetical, so sorting the members left it green — it asserted the
      // property in its name and checked nothing.
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  middle: {desc: medium, gate: [check], run: [dart]}
  alpha: {desc: slow, gate: [check], run: [dart]}
''');
      expect(tasksInGate(file, 'check').map((t) => t.name), [
        'zebra',
        'middle',
        'alpha',
      ]);
    });

    test('and the plan keeps that order, cheap gates before slow ones', () {
      // Why the order is load-bearing at all (§4.3): somebody chose it by
      // writing the file, and sorting would overrule them.
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  alpha: {desc: slow, gate: [check], run: [dart]}
''');
      expect(planGate(file, 'check').names, ['zebra', 'alpha']);
    });

    test('the realistic shape reads the same way', () {
      final names = tasksInGate(
        parseXtaskFile(_lake),
        'check',
      ).map((t) => t.name);
      expect(names, ['analyze', 'lake-format', 'test']);
    });

    test('a task in two gates is in both', () {
      final file = parseXtaskFile(_lake);
      expect(tasksInGate(file, 'ci-analyze').map((t) => t.name), [
        'analyze',
        'lake-format',
      ]);
      expect(tasksInGate(file, 'check'), contains(file.tasks['analyze']));
    });

    test('a gate nobody is in is empty, not an error', () {
      // Whether that is a MISTAKE is `--validate`'s question — a declared
      // gate set with no members — not this function's.
      expect(tasksInGate(parseXtaskFile(_lake), 'ci-nothing'), isEmpty);
    });
  });

  group('a gate set is planned directly, without becoming a task', () {
    // The seam: graph.dart knows `needs:` and `then:` and nothing about gate
    // sets. Teaching it a third kind of edge would give the run order two
    // authors, so a gate set is planned by seeding one planner with each of
    // its tasks in turn — same order, same run-once rule, same cycle report.
    test('its tasks run in declaration order', () {
      expect(planGate(parseXtaskFile(_lake), 'check').names, [
        'analyze',
        'lake-format',
        'test',
      ]);
    });

    test('a task in no gate is left out of it', () {
      expect(
        planGate(parseXtaskFile(_lake), 'check').names,
        isNot(contains('web-e2e')),
      );
    });

    test("a member's own `needs:` keeps its place, in front", () {
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  install: {desc: fetch, run: [dart]}
  a: {desc: x, gate: [check], needs: [install], run: [dart]}
''');
      expect(planGate(file, 'check').names, ['install', 'a']);
    });

    test('something two members both need runs once', () {
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  install: {desc: fetch, run: [dart]}
  a: {desc: x, gate: [check], needs: [install], run: [dart]}
  b: {desc: y, gate: [check], needs: [install], run: [dart]}
''');
      expect(planGate(file, 'check').names, ['install', 'a', 'b']);
    });

    test('overlapping gate sets each get their own plan', () {
      final file = parseXtaskFile(_lake);
      expect(planGate(file, 'ci-analyze').names, ['analyze', 'lake-format']);
      expect(planGate(file, 'check').names, hasLength(3));
    });

    test('a member another member continues into waits for it', () {
      // Seeded in declaration order, `verify` went first because it was
      // WRITTEN first — ahead of the task whose `then:` reaches it, and with
      // no continuation on it, so a failed verification answered 1 rather
      // than §5.3's code and a failed publish was announced anyway. `planRun`
      // had the order right the whole time, which left `xtask publish` and
      // `xtask release` describing two different runs of the same tasks.
      final file = parseXtaskFile('''
version: 1
gates: [release]
tasks:
  verify: {desc: check what went out, gate: [release], run: [dart]}
  publish: {desc: upload, gate: [release], then: [verify], run: [dart]}
''');
      expect(planGate(file, 'release').names, ['publish', 'verify']);
      expect(planGate(file, 'release').names, planRun(file, 'publish').names);
      expect(planGate(file, 'release').steps.last.continuationOf, 'publish');
    });

    test('and it waits through a chain of them, however it was written', () {
      final file = parseXtaskFile('''
version: 1
gates: [release]
tasks:
  announce: {desc: say so, gate: [release], run: [dart]}
  verify: {desc: check, gate: [release], then: [announce], run: [dart]}
  publish: {desc: upload, gate: [release], then: [verify], run: [dart]}
''');
      expect(planGate(file, 'release').names, [
        'publish',
        'verify',
        'announce',
      ]);
    });

    test('a member reached only through `needs:` keeps declaration order', () {
      // The deferral is about `then:` alone. A member something else needs
      // comes out in front of it either way, so moving it would overrule the
      // order §4.3 says the author chose.
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  install: {desc: fetch, gate: [check], run: [dart]}
  a: {desc: x, gate: [check], needs: [install], run: [dart]}
''');
      expect(planGate(file, 'check').names, ['install', 'a']);
    });

    test('a ring of `then:` among members is planned, not refused', () {
      // Every member defers to another, so nothing is left to seed first.
      // `xtask a` runs this file without complaint; a gate set holding the
      // same tasks must not be the one thing that cannot.
      final file = parseXtaskFile('''
version: 1
gates: [check]
tasks:
  a: {desc: x, gate: [check], then: [b], run: [dart]}
  b: {desc: y, gate: [check], then: [a], run: [dart]}
''');
      expect(planGate(file, 'check').names, ['a', 'b']);
    });

    test('a gate set nothing is in plans nothing', () {
      // `--validate` refuses this file; the planner still has to answer
      // rather than throw, because `--gate-members` reads the same data.
      final file = parseXtaskFile(
        'version: 1\ngates: [empty]\ntasks:\n  a: {desc: x, run: [d]}\n',
      );
      expect(planGate(file, 'empty').names, isEmpty);
    });
  });

  group('grouping markers are detected, not configured', () {
    // A flag would be a second place to say where the run is happening, and it
    // would be wrong the day somebody copies a workflow.
    test('GitHub Actions is recognised by its own variable', () {
      expect(
        LogMarkers.forHost({'GITHUB_ACTIONS': 'true'}),
        isA<GitHubMarkers>(),
      );
    });

    test('anything else gets plain markers', () {
      expect(LogMarkers.forHost({}), isA<PlainMarkers>());
      expect(
        LogMarkers.forHost({'GITHUB_ACTIONS': 'false'}),
        isA<PlainMarkers>(),
      );
      expect(LogMarkers.forHost({'CI': 'true'}), isA<PlainMarkers>());
    });
  });

  group('on GitHub, a task is a section and a failure is an annotation', () {
    const markers = GitHubMarkers();

    test('a task opens and closes a group', () {
      expect(markers.open('analyze'), ['::group::analyze']);
      expect(markers.close(), ['::endgroup::']);
    });

    test('an error closes the group BEFORE annotating', () {
      // An `::error::` inside a group is folded away with it, so the one line
      // somebody needs would be the one line they have to expand to reach.
      final lines = markers.error('task `a` failed');
      expect(lines.first, '::endgroup::');
      expect(lines.last, startsWith('::error::'));
    });

    test('a newline in the message is escaped, not truncated', () {
      // GitHub reads a workflow command to the end of its line: an unescaped
      // newline drops everything after it out of the annotation.
      final lines = markers.error('first\nsecond');
      expect(lines.last, '::error::first%0Asecond');
      expect(lines.last, isNot(contains('\n')));
    });

    test('and a message that already reads as an escape is escaped too', () {
      // The runner DECODES what it reads back. A message quoting an argument
      // — `--name a%0Ab`, which `describe` prints verbatim — was handed over
      // untouched, decoded into the newline the escaping exists to remove,
      // and truncated at exactly the point it was written to survive.
      final lines = markers.error('run dart test --name a%0Ab');
      expect(lines.last, '::error::run dart test --name a%250Ab');
    });
  });

  group('without a host that folds, the task is still named', () {
    const markers = PlainMarkers();

    test('because knowing whose output this is matters with or without', () {
      expect(markers.open('analyze').single, contains('analyze'));
      expect(markers.close(), isEmpty);
    });

    test('and a failure is still marked', () {
      expect(markers.error('boom').single, contains('boom'));
    });
  });
}
