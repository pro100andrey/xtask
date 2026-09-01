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

    test('and a step that chains two gate sets runs both of them', () {
      // A chain is more commands on one line, and each of these is a gate set
      // this file declares — there is no second list of what runs anywhere in
      // it, which is the whole of what the rule protects. Read as one opaque
      // command the answer depended on the order: the gate first meant the
      // rest became its operands and the step was refused, the gate last meant
      // the first half was never looked at.
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analyze && dart run :xtask ci-web
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('but a command chained beside a gate set is still reported', () {
      // The silent green this cutting removes, and the order-dependence with
      // it: `dart analyze` is in the gate set already, and reading the line
      // whole meant it was never mentioned when it came first and reported as
      // stray operands when it came second.
      for (final step in [
        'dart analyze && dart run :xtask ci-analyze',
        'dart run :xtask ci-analyze && dart analyze',
        'npm ci; dart run :xtask ci-analyze',
      ]) {
        workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: $step
''');
        final found = check();
        expect(found.invocations.single.gate, 'ci-analyze', reason: step);
        expect(
          said().single,
          contains('belongs in the task file'),
          reason: step,
        );
      }
    });

    test('and a redirection is not a separator at all', () {
      // `2>&1` is one of the most ordinary lines in a workflow. Split on the
      // `&`, it became `dart run :xtask check 2>` and `1` — a gate counted
      // unrun and a command nobody wrote.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze 2>&1
      - run: dart run :xtask ci-web > out.txt
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('and a mention inside quotes is data, however it is written', () {
      // Three shapes of one banner, each of which used to answer differently:
      // the quote on the word before the mention, on the mention itself, and a
      // bare `run` inside the string putting the next word in command
      // position. None of them runs a gate.
      for (final step in [
        'echo "run xtask ci-analyze"',
        'echo "./xtask ci-analyze"',
        'echo "now run xtask ci-analyze to reproduce"',
      ]) {
        workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: $step
''');
        final found = check();
        expect(found.invocations, isEmpty, reason: step);
        expect(
          said().single,
          contains('belongs in the task file'),
          reason: step,
        );
      }
    });

    test('and a backslash escape does not open a quote', () {
      workflow('ci.yml', r'''
jobs:
  a:
    steps:
      - run: echo don\'t # xtask: not a gate - a banner
      - run: dart run :xtask ci-analyze
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.single.gate, 'ci-analyze');
    });

    test('and a separator inside quotes is text, not a new command', () {
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: dart run :xtask ci-analyze
      - run: echo "a && b" # xtask: not a gate - a banner
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.exempted.single.command, 'echo "a && b"');
    });

    test('and a step that only moves the shell runs nothing', () {
      // Cutting on `&&` would otherwise turn the shape this checker's own
      // history says it must accept into a report about `cd sub`. The list is
      // closed because it is what a shell does to itself, not what a program
      // might do — which is the list the invocation rule refuses to keep.
      workflow('ci.yml', '''
jobs:
  analyze:
    steps:
      - run: cd sub && dart run :xtask ci-analyze
      - run: export CI=1 && dart run :xtask ci-web
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
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
      final lines = said();
      expect(lines, hasLength(2));
      expect(lines.first, contains('is not a number of jobs'));
      // And the marker is answered too. Dropped silently, the person who
      // wrote it is never told it excused nothing.
      expect(lines.last, contains('excuses nothing'));
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
      // Both facts, not one. The marker used to REPLACE the undeclared-gate
      // finding, so the reader was told about marker placement and never that
      // `ci-analyse` is not a gate set this file has — about a job that runs
      // nothing.
      final said_ = said();
      expect(said_.any((s) => s.contains('does not declare')), isTrue);
      expect(said_.any((s) => s.contains('excuses nothing')), isTrue);
      expect(check().exempted, isEmpty);
    });

    test('and a marker with no reason is answered wherever it is written', () {
      // The reason is the whole price, and the test for it lived in the last
      // branch — so on a step that reaches xtask the reader was told the
      // marker excuses nothing and never that it says nothing.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask ci-web # xtask: not a gate
''');
      // And it excuses nothing, so the gate under it still counts as run:
      // an exemption IS its reason, and without one there is no exemption to
      // weigh — only a marker to report.
      final found = check();
      expect(said().single, contains('gives no reason'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('a block is read a line at a time, whichever order it is in', () {
      // Taken as one string, the answer depended on where the gate sat: a
      // block that echoed first was refused whole, and one that echoed AFTER
      // the gate passed — the same duplicated command, hidden by being
      // second. A line is where a command begins, which is all this needs to
      // know about a script.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: |
          echo starting
          dart run :xtask ci-analyze
      - run: |
          dart run :xtask ci-web
          dart analyze
''');
      final found = check();
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
      expect(
        said(),
        [
          contains('runs `echo starting`'),
          contains('runs `dart analyze`'),
        ],
        reason: 'both non-gate lines, in either order',
      );
    });

    test('and a marker inside a block exempts the line under it', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: |
          # xtask: not a gate — the banner CI logs are read by
          echo starting
          dart run :xtask ci-analyze
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.exempted.single.command, 'echo starting');
    });

    test('and a marker at the end of a line exempts that line', () {
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: npm ci # xtask: not a gate — deps
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(
        found.exempted.single.command,
        'npm ci',
        reason: 'the marker is a comment, not part of the command',
      );
    });

    test('but a reasonless marker beside one excuses none of it', () {
      // The hole the shared-marker flag opened: with no reason to weigh, the
      // whole block vanished — no finding, no exemption, nothing said. The
      // cheapest way there has ever been to turn a red gate green.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: |  # xtask: not a gate
          npm ci
          npm run build
''');
      final found = check();
      expect(found.exempted, isEmpty);
      expect(said().where((s) => s.contains('gives no reason')), hasLength(1));
      expect(
        said().where((s) => s.contains('belongs in the task file')),
        hasLength(2),
        reason: 'both lines of the block are unexcused',
      );
    });

    test('a marker beside `run:` covers every line of its block', () {
      // A block is one step, and the marker beside the key is about the step.
      // Read only for the first line it exempted `npm ci` and reported `npm
      // run build` under the same marker, so a multi-line setup script could
      // not be exempted at all — in the one place the author would obviously
      // write it.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: | # xtask: not a gate - the setup script
          npm ci
          npm run build
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.exempted.map((s) => s.command), [
        'npm ci',
        'npm run build',
      ]);
    });

    test('but a marker inside a quoted string exempts nothing', () {
      // The two readings of one `#` disagreed: the argv was cut by a scan that
      // tracked quotes and the exemption was found with `indexOf` over the raw
      // line, so a step could exempt itself by PRINTING the marker — and the
      // disagreement resolved in the direction that turns a finding into a
      // pass. `ExemptsNothing` and `ExemptsWithoutSaying` are both about a
      // marker that does not mean what it looks like; this was the third way.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: |
          echo '# xtask: not a gate - pretend'
''');
      final found = check();
      expect(found.exempted, isEmpty);
      expect(found.problems, isNotEmpty);
      expect(said().single, contains('pretend'));
    });

    test(
      'and a trailing marker in a block does not reach the line under it',
      () {
        workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: |
          npm ci # xtask: not a gate — deps
          dart analyze
''');
        expect(check().exempted, hasLength(1));
        expect(said().single, contains('dart analyze'));
      },
    );

    test('and a line continuation is one command, not two', () {
      workflow('ci.yml', r'''
jobs:
  a:
    steps:
      - run: |
          dart run :xtask \
            ci-analyze
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.single.gate, 'ci-analyze');
    });

    test('and a prefix it has never heard of is still an invocation', () {
      // Position was the only test, and a whitelist of six runner words is a
      // list that is never finished: `timeout`, `xvfb-run`, `cd … &&` and even
      // the plain `dart bin/xtask.dart` were each told to move a gate set that
      // is already in the task file.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: timeout 600 ./xtask ci-analyze
      - run: dart bin/xtask.dart ci-web
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });

    test('and a mention that names one INSIDE quotes still is', () {
      // Quotes come off before the parser sees the words, because `-j "2"` is
      // ordinary — so `echo "run xtask check"` parsed into a declared gate set
      // and the job was reported as running a gate that nothing in it runs.
      // A banner line reaches this, and it is the silent green the whole mode
      // exists to prevent.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: echo "run xtask ci-analyze"
''');
      final found = check();
      expect(found.invocations, isEmpty);
      expect(said().first, contains('belongs in the task file'));
    });

    test('and a command hidden in a quoted argument is not read as one', () {
      // The price of the rule, paid deliberately. `sh -c "…"` really does run
      // what is inside the quotes, and telling it from `echo "…"` means
      // knowing which programs take a command as an argument — the list this
      // module refuses to keep. So the step is answered rather than vouched
      // for: it wants a marker, or wants writing plainly. What must not happen
      // is the other direction, where a banner counts as running a gate.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: sh -c "dart run :xtask ci-web"
''');
      final found = check();
      expect(found.invocations.single.gate, 'ci-analyze');
      expect(said().single, contains('belongs in the task file'));
    });

    test('and a second mention on one line is tried when the first fails', () {
      // A repository that builds its own copy writes both on one line. Only
      // the first non-positional mention was ever tried, so this was read from
      // the `cp` and reported as a command belonging in the task file, with
      // its gate counted as unrun — about a step that runs it.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: cp ./xtask /tmp/x && ./xtask ci-analyze # xtask: not a gate - built here
      - run: dart run :xtask ci-web
''');
      final found = check();
      expect(found.problems, isEmpty, reason: refusals(found).join('\n'));
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
      // The `cp` is a command like any other and wants the marker a `cp` as
      // its own step already wants; what must not happen is the gate beside it
      // being counted unrun.
      expect(found.exempted.single.command, 'cp ./xtask /tmp/x');
    });

    test('but a mention that names no gate this file has is a command', () {
      // The other half of the same rule: what makes a prefixed step an
      // invocation is that the words after it name something real.
      workflow('ci.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
      - run: cp ./xtask /usr/local/bin
''');
      expect(said().single, contains('belongs in the task file'));
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
      // Two facts: the marker says nothing, and what it was written over is
      // therefore unexcused. Swallowing the step on the strength of a marker
      // that gives no reason is the form this grows into when it is reached
      // for to make a red gate green.
      final lines = said();
      expect(lines.any((s) => s.contains('gives no reason')), isTrue);
      expect(lines.any((s) => s.contains('belongs in the task file')), isTrue);
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
