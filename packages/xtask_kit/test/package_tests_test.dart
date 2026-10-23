import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/src/package_tests.dart';

void main() {
  group('whether a package needs Flutter', () {
    test('not when nothing it depends on is from the Flutter SDK', () {
      expect(
        usesFlutter('''
name: models
dependencies:
  meta: ^1.0.0
  flutter_lints_lookalike: ^1.0.0
dev_dependencies:
  test: ^1.0.0
'''),
        isFalse,
      );
    });

    test('when it depends on the Flutter SDK', () {
      expect(
        usesFlutter('''
name: ui
dependencies:
  flutter:
    sdk: flutter
'''),
        isTrue,
      );
    });

    test('when only its tests do, through flutter_test', () {
      expect(
        usesFlutter('''
name: storage
dependencies:
  meta: ^1.0.0
dev_dependencies:
  flutter_test:
    sdk: flutter
'''),
        isTrue,
      );
    });

    test('not for a pubspec with no dependencies at all', () {
      expect(usesFlutter('name: bare\n'), isFalse);
    });

    test('and a pubspec that is not a map is refused', () {
      expect(() => usesFlutter('- a list'), throwsFormatException);
    });
  });

  group('running', () {
    late Directory root;
    late List<String> said;
    late List<({List<String> argv, String? workingDirectory})> started;
    late int answer;

    VerbContext context({
      String? member,
      String? workingDirectory,
      List<String> args = const [],
    }) => VerbContext(
      args: args,
      env: const {},
      root: root.path,
      workingDirectory: workingDirectory ?? root.path,
      member: member,
      log: said.add,
      start: (argv, {workingDirectory}) async {
        started.add((argv: argv, workingDirectory: workingDirectory));
        return answer;
      },
    );

    void write(String path, String content) => File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    void dartPackage(String dir, {bool tests = true}) {
      write('$dir/pubspec.yaml', 'name: ${p.basename(dir)}\n');
      if (tests) {
        write('$dir/test/a_test.dart', '');
      }
    }

    void flutterPackage(String dir) {
      write(
        '$dir/pubspec.yaml',
        'name: ${p.basename(dir)}\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n',
      );
      write('$dir/test/a_test.dart', '');
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('xtask_kit_tests_');
      said = [];
      started = [];
      answer = ExitCode.success;
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('a Dart package runs dart test in its own directory', () async {
      dartPackage('packages/models');

      expect(
        await packageTests()(context(member: 'packages/models')),
        ExitCode.success,
      );
      expect(started.single.argv, ['dart', 'test']);
      expect(started.single.workingDirectory, 'packages/models');
      expect(said.single, 'packages/models: dart test');
    });

    test('a Flutter package runs flutter test', () async {
      flutterPackage('packages/ui');

      expect(
        await packageTests()(context(member: 'packages/ui')),
        ExitCode.success,
      );
      expect(started.single.argv, ['flutter', 'test']);
      expect(started.single.workingDirectory, 'packages/ui');
    });

    test("the task's arguments go to the runner", () async {
      dartPackage('packages/models');

      await packageTests()(
        context(
          member: 'packages/models',
          args: ['--reporter=failures-only', 'test/a_test.dart'],
        ),
      );
      expect(started.single.argv, [
        'dart',
        'test',
        '--reporter=failures-only',
        'test/a_test.dart',
      ]);
    });

    test('a member naming the pubspec, or a path inside the package, '
        'is that package', () async {
      dartPackage('packages/models');

      await packageTests()(context(member: 'packages/models/pubspec.yaml'));
      await packageTests()(context(member: 'packages/models/lib/src'));
      expect(started.map((s) => s.workingDirectory), [
        'packages/models',
        'packages/models',
      ]);
    });

    test("without each: it is the task's own directory", () async {
      dartPackage('packages/embed');

      await packageTests()(
        context(workingDirectory: p.join(root.path, 'packages', 'embed')),
      );
      expect(started.single.workingDirectory, 'packages/embed');
    });

    test('and with neither, the root package', () async {
      dartPackage('.');

      await packageTests()(context());
      expect(started.single.workingDirectory, '.');
    });

    test('a package without test/ is skipped, and says so', () async {
      dartPackage('packages/lints', tests: false);

      expect(
        await packageTests()(context(member: 'packages/lints')),
        ExitCode.success,
      );
      expect(started, isEmpty);
      expect(said.single, 'packages/lints: skipped, no test/');
    });

    test('a failing suite fails the task with 1, '
        'whatever number the runner gave', () async {
      dartPackage('packages/models');
      answer = 79;

      expect(
        await packageTests()(context(member: 'packages/models')),
        ExitCode.taskFailed,
      );
    });

    test('a member in no package is refused, before anything', () async {
      write('docs/readme.md', '');

      expect(
        await packageTests()(context(member: 'docs')),
        ExitCode.invalidFile,
      );
      expect(started, isEmpty);
      expect(said.single, contains('no pubspec.yaml in docs or above it'));
    });

    test('a pubspec that cannot be read is refused, naming it', () async {
      write('packages/broken/pubspec.yaml', 'name: [unclosed\n');
      write('packages/broken/test/a_test.dart', '');

      expect(
        await packageTests()(context(member: 'packages/broken')),
        ExitCode.taskFailed,
      );
      expect(started, isEmpty);
      expect(said.single, contains('packages/broken/pubspec.yaml'));
    });
  });
}
