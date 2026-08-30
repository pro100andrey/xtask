import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart' hide workflow;
import 'package:xtask/src/report.dart' as report show workflow;

import 'helpers.dart';

void main() {
  late Directory root;

  setUp(() => root = tempRepo('ci'));

  void workflow(String name, String yaml) {
    File(p.join(root.path, '.github', 'workflows', name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(yaml);
  }

  const lake = '''
version: 1
gates: [ci-analyze, ci-web]
tasks:
  analyze: {desc: a, gate: [ci-analyze], run: [dart, analyze]}
  web-e2e: {desc: b, gate: [ci-web], run: [dart, test]}
''';

  CiReport check([String yaml = lake]) =>
      checkCi(parseXtaskFile(yaml), root: root.path);

  /// What a person is told about the steps that are not an invocation.
  ///
  /// The findings are values; the sentences are `report.dart`'s, which is the
  /// declared home of everything the tool says. Asserting the rendered line is
  /// asserting what somebody reads.
  List<String> said([String yaml = lake]) => refusals(check(yaml));

  group('a job runs a gate set, and nothing else', () {
    test('an invocation is recognised and reported', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - uses: actions/checkout@v4
      - run: dart run :xtask ci-analyze
  web:
    steps:
      - run: dart run :xtask ci-web
''');
      final report = check();
      expect(report.ok, isTrue);
      expect(report.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
      expect(report.invocations.first.step.job, 'analyze');
    });

    test('a `uses:` step is not a shell step and is left alone', () {
      // §7.1 leaves what must EXIST before xtask runs to the CI file, and
      // that is what actions are.
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask ci-web
''');
      expect(check().problems, isEmpty);
    });

    test('a step that names a command is the duplicate list growing back', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart analyze --fatal-infos
''');
      final report = check();
      expect(report.ok, isFalse);
      expect(said().single, contains('dart analyze --fatal-infos'));
      expect(said().single, contains('job `analyze`'));
    });

    test('and so is a step that runs a gate and then something else', () {
      // A step doing two things is a step this cannot vouch for. Both halves
      // are real gate sets on purpose: a checker that only looked at the LAST
      // word would call this fine, and the version that did was caught by a
      // mutation rather than by the first form of this test.
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analyze && dart run :xtask ci-web
''');
      final report = check();
      expect(report.ok, isFalse);
      expect(said().single, contains('&&'));
    });

    test('flags after the name are allowed; a second operand is not', () {
      // `xtask check -j 4` was refused, so §7.1 sent all parallelism to CI
      // and then forbade the one construct that provides it.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze -j 4
  b:
    steps:
      - run: dart run :xtask ci-web --keep-going
''');
      final report = check();
      expect(report.problems, isEmpty, reason: said().join('\n'));
      expect(report.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('an attached value does not swallow the gate set after it', () {
      // `-j4` has no `=`, so a rule that skipped the next word whenever a
      // flag lacked one ate the gate — on the very spelling this change
      // advertises — and called a valid workflow a step doing something else.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask -j4 ci-analyze
  b:
    steps:
      - run: dart run :xtask --jobs=2 ci-web
''');
      final report = check();
      expect(report.problems, isEmpty, reason: said().join('\n'));
      expect(report.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('a step the command line would refuse is not vouched for', () {
      // Skipping a flag's value without looking at it reported a green job
      // for a step that exits 1 the moment it runs.
      for (final command in [
        'dart run :xtask ci-analyze -j abc',
        'dart run :xtask ci-analyze -j',
        'dart run :xtask ci-analyze --keep-going=true',
        // `-j=4` is neither spelling: `--jobs=4` carries its value after an
        // `=`, `-j4` carries it joined, and the command line refuses this.
        'dart run :xtask ci-analyze -j=4',
        'dart run :xtask ci-analyze --jobs=nonsense',
      ]) {
        workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: $command
''');
        expect(check().problems, isNotEmpty, reason: command);
      }
    });

    test(
      'arguments after `--` have nothing to reach, so are not vouched for',
      () {
        // A gate set has no body, so `xtask check -- --name x` exits 2 the
        // moment it runs. The checker knows because the parser hands back a
        // `RunTask` carrying them, not because it looks for `--` itself.
        workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze -- --name x
''');
        expect(check().problems, isNotEmpty);
      },
    );

    test('the checker and the command line accept the same spellings', () {
      // The point of parsing rather than re-reading: every spelling the
      // command line takes is one a workflow may be written in, without this
      // file learning any of them.
      for (final written in [
        'ci-analyze --keep-going -j 4',
        'ci-analyze -j4',
        'ci-analyze --jobs=8',
        '--keep-going ci-analyze',
        '-j auto ci-analyze',
      ]) {
        workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask $written
''');
        expect(
          check().invocations.map((i) => i.gate),
          ['ci-analyze'],
          reason: written,
        );
      }
    });

    test("and it is refused in the command line's own words", () {
      // "What runs belongs in the task file" is the wrong sentence about a
      // step that names a gate set correctly and would still exit before
      // doing anything: it sends the reader to move a task that is already
      // where it should be. The parser has the exact sentence, so it is
      // quoted rather than guessed at.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze -j abc
''');
      final problem = said().single;
      expect(problem, contains('is not a number of jobs'));
      expect(problem, isNot(contains('belongs in the task file')));
    });

    test('a lone dash is a diagnostic, not a crash', () {
      // Reaching for a second character raised a `RangeError` out of
      // `--check-ci` rather than reporting anything.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze -
''');
      expect(check, returnsNormally);
    });

    test('a mode is not a modifier — naming a gate is not running it', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask --dry-run ci-analyze
''');
      expect(check().problems, isNotEmpty);
      // In its own words. "What runs belongs in the task file" sends a reader
      // to move a gate set that is already in the task file.
      final problem = said().single;
      expect(problem, contains('`ci-analyze`'));
      expect(problem, contains('--dry-run'));
      expect(problem, contains('run nothing of it'));
      expect(problem, isNot(contains('belongs in the task file')));
    });

    test('but a mode that names nothing is a question, not a problem', () {
      // The comment here said as much and the code answered otherwise: a mode
      // came back indistinguishable from "no xtask in this step at all", so
      // `--validate` was reported as a command belonging in the task file —
      // and so was `--check-ci`, which is the step §7.1 asks a project to add.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask --validate
      - run: dart run :xtask --check-ci
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.questions.map((q) => q.mode), ['--validate', '--check-ci']);
    });

    test('a step a person exempted is not a problem, and is named', () {
      // The rule is blanket on purpose: telling a step that installs a browser
      // driver from a step that runs the build would be classifying shell,
      // which nothing does. So the exception is written where the exception
      // is — and counted, because an exemption nobody sees is one nobody
      // revisits.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      # xtask: not a gate — the browser driver, which no action installs
      - run: npx playwright install --with-deps
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.exempted.single.command, contains('playwright'));
      expect(
        report.workflow(found).join('\n'),
        contains(
          'job `a` exempts `npx playwright install --with-deps` — the browser '
          'driver, which no action installs',
        ),
      );
    });

    test('and the marker may sit on the line of the step itself', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: docker login # xtask: not a gate — credentials, not a task
''');
      expect(check().exempted, hasLength(1));
    });

    test('but a trailing marker does not exempt the step under it', () {
      // Read as "the line above", a marker trailing one step's own line was
      // also found by the next step: `npm ci # …` exempted the `dart analyze`
      // beneath it — the duplicate list growing back, green, under somebody
      // else's reason. The line above counts only when it is nothing but a
      // comment.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: npm ci # xtask: not a gate — deps
      - run: dart analyze
''');
      expect(check().exempted, hasLength(1));
      expect(said().single, contains('dart analyze'));
    });

    test('and a marker does not silence what the command line refuses', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze -j abc # xtask: not a gate — flaky
''');
      expect(said().single, contains('is not a number of jobs'));
    });

    test('and it does not silence a misspelled gate set', () {
      // The worst of the three: a job that runs nothing, passing, because
      // somebody wrote a comment above it.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask ci-analyse # xtask: not a gate — legacy
''');
      expect(said().single, contains('excuses nothing'));
      expect(check().exempted, isEmpty);
    });

    test('and a step that only quotes something still runs its gate', () {
      // The quote guard was asked of every word in the step, so a block that
      // echoes a line before running the gate was reported as a duplicated
      // command list — about a gate already in the task file. It is asked of
      // the words being parsed, and only of unbalanced quotes.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: |
          echo "running the gates"
          dart run :xtask ci-analyze
      - run: dart run :xtask ci-web -j "2"
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('but an exemption with no reason is refused', () {
      // The reason is the whole price. Without it the marker is a way of
      // turning a red gate green that leaves nothing behind saying what for.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      # xtask: not a gate
      - run: npx playwright install
''');
      expect(said().single, contains('gives no reason'));
    });

    test('and one that exempts nothing is refused too', () {
      // A marker on a step that did not need one is how the ones that are
      // load-bearing become impossible to find.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze # xtask: not a gate — no need
''');
      expect(said().single, contains('excuses nothing'));
    });

    test('and a word wearing a quote is not read on from', () {
      // Split on whitespace, `echo "install xtask first"` gives `first"` after
      // the xtask word, which was reported as a gate set this file does not
      // declare — a sentence about a name nobody wrote.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: echo "install xtask first"
''');
      final problem = said().single;
      expect(problem, contains('belongs in the task file'));
      // The quoted command is quoted back, which is right. What is gone is
      // the claim that `first"` is a gate set name somebody wrote.
      expect(problem, isNot(contains('the gate set `first"`')));
      expect(problem, isNot(contains('does not declare')));
    });

    test('but a step doing two things is still refused', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze ci-web
''');
      expect(check().problems, isNotEmpty);
    });

    test('a gate set the file does not declare is a typo, named as one', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analize
''');
      final report = check();
      expect(report.ok, isFalse);
      expect(said().single, contains('ci-analize'));
      expect(said().single, contains('ci-analyze'));
    });

    test("how xtask is reached is the project's business", () {
      // §9 leaves the entry point to the project, so a checker that knew one
      // spelling would call a working workflow broken.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run bin/xtask.dart ci-analyze
  b:
    steps:
      - run: ./xtask ci-web
''');
      expect(check().problems, isEmpty);
      expect(check().invocations, hasLength(2));
    });
  });

  group('a gate set no job runs is reported, not refused', () {
    test('because it is right for a human entry point', () {
      // §7.1: the gate sets are the jobs PLUS the people. Nothing in the file
      // tells those apart, and a key that claimed to would be a second place
      // saying what the workflow already says.
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analyze
''');
      final report = check();
      expect(report.ok, isTrue);
      expect(report.unrun, ['ci-web']);
    });

    test("an empty gate is not counted — that is validate's complaint", () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analyze
''');
      final report = check('''
version: 1
gates: [ci-analyze]
tasks:
  analyze: {desc: a, gate: [ci-analyze], run: [dart, analyze]}
''');
      expect(report.unrun, isEmpty);
    });
  });

  group('a workflow this process cannot read is a sentence, not a crash', () {
    test('one that is not UTF-8', () {
      // Only `YamlException` was caught, so a workflow with a stray byte ended
      // `--check-ci` on a stack trace and exit 255 — from the gate the README
      // tells every project to run in CI, about the very file it was pointed
      // at.
      File(p.join(root.path, '.github', 'workflows', 'bad.yml'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([
          ...'jobs:\n  a:\n    steps:\n      - run: echo '.codeUnits,
          0xFF,
          0xFE,
          0x0A,
        ]);
      expect(check, throwsA(isA<XtaskFormatException>()));
    });

    test('and a directory that cannot be listed', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
''');
      final directory = Directory(p.join(root.path, '.github', 'workflows'));
      Process.runSync('chmod', ['000', directory.path]);
      addTearDown(() => Process.runSync('chmod', ['755', directory.path]));
      expect(check, throwsA(isA<XtaskFormatException>()));
    }, testOn: '!windows');
  });

  group('a question with no answer is refused, not answered 0', () {
    // Both of these would otherwise let a gate task asking this pass after
    // somebody deleted the CI file.
    test('no workflow directory at all', () {
      expect(check, throwsA(isA<XtaskFormatException>()));
    });

    test('a workflow that never invokes xtask', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - uses: actions/checkout@v4
''');
      expect(
        check,
        throwsA(
          isA<XtaskFormatException>().having(
            (e) => e.message,
            'message',
            contains('nothing'),
          ),
        ),
      );
    });

    test('but a workflow with a BAD step is a problem, not an absence', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: make check
''');
      expect(check().ok, isFalse);
    });
  });

  test('every workflow in the directory is read, not just one', () {
    workflow('analyze.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
''');
    workflow('web.yaml', '''
jobs:
  b:
    steps:
      - run: dart run :xtask ci-web
''');
    expect(check().invocations, hasLength(2));
    expect(check().unrun, isEmpty);
  });
}
