import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/ci.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/parse.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xtask_ci_'));
  tearDown(() => root.deleteSync(recursive: true));

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
      expect(report.problems.single, contains('dart analyze --fatal-infos'));
      expect(report.problems.single, contains('job `analyze`'));
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
      expect(report.problems.single, contains('&&'));
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
      expect(report.problems.single, contains('ci-analize'));
      expect(report.problems.single, contains('ci-analyze'));
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
