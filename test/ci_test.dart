import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/parse.dart';
import 'package:xtask/src/report.dart' hide workflow;
import 'package:xtask/src/report.dart' as report show workflow;

import 'helpers.dart';

void main() {
  _judgeTable();
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
  List<String> said([String yaml = lake]) => refusals(check(yaml));

  /// One workflow with one job holding [steps], written out.
  void steps(String steps) => workflow('ci.yml', '''
jobs:
  a:
    steps:
$steps
''');

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
      final found = check();
      expect(found.ok, isTrue);
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
      expect(found.invocations.first.step.job, 'analyze');
    });

    test('a `uses:` step is not a shell step and is left alone', () {
      steps('''
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart run :xtask ci-analyze
''');
      expect(check().problems, isEmpty);
    });

    test('a step that names a command is the duplicate list growing back', () {
      steps('''
      - run: dart analyze --fatal-infos
''');
      final found = check();
      expect(found.ok, isFalse);
      expect(said().single, contains('dart analyze --fatal-infos'));
      expect(said().single, contains('job `a`'));
      expect(said().single, contains('belongs in the task file'));
    });

    test("how xtask is reached is the project's business", () {
      for (final spelling in [
        'xtask',
        './xtask',
        'dart run :xtask',
        'dart run xtask:xtask',
        'dart run bin/xtask.dart',
        'dart bin/xtask.dart',
        'dart run --enable-asserts :xtask',
        r'.\xtask.exe',
        r'tool\xtask.bat',
      ]) {
        steps('''
      - run: $spelling ci-analyze
''');
        final found = check();
        expect(found.problems, isEmpty, reason: '$spelling: ${said()}');
        expect(found.invocations.single.gate, 'ci-analyze', reason: spelling);
      }
    });

    test('a mention that is not in command position is a command', () {
      // The silent green this rule exists against: a banner that names a gate
      // set is not a job running it, and neither is a step that copies the
      // binary somewhere. Telling `echo` from `timeout` from `sh -c` means
      // knowing what every program does with its arguments, so none of them
      // is read — a prefix has a key of its own, on the task or on the step.
      for (final command in [
        'echo run xtask ci-analyze',
        'echo "run xtask ci-analyze"',
        'cp ./xtask /usr/local/bin',
        'timeout 600 ./xtask ci-analyze',
        'sh -c "dart run :xtask ci-analyze"',
        'cd sub && dart run :xtask ci-analyze',
        'dart analyze && dart run :xtask ci-analyze',
        'dart run :xtask ci-analyze && dart analyze',
      ]) {
        steps('''
      - run: $command
''');
        final found = check();
        expect(found.invocations, isEmpty, reason: command);
        expect(found.problems.single, isA<RunsACommand>(), reason: command);
      }
    });

    test('and `working-directory:` is how a step moves, not `cd`', () {
      steps('''
      - run: dart run :xtask ci-analyze
        working-directory: packages/lake
''');
      expect(check().invocations.single.gate, 'ci-analyze');
    });

    test('flags after the name are allowed, in every spelling', () {
      // The checker and the command line accept the same spellings, because
      // it is the command line's parser that reads them.
      for (final written in [
        'ci-analyze --keep-going -j 4',
        'ci-analyze -j4',
        'ci-analyze --jobs=8',
        '--keep-going ci-analyze',
        '-j auto ci-analyze',
        'ci-analyze -j "2"',
        "ci-analyze -j '2'",
      ]) {
        steps('''
      - run: dart run :xtask $written
''');
        final found = check();
        expect(found.problems, isEmpty, reason: '$written: ${said()}');
        expect(found.invocations.single.gate, 'ci-analyze', reason: written);
      }
    });

    test('a step the command line would refuse is refused in its words', () {
      for (final command in [
        'dart run :xtask ci-analyze -j abc',
        'dart run :xtask ci-analyze -j',
        'dart run :xtask ci-analyze --keep-going=true',
        'dart run :xtask ci-analyze -j=4',
        'dart run :xtask ci-analyze ci-web',
        'dart run :xtask ci-analyze -- --name x',
        'dart run :xtask ci-analyze -',
      ]) {
        steps('''
      - run: $command
''');
        final found = check();
        expect(found.invocations, isEmpty, reason: command);
        expect(
          found.problems.single,
          isA<RunsSomethingRefused>(),
          reason: command,
        );
        expect(
          said().single,
          isNot(contains('belongs in the task file')),
          reason: command,
        );
      }
      steps('''
      - run: dart run :xtask ci-analyze -j abc
''');
      expect(said().single, contains('is not a number of jobs'));
    });

    test('a mode that names a gate set is not running it', () {
      steps('''
      - run: dart run :xtask --dry-run ci-analyze
''');
      final found = check();
      expect(found.invocations, isEmpty);
      expect(found.problems.single, isA<NamesAGateWithoutRunningIt>());
      final problem = said().single;
      expect(problem, contains('`ci-analyze`'));
      expect(problem, contains('--dry-run'));
      expect(problem, contains('run nothing of it'));
    });

    test('but a mode that names nothing is a question, not a problem', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask --validate
      - run: dart run :xtask --check-ci
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.questions.map((q) => q.mode), ['--validate', '--check-ci']);
      expect(
        report.workflow(found),
        contains(contains('asks `--validate`, which is a question')),
      );
    });

    test('a gate set the file does not declare is a typo, named as one', () {
      steps('''
      - run: dart run :xtask ci-analize
''');
      final found = check();
      expect(found.ok, isFalse);
      expect(found.invocations, isEmpty);
      expect(said().single, contains('`ci-analize`'));
      expect(said().single, contains('ci-analyze'));
    });

    test('a step with an `if:` is counted, and its condition is shown', () {
      // Whether the condition holds is the workflow's business. What must not
      // happen is a job that runs the gate only sometimes being reported
      // exactly like one that always does.
      steps('''
      - run: dart run :xtask ci-analyze
        if: github.event_name == 'push'
      - run: dart run :xtask ci-web
        if: false
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
      final lines = report.workflow(found);
      expect(lines[0], endsWith("when `github.event_name == 'push'`"));
      expect(lines[1], endsWith('when `false`'));
    });

    test('a step holding an expression is reported, not guessed at', () {
      steps(r'''
      - run: dart run :xtask ${{ matrix.gate }}
''');
      final found = check();
      expect(found.invocations, isEmpty);
      expect(found.problems.single, isA<RunsAnExpression>());
      expect(said().single, contains('cannot read'));
    });

    test('a script is reported, whatever it holds', () {
      // A script is not read, because reading it means reading shell — and
      // every reading of shell is a way in. A heredoc holding an invocation,
      // a gate set behind an `echo`, a gate set in front of a command: all of
      // them are one finding, the same finding, with nothing counted as run.
      for (final block in [
        '''
          echo starting
          dart run :xtask ci-analyze''',
        '''
          dart run :xtask ci-analyze
          dart analyze''',
        '''
          cat > s.sh <<EOF
          dart run :xtask ci-analyze
          EOF''',
      ]) {
        steps('''
      - run: |
$block
''');
        final found = check();
        expect(found.invocations, isEmpty, reason: block);
        expect(found.problems.single, isA<RunsAScript>(), reason: block);
        expect(said().single, contains('a script of'), reason: block);
      }
    });

    test('but a block holding one command line is that command line', () {
      steps(r'''
      - run: |
          dart run :xtask ci-analyze
      - run: |
          dart run :xtask \
            ci-web
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.invocations.map((i) => i.gate), ['ci-analyze', 'ci-web']);
    });
  });

  group('the exemption marker', () {
    test('on the `run:` line excuses a command, and is printed with why', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: npx playwright install --with-deps # xtask: not a gate — the browser driver, which no action installs
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(
        found.exempted.single.command,
        'npx playwright install --with-deps',
      );
      expect(
        report.workflow(found),
        contains(
          contains(
            'job `a` exempts `npx playwright install --with-deps` — the '
            'browser driver, which no action installs',
          ),
        ),
      );
    });

    test('and after the `|` excuses a whole script', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: | # xtask: not a gate - the setup script
          npm ci
          npm run build
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.exempted.single.exemption, 'the setup script');
    });

    test('and excuses an expression the checker cannot read', () {
      steps(r'''
      - run: dart run :xtask ci-analyze
      - run: ${{ matrix.setup }} # xtask: not a gate - per-platform setup
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.exempted, hasLength(1));
    });

    test('is read on a step that has a `name:`, like most steps do', () {
      steps('''
      - name: the gate
        run: dart run :xtask ci-analyze
      - name: the driver
        run: npx playwright install # xtask: not a gate — the driver
''');
      final found = check();
      expect(found.problems, isEmpty, reason: '${refusals(found)}');
      expect(found.exempted.single.exemption, 'the driver');
    });

    test('and is read nowhere else', () {
      // One placement. A marker on the line above was found by the step below
      // a step it was written for, and a marker inside a script belonged to
      // the script; both were rules about which line belongs to what, and
      // each was one more place to be wrong.
      steps('''
      - run: dart run :xtask ci-analyze
      # xtask: not a gate — the driver
      - run: npx playwright install
      - run: |
          # xtask: not a gate — the banner
          echo starting
''');
      final found = check();
      expect(found.exempted, isEmpty);
      expect(found.problems.map((p) => p.runtimeType), [
        RunsACommand,
        RunsAScript,
      ]);
    });

    test('inside a quoted string is what the step prints', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: "echo '# xtask: not a gate - pretend'"
''');
      final found = check();
      expect(found.exempted, isEmpty);
      expect(found.problems.single, isA<RunsACommand>());
    });

    test('with no reason is refused, and excuses nothing', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: npx playwright install # xtask: not a gate
''');
      final found = check();
      expect(found.exempted, isEmpty);
      expect(found.problems.map((p) => p.runtimeType), [
        ExemptsWithoutSaying,
        RunsACommand,
      ]);
      expect(said().first, contains('gives no reason'));
    });

    test(
      'on a step that runs a gate set excuses nothing, and it still runs',
      () {
        steps('''
      - run: dart run :xtask ci-analyze # xtask: not a gate — no need
''');
        final found = check();
        expect(found.problems.single, isA<ExemptsNothing>());
        expect(said().single, contains('excuses nothing'));
        // The job runs it whatever the marker claims, so it is not unrun.
        expect(found.invocations.single.gate, 'ci-analyze');
        expect(found.unrun, ['ci-web']);
      },
    );

    test('does not silence a misspelled gate set', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask ci-analyse # xtask: not a gate — legacy
''');
      final found = check();
      expect(found.problems.map((p) => p.runtimeType), [
        RunsAnUndeclaredGate,
        ExemptsNothing,
      ]);
      expect(found.exempted, isEmpty);
    });

    test('does not silence what the command line refuses', () {
      steps('''
      - run: dart run :xtask ci-analyze -j abc # xtask: not a gate — flaky
''');
      expect(check().problems.map((p) => p.runtimeType), [
        RunsSomethingRefused,
        ExemptsNothing,
      ]);
    });

    test('does not silence a mode that names a gate set', () {
      // Both facts. The marker used to replace the first finding, so the
      // reader was told about a marker and never that the job runs nothing
      // of the gate it names.
      steps('''
      - run: dart run :xtask --dry-run ci-analyze # xtask: not a gate — debug
''');
      expect(check().problems.map((p) => p.runtimeType), [
        NamesAGateWithoutRunningIt,
        ExemptsNothing,
      ]);
    });

    test('on a question excuses nothing', () {
      steps('''
      - run: dart run :xtask ci-analyze
      - run: dart run :xtask --validate # xtask: not a gate — just a check
''');
      final found = check();
      expect(found.problems.single, isA<ExemptsNothing>());
      expect(found.questions, isEmpty);
    });
  });

  group('a gate set no job runs is reported, not refused', () {
    test('because it is right for a human entry point', () {
      steps('''
      - run: dart run :xtask ci-analyze
''');
      final found = check();
      expect(found.ok, isTrue);
      expect(found.unrun, ['ci-web']);
    });

    test("an empty gate is not counted — that is validate's complaint", () {
      steps('''
      - run: dart run :xtask ci-analyze
''');
      final found = check('''
version: 1
gates: [ci-analyze, ci-web]
tasks:
  analyze: {desc: a, gate: [ci-analyze], run: [dart, analyze]}
''');
      expect(found.unrun, isEmpty);
    });
  });

  group('there has to be something to check', () {
    test('no workflow directory is refused, not passed', () {
      expect(
        refusalOf(check),
        contains('there is no `.github/workflows`'),
      );
    });

    test('a workflow that never invokes xtask is refused', () {
      steps('''
      - uses: actions/checkout@v4
''');
      expect(refusalOf(check), contains('nothing under `.github/workflows`'));
    });

    test('and one that only asks questions is refused in different words', () {
      steps('''
      - run: dart run :xtask --check-ci
''');
      expect(refusalOf(check), contains('runs a gate set'));
    });

    test('and one whose every step is exempted is refused too', () {
      // The marker cannot stand in for the invocation.
      steps('''
      - run: npm ci # xtask: not a gate — deps
''');
      expect(refusalOf(check), contains('nothing under `.github/workflows`'));
    });

    test('a workflow that is not YAML is refused with its name', () {
      workflow('ci.yml', 'jobs: [\n');
      expect(refusalOf(check), contains('ci.yml'));
    });

    test('a file that is not a workflow is passed over', () {
      workflow('README.md', 'not yaml at all: [');
      steps('''
      - run: dart run :xtask ci-analyze
''');
      expect(check().ok, isTrue);
    });

    test('workflows are read in a stable order', () {
      workflow('b.yml', '''
jobs:
  b:
    steps:
      - run: dart run :xtask ci-web
''');
      workflow('a.yml', '''
jobs:
  a:
    steps:
      - run: dart run :xtask ci-analyze
''');
      expect(check().invocations.map((i) => i.step.workflow), [
        '.github/workflows/a.yml',
        '.github/workflows/b.yml',
      ]);
    });
  });
}

/// [judge] on its own, with steps built by hand.
///
/// The classification needs no directory and no file, and a table says the
/// rule more plainly than a workflow per row would.
void _judgeTable() {
  group('judge', () {
    const declared = {'check', 'release'};
    CiStep step(String command, {String? exemption}) =>
        CiStep('ci.yml', 'job', command, exemption: exemption);

    test('the readings', () {
      expect(judge(step('xtask check'), declared, const {}).gate, 'check');
      expect(
        judge(step('xtask --list'), declared, const {}).question,
        '--list',
      );
      expect(
        judge(step('npm ci', exemption: 'deps'), declared, const {}).exempted,
        isTrue,
      );
      expect(
        judge(step('npm ci'), declared, const {}).problems.single,
        isA<RunsACommand>(),
      );
      expect(
        judge(step('xtask chekc'), declared, const {}).problems.single,
        isA<RunsAnUndeclaredGate>(),
      );
      expect(
        judge(step('xtask check -j x'), declared, const {}).problems.single,
        isA<RunsSomethingRefused>(),
      );
      expect(
        judge(
          step('xtask --dry-run check'),
          declared,
          const {},
        ).problems.single,
        isA<NamesAGateWithoutRunningIt>(),
      );
      expect(
        judge(step('a\nb'), declared, const {}).problems.single,
        isA<RunsAScript>(),
      );
      expect(
        judge(
          step(r'xtask ${{ matrix.gate }}'),
          declared,
          const {},
        ).problems.single,
        isA<RunsAnExpression>(),
      );
    });

    test('a marker is one fact, and what it stands over is another', () {
      expect(
        judge(step('npm ci', exemption: ''), declared, const {}).problems.map(
          (p) => p.runtimeType,
        ),
        [ExemptsWithoutSaying, RunsACommand],
      );
      expect(
        judge(
          step('xtask chekc', exemption: 'old'),
          declared,
          const {},
        ).problems.map((p) => p.runtimeType),
        [RunsAnUndeclaredGate, ExemptsNothing],
      );
    });

    test('and a step naming a task is told what it actually runs', () {
      // **Not the undeclared-gate sentence, which is untrue about it.** That
      // one says the job runs nothing; this job runs the task, correctly
      // spelt. What is wrong is the shape: a member named where the list
      // belongs, so the next task added to the gate is one no job runs.
      final it = judge(step('xtask format'), declared, const {'format'});
      expect(it.problems.single, isA<RunsATaskNotAGate>());
      expect(it.gate, isNull);
    });
  });
}
