import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/sets.dart';
import 'package:xtask/src/validate.dart';

void main() {
  group('a task that does nothing', () {
    test('is one with no body, no `needs:` and no `then:`', () {
      final report = validateFile(
        parseXtaskFile(
          'version: 1\ntasks:\n  idle: {desc: x}\n',
        ),
        knownVerbs: const {},
      );
      expect(report.ok, isFalse);
      expect('$report', contains('`idle`'));
    });

    test('and a pure continuation is not one', () {
      // `publish then verify`, `verify then notify` runs all three and answers
      // 0, while this reported the middle one as a name with a description
      // attached: a file the run accepts and the gate the README tells every
      // project to adopt refuses.
      final report = validateFile(
        parseXtaskFile(
          'version: 1\ntasks:\n'
          '  publish: {desc: a, run: [echo, up], then: [verify]}\n'
          '  verify:  {desc: b, then: [notify]}\n'
          '  notify:  {desc: c, run: [echo, done]}\n',
        ),
        knownVerbs: const {},
      );
      expect(report.ok, isTrue, reason: '$report');
    });
  });

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

  group('an `in:` composed out of values', () {
    test('is checked here too, not only when a run reaches it', () {
      // A `values:` set is exempt from the boundary — its members are not
      // paths — and `in: sub/$each` builds one out of them. Checking only the
      // written string left a file `--validate` called clean and `--dry-run`
      // refused, which is the gap this check exists to close.
      final report = check(
        'version: 1\n'
        "sets:\n  f:\n    values: [dev, '../../etc']\n"
        'tasks:\n'
        r'  a: {desc: x, each: f, in: sub/$each, run: [dart]}'
        '\n',
      );
      expect(report.toString(), contains('reaches outside the repository'));
    });

    test('and ordinary values say nothing', () {
      final report = check(
        'version: 1\n'
        'sets:\n  f:\n    values: [dev, prod]\n'
        'tasks:\n'
        r'  a: {desc: x, each: f, in: sub/$each, run: [dart]}'
        '\n',
      );
      expect(report.ok, isTrue, reason: report.toString());
    });
  });

  group('a key that guarantees nothing is said out loud', () {
    test('a token only one task holds keeps it apart from nobody', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, exclusive: [port], run: [dart]}\n',
      );
      expect(report.toString(), contains('nothing is being kept apart'));
    });

    test('and the same token twice on one task is still one holder', () {
      // Counting occurrences rather than tasks let this slip past the very
      // check it is the case for.
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, exclusive: [db, db], run: [dart]}\n',
      );
      expect(report.toString(), contains('nothing is being kept apart'));
    });

    test('and two holders are what the key is for', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, exclusive: [port], run: [dart]}\n'
        '  b: {desc: y, exclusive: [port], run: [dart]}\n',
      );
      expect(report.ok, isTrue, reason: report.toString());
    });

    test('`serial:` with no `each:` has nothing to put in order', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, serial: true, run: [dart]}\n',
      );
      expect(report.toString(), contains('nothing for it to be in order'));
    });
  });

  group('a set another task produces is not judged before it runs', () {
    test('and the file that used to be called invalid is clean', () {
      // It ran green and both `--validate` and `--dry-run` called it broken:
      // one question with three answers, and the gate §8 calls the first to
      // adopt was the one saying a working file is wrong.
      given(['build/keep/x']);
      final report = check(
        'version: 1\n'
        "sets:\n  made:\n    include: ['build/*.txt']\n"
        '    produced: true\n'
        'tasks:\n'
        '  make: {desc: p, run: [touch, build/a.txt]}\n'
        r'  use: {desc: c, needs: [make], all: made, run: [echo, $all]}'
        '\n',
        withFilesystem: true,
      );
      expect(report.ok, isTrue, reason: report.toString());
    });

    test('but a set nothing runs before is still checked', () {
      // `needs:` is a task saying out loud that something runs first. Without
      // it, an empty set is the typo the rule exists for.
      final report = check(
        'version: 1\n'
        "sets:\n  src:\n    include: ['nothing-matches/*']\n"
        'tasks:\n'
        r'  a: {desc: x, all: src, run: [echo, $all]}'
        '\n',
        withFilesystem: true,
      );
      expect(report.toString(), contains('is empty'));
    });

    test('and only its emptiness is passed over', () {
      // Skipping the whole expansion took the repository boundary with it —
      // and that fence exists because a set is fed to verbs that delete.
      final report = check(
        'version: 1\n'
        "sets:\n  made:\n    include: ['/etc/host*']\n    produced: true\n"
        'tasks:\n'
        r'  a: {desc: x, all: made, run: [echo, $all]}'
        '\n',
        withFilesystem: true,
      );
      expect(report.toString(), contains('reaches outside the repository'));
    });

    test('a pattern that is not a pattern is still reported', () {
      final report = check(
        'version: 1\n'
        "sets:\n  made:\n    include: ['[']\n    produced: true\n"
        'tasks:\n'
        r'  a: {desc: x, all: made, run: [echo, $all]}'
        '\n',
        withFilesystem: true,
      );
      expect(report.problems, isNotEmpty, reason: report.toString());
    });
  });

  group('a file with nothing wrong', () {
    test('reports nothing', () {
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart, analyze]}\n'
        '',
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
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: y, gate: [check], run: [dart]}\n',
      );
      expect(report.ok, isTrue, reason: report.toString());
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
      // One sentence for the rule, wherever it is reported. The validator and
      // the resolver had one each: this half — the list of known verbs — was
      // the validator's, and the half saying what a verb IS was the
      // resolver's. Each had learnt something the other had not.
      expect(report.toString(), contains('has not registered'));
      expect(report.toString(), contains('a Dart function'));
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
        'version: 1\ntasks:\n'
        r'  a: {desc: x, each: ghost, in: $each, run: [dart]}'
        '\n',
      );
      expect(report.toString(), contains('there is no set called `ghost`'));
    });

    test('`argv-from:` naming a missing set', () {
      final report = check(
        'version: 1\ntasks:\n  a: {desc: x, all: ghost, run: [dart, \$all]}\n',
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

  group('a gate set is declared before it is used', () {
    test('a misspelled `gate:` says what the declared names are', () {
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: x, gate: [chekc], run: [dart]}\n'
        '',
      );
      expect(report.toString(), contains('names the gate set `chekc`'));
    });

    test('a declared gate nothing is in is refused', () {
      final report = check(
        'version: 1\ngates: [check, release]\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart]}\n'
        '',
      );
      expect(report.toString(), contains('gate set `release` is declared'));
      expect(report.toString(), contains('checks nothing'));
    });

    test('using gate sets without declaring any says how to start', () {
      final report = check(
        'version: 1\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart]}\n'
        '',
      );
      expect(report.toString(), contains('`gates: [check]`'));
    });

    test('a file that neither declares nor uses gate sets is fine', () {
      // The rule is about a file that USES them. A file with no gate sets at
      // all is a legitimate file and this says nothing about it. (Declaring
      // one nothing is in is the case above, and it is a refusal.)
      final report = check('version: 1\ntasks:\n  a: {desc: x, run: [d]}\n');
      expect(report.ok, isTrue, reason: report.toString());
    });
  });

  group('a gate set and a task are two kinds of thing with one name space', () {
    test('sharing a name is refused, because a person types one word', () {
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  check: {desc: x, gate: [check], run: [dart]}\n',
      );
      expect(report.toString(), contains('both a gate set and a task'));
    });

    test('`needs:` naming a gate set says so once, and accurately', () {
      // It used to say `there is no task called \`check\`` first — false,
      // the file declares that name — and the accurate sentence second.
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart]}\n'
        '  b: {desc: y, needs: [check], run: [dart]}\n',
      );
      expect(report.problems, hasLength(1), reason: report.toString());
      expect(report.toString(), isNot(contains('there is no task')));
    });

    test('`needs:` may not name a gate set', () {
      // An edge runs between tasks. A gate set is a list, not a step, and
      // letting one be a node would give the run order two authors.
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart]}\n'
        '  b: {desc: y, needs: [check], run: [dart]}\n',
      );
      expect(report.toString(), contains('edges between tasks'));
    });

    test('`then:` may not either', () {
      final report = check(
        'version: 1\ngates: [check]\ntasks:\n'
        '  a: {desc: x, gate: [check], run: [dart]}\n'
        '  b: {desc: y, then: [check], run: [dart]}\n',
      );
      expect(report.toString(), contains('edges between tasks'));
    });
  });

  group('a set that matches nothing', () {
    test('is caught without running any task', () {
      given(['lib/a.dart']);
      final report = check(
        'version: 1\n'
        "sets:\n  srcs: {include: ['**/*.lake']}\n"
        'tasks:\n  a: {desc: x, all: srcs, run: [dart, \$all]}\n',
        withFilesystem: true,
      );
      expect(report.toString(), contains('is empty'));
    });

    test('a set that matches is fine', () {
      given(['a.lake']);
      final report = check(
        'version: 1\n'
        "sets:\n  srcs: {include: ['**/*.lake']}\n"
        'tasks:\n  a: {desc: x, all: srcs, run: [dart, \$all]}\n',
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
        'tasks:\n  a: {desc: x, all: srcs, run: [dart, \$all]}\n',
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
          'version: 1\ngates: [nobody]\ntasks:\n'
          '  idle: {desc: does nothing}\n'
          '  ghost-verb: {desc: y, do: nope}\n'
          '  ghost-set: {desc: z, all: nowhere, run: [dart, \$all]}\n'
          '  orphan: {desc: w, gate: [nobody, missing], run: [dart]}\n'
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
      expect(report.toString(), contains('line 4'));
    });
  });
}
