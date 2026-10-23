/// The read-only view a project's own entry point asks in-process.
///
/// Imported from `package:xtask/xtask.dart` and nowhere deeper, because the
/// point of these functions is that a project can reach them: a test that
/// imported `src/` would pass the day the export went missing.
///
/// Every answer is held against what `--gate-members` says for the same file,
/// members and refusals both. The two are one implementation, and these tests
/// are what notices the day somebody makes them two again.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/cli.dart' show runCli;
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/process.dart';
import 'package:xtask/src/request.dart' show xtaskFileName;
import 'package:xtask/xtask.dart';

import 'helpers.dart';

void main() {
  late Directory root;

  setUp(() => root = tempRepo('reading'));

  void writeFile(String yaml) =>
      File(p.join(root.path, xtaskFileName)).writeAsStringSync(yaml);

  /// What `xtask --gate-members [gate]` prints and refuses, from [from].
  Future<({int code, List<String> out, List<String> err})> cli(
    String gate, {
    String? from,
  }) async {
    final out = <String>[];
    final err = <String>[];
    final code = await runCli(
      ['--gate-members', gate],
      workingDirectory: from ?? root.path,
      environment: const {},
      out: out.add,
      err: err.add,
      resolver: ExecutableResolver(
        environment: const {'PATH': '/bin'},
        windows: false,
        isRunnable: (_) => true,
      ),
      starter: SystemProcessStarter(),
    );
    return (code: code, out: out, err: err);
  }

  /// The refusal [gateMembers] throws for [gate], as a person reads it.
  String thrown(String gate, {String? from}) {
    try {
      gateMembers(gate, workingDirectory: from ?? root.path);
    } on XtaskFormatException catch (e) {
      return '$e';
    }
    fail('expected a refusal, got none');
  }

  const lake = '''
version: 1
gates: [check, ci-web]
tasks:
  zebra: {desc: cheap, gate: [check], run: [dart]}
  web: {desc: browser, gate: [ci-web], run: [dart]}
  alpha: {desc: slow, gate: [check, ci-web], run: [dart]}
''';

  group('findRoot', () {
    test('is the directory holding the file, found from below it', () {
      writeFile(lake);
      final deep = Directory(p.join(root.path, 'packages', 'lake'))
        ..createSync(recursive: true);
      expect(findRoot(deep.path), p.absolute(root.path));
    });

    test('and null where there is none, rather than a guess', () {
      expect(findRoot(root.path), isNull);
    });
  });

  group('gateMembers', () {
    test("answers what `--gate-members` prints, in the file's order", () async {
      writeFile(lake);
      final deep = Directory(p.join(root.path, 'sub'))..createSync();
      for (final gate in ['check', 'ci-web']) {
        final printed = await cli(gate, from: deep.path);
        expect(printed.code, ExitCode.success);
        expect(
          gateMembers(gate, workingDirectory: deep.path),
          printed.out,
          reason: 'the members of `$gate`',
        );
      }
      expect(gateMembers('check', workingDirectory: root.path), [
        'zebra',
        'alpha',
      ]);
    });

    group('refuses with the words `--gate-members` refuses with', () {
      Future<void> same(String gate) async {
        final printed = await cli(gate);
        expect(printed.code, ExitCode.invalidFile);
        expect(printed.out, isEmpty);
        expect(thrown(gate), printed.err.join('\n'));
      }

      test('when there is no file here or above', () async {
        await same('check');
        expect(thrown('check'), contains('no `$xtaskFileName`'));
      });

      test('when the file cannot be read', () async {
        writeFile(lake);
        final file = File(p.join(root.path, xtaskFileName));
        Process.runSync('chmod', ['000', file.path]);
        addTearDown(() => Process.runSync('chmod', ['644', file.path]));
        // Somebody for whom a mode is no obstacle reads it anyway, and then
        // there is no unreadable file to test.
        try {
          file.readAsStringSync();
          markTestSkipped('this user reads a file with mode 000');
          return;
        } on FileSystemException {
          // As intended.
        }
        await same('check');
        expect(thrown('check'), contains('cannot read'));
      }, testOn: '!windows');

      test('when the file does not parse', () async {
        writeFile('version: 1\ntasks:\n  a: {desc: x, colour: red}\n');
        await same('check');
      });

      test('when the gate set is not declared, with the near name', () async {
        writeFile(lake);
        await same('chek');
        expect(thrown('chek'), contains('did you mean `check`?'));
      });
    });
  });
}
