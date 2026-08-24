import 'package:test/test.dart';
import 'package:xtask/src/gates.dart';
import 'package:xtask/src/graph.dart';
import 'package:xtask/src/markers.dart';
import 'package:xtask/src/parse.dart';

/// Lake's own shape, abbreviated: six gate sets, five of them one CI job.
const _lake = '''
version: 1
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

  check:
    desc: reproduce CI locally
    collects: check
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
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  middle: {desc: medium, gate: [check], run: [dart]}
  alpha: {desc: slow, gate: [check], run: [dart]}
  check: {desc: c, collects: check}
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
      final file = withCollectedGates(
        parseXtaskFile('''
version: 1
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  alpha: {desc: slow, gate: [check], run: [dart]}
  check: {desc: c, collects: check}
'''),
      );
      expect(planRun(file, 'check').names, ['zebra', 'alpha', 'check']);
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
      // Whether that is a MISTAKE is `--validate`'s question (an orphan gate),
      // not this function's.
      expect(tasksInGate(parseXtaskFile(_lake), 'ci-nothing'), isEmpty);
    });
  });

  group('`collects:` becomes needs, before the planner sees it', () {
    // The seam: graph.dart knows `needs:` and `then:` and nothing about gates.
    // Teaching it a third kind of edge would give the run order two authors.
    test('the composite gains its gate members', () {
      final file = withCollectedGates(parseXtaskFile(_lake));
      expect(file.tasks['check']!.needs, ['analyze', 'lake-format', 'test']);
    });

    test('and the plan runs them in that order', () {
      final file = withCollectedGates(parseXtaskFile(_lake));
      expect(planRun(file, 'check').names, [
        'analyze',
        'lake-format',
        'test',
        'check',
      ]);
    });

    test('a task in no gate is left out of it', () {
      final file = withCollectedGates(parseXtaskFile(_lake));
      expect(planRun(file, 'check').names, isNot(contains('web-e2e')));
    });

    test('nothing else about the composite is disturbed', () {
      final file = withCollectedGates(parseXtaskFile(_lake));
      final check = file.tasks['check']!;
      expect(check.desc, 'reproduce CI locally');
      expect(check.collects, 'check');
      expect(check.body, isNull);
      expect(check.span, isNotNull);
    });

    test('a task that is not a composite is untouched', () {
      final before = parseXtaskFile(_lake).tasks['analyze']!;
      final after = withCollectedGates(parseXtaskFile(_lake)).tasks['analyze']!;
      expect(after.needs, before.needs);
      expect(after.gate, before.gate);
    });

    test('an explicit `needs:` keeps its place, in front', () {
      // A composite that wants something before its gate — a dependency fetch,
      // say — still gets it first.
      final file = withCollectedGates(
        parseXtaskFile('''
version: 1
tasks:
  install: {desc: fetch}
  a: {desc: x, gate: [check], run: [dart]}
  check: {desc: y, needs: [install], collects: check}
'''),
      );
      expect(file.tasks['check']!.needs, ['install', 'a']);
      expect(planRun(file, 'check').names, ['install', 'a', 'check']);
    });

    test('a composite inside its own gate does not need itself', () {
      // Plausible to write — `check` with `gate: [check]` — and it would
      // otherwise be reported as a cycle. Gathering a set does not mean
      // gathering yourself.
      final file = withCollectedGates(
        parseXtaskFile('''
version: 1
tasks:
  a: {desc: x, gate: [check], run: [dart]}
  check: {desc: y, gate: [check], collects: check}
'''),
      );
      expect(file.tasks['check']!.needs, ['a']);
      expect(planRun(file, 'check').names, ['a', 'check']);
    });

    test('two composites over overlapping gates each get their own', () {
      final file = withCollectedGates(
        parseXtaskFile(
          '$_lake'
          '  ci-analyze:\n'
          '    desc: the analyze job\n'
          '    collects: ci-analyze\n',
        ),
      );
      expect(file.tasks['check']!.needs, hasLength(3));
      expect(file.tasks['ci-analyze']!.needs, ['analyze', 'lake-format']);
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

  group('two questions about a gate set, and gates.dart owns both', () {
    // They were three inline expressions across cli.dart, ci.dart and
    // validate.dart. Existing and being runnable are different questions —
    // §8 judges an orphan, `--gates` only reads the data — so the answer is
    // two named functions, not one.
    const orphaned = '''
version: 1
tasks:
  analyze: {desc: a, gate: [check, ci-analyze], run: [dart]}
  check: {desc: b, collects: check}
  nobody: {desc: c, collects: never-declared}
''';

    test('a gate set exists as soon as a task says it is in one', () {
      expect(gateSets(parseXtaskFile(orphaned)), {
        'check',
        'ci-analyze',
        'never-declared',
      });
    });

    test('and being COLLECTED is the narrower question', () {
      expect(collectedGates(parseXtaskFile(orphaned)), {
        'check',
        'never-declared',
      });
    });

    test('the wider set contains the narrower one', () {
      // A composite may collect a gate nobody is in — `never-declared` here —
      // so collection is a way of existing, not a subset of membership.
      final file = parseXtaskFile(orphaned);
      expect(gateSets(file), containsAll(collectedGates(file)));
    });

    test('a file with no gates at all has neither', () {
      final file = parseXtaskFile(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart]}\n',
      );
      expect(gateSets(file), isEmpty);
      expect(collectedGates(file), isEmpty);
    });
  });
}
