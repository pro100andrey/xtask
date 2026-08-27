import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/sets.dart';
import 'package:xtask/src/validate.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xtask_validate_'));
  tearDown(() => root.deleteSync(recursive: true));

  void given(List<String> paths) {
    for (final path in paths) {
      File(p.join(root.path, p.joinAll(p.posix.split(path))))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
    }
  }

  ValidationReport check(
    String yaml, {
    Set<String> verbs = const {'remove'},
    bool withFilesystem = false,
  }) => validateFile(
    parseXtaskFile(yaml),
    knownVerbs: verbs,
    sets: withFilesystem ? SetExpander(root: root.path) : null,
  );

  group('an `in:` that leaves the repository', () {
    test('is a problem --validate reports, not one only a run finds', () {
      // The set half of this fence was already reachable from here through
      // `_checkSetsExpand`, so leaving `in:` to resolve time made one boundary
      // answer at two moments: `--validate` said nothing wrong and `--dry-run`
      // refused the same file.
      for (final where in ['../..', '/etc', r'..\..', r'\\server\share']) {
        final report = check(
          'version: 1\ntasks:\n'
          '  a: {desc: x, in: "${where.replaceAll(r'\', r'\\')}", '
          'run: [dart]}\n',
        );
        expect(
          report.problems.map((p) => p.toString()).join('\n'),
          contains('reaches outside the repository'),
          reason: where,
        );
      }
    });
  });

  group('a file with nothing wrong', () {
    test('reports nothing', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart, analyze]}\n'
        '  check: {desc: y, collects: check}\n',
      );
      expect(report.ok, isTrue, reason: report.toString());
      expect(report.problems, isEmpty);
    });
  });

  group('a task that does nothing', () {
    test('is refused', () {
      final report = check('version: 1\ntasks:\n  idle: {desc: x}\n');
      expect(report.problems, hasLength(1));
      expect(report.toString(), contains('running it does nothing'));
    });

    test('but a composite that gathers a gate set is fine', () {
      final report = check(
        'version: 1\ntasks:\n  check: {desc: x, collects: check}\n',
      );
      expect(report.ok, isTrue);
    });

    test('and so is one that only depends on others', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  all: {desc: x, needs: [a]}\n'
        '  a: {desc: y, run: [dart]}\n',
      );
      expect(report.ok, isTrue);
    });
  });

  group('a verb nobody has', () {
    test('is refused, and the known ones are listed', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, do: ghost}\n',
        verbs: {'remove', 'regen'},
      );
      expect(report.toString(), contains('neither built in nor registered'));
      expect(report.toString(), contains('regen, remove'));
    });

    test('a registered one passes', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, do: regen}\n',
        verbs: {'regen'},
      );
      expect(report.ok, isTrue);
    });
  });

  group('a name that refers to nothing', () {
    test('`each:` naming a missing set', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, each: ghost, run: [dart]}\n',
      );
      expect(report.toString(), contains('there is no set called `ghost`'));
    });

    test('`argv-from:` naming a missing set', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, argv-from: ghost, run: [dart]}\n',
      );
      expect(report.toString(), contains('there is no set called `ghost`'));
    });

    test('`needs:` naming a missing task', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, needs: [ghost]}\n',
      );
      expect(report.toString(), contains('there is no such task'));
    });

    test('`then:` naming a missing task', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, run: [dart], then: [ghost]}\n',
      );
      expect(report.toString(), contains('there is no such task'));
    });
  });

  group('cycles', () {
    test('are found, with the ring spelled out', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, needs: [b]}\n'
        '  b: {desc: y, needs: [a]}\n',
      );
      expect(report.toString(), contains('a → b → a'));
    });

    test('a ring nothing depends on is still found', () {
      // The reason every task is planned rather than one entry point: a cycle
      // off to the side is invisible to a run and fatal the day something
      // reaches it.
      final report = check(
        'version: 1\ntasks:\n'
        '  main: {desc: x, run: [dart]}\n'
        '  orphan-a: {desc: y, needs: [orphan-b]}\n'
        '  orphan-b: {desc: z, needs: [orphan-a]}\n',
      );
      expect(report.toString(), contains('orphan-a → orphan-b → orphan-a'));
    });

    test('one ring is reported once, not once per member', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, needs: [b]}\n'
        '  b: {desc: y, needs: [c]}\n'
        '  c: {desc: z, needs: [a]}\n',
      );
      expect(report.problems, hasLength(1));
    });
  });

  group('an orphan gate is a task that believes it is checked', () {
    test('a gate nothing collects is refused', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, gate: [ci-web], run: [dart]}\n'
        '  check: {desc: y, collects: check}\n',
      );
      expect(report.toString(), contains('no task collects it'));
      expect(report.toString(), contains('looks checked and is not'));
      expect(report.toString(), contains('Collected: check'));
    });

    test('every gate a task claims is checked, not just the first', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, gate: [check, ci-web, ci-test], run: [dart]}\n'
        '  check: {desc: y, collects: check}\n',
      );
      expect(report.problems, hasLength(2));
    });

    test('a gate that is collected passes', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, gate: [ci-web], run: [dart]}\n'
        '  ci-web: {desc: y, collects: ci-web}\n',
      );
      expect(report.ok, isTrue, reason: report.toString());
    });
  });

  group('a set that matches nothing', () {
    test('is caught without running any task', () {
      given(['lib/a.dart']);
      final report = check(
        'version: 1\n'
        "sets:\n  srcs: {include: ['**/*.lake']}\n"
        'tasks:\n  a: {desc: x, argv-from: srcs, run: [dart]}\n',
        withFilesystem: true,
      );
      expect(report.toString(), contains('is empty'));
    });

    test('a set that matches is fine', () {
      given(['a.lake']);
      final report = check(
        'version: 1\n'
        "sets:\n  srcs: {include: ['**/*.lake']}\n"
        'tasks:\n  a: {desc: x, argv-from: srcs, run: [dart]}\n',
        withFilesystem: true,
      );
      expect(report.ok, isTrue, reason: report.toString());
    });

    test('without a filesystem the check is simply not done', () {
      // Stated as behaviour so that nobody reads a clean report from a
      // filesystem-less run as proof the globs match something.
      final report = check(
        'version: 1\n'
        "sets:\n  srcs: {include: ['**/*.lake']}\n"
        'tasks:\n  a: {desc: x, argv-from: srcs, run: [dart]}\n',
      );
      expect(report.ok, isTrue);
    });
  });

  group('everything wrong at once, rather than the first thing', () {
    // The departure from the parser, and the reason for it: §8 calls this the
    // first gate a project adopts, and a gate that takes five runs to list
    // five problems is one people stop running.
    late final ValidationReport report;

    setUpAll(() {
      report = validateFile(
        parseXtaskFile(
          'version: 1\ntasks:\n'
          '  idle: {desc: does nothing}\n'
          '  ghost-verb: {desc: y, do: nope}\n'
          '  ghost-set: {desc: z, argv-from: nowhere, run: [dart]}\n'
          '  orphan: {desc: w, gate: [nobody], run: [dart]}\n'
          '  ring-a: {desc: v, needs: [ring-b]}\n'
          '  ring-b: {desc: u, needs: [ring-a]}\n',
        ),
        knownVerbs: const {'remove'},
      );
    });

    test('all five are reported in one run', () {
      expect(report.problems, hasLength(5), reason: report.toString());
    });

    test('and each names its own task', () {
      final text = report.toString();
      // A cycle names its members bare, as a chain: `a` → `b` → `a` would be
      // noise around the one thing the line is for.
      for (final name in ['idle', 'ghost-verb', 'ghost-set', 'orphan']) {
        expect(text, contains('`$name`'), reason: name);
      }
      expect(text, contains('ring-a → ring-b → ring-a'));
    });

    test('and each carries the line it was written on', () {
      // Only possible because the model carries spans. Every one of these is
      // raised after parsing, which is exactly the case that used to say
      // "somewhere in your file".
      for (final problem in report.problems) {
        expect(problem.span, isNotNull, reason: problem.message);
      }
      expect(report.toString(), contains('line 3'));
    });
  });
}
