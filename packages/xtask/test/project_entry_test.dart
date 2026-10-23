import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/src/executables.dart';
import 'package:xtask/src/exit_codes.dart';
import 'package:xtask/src/project_entry.dart';

import 'helpers.dart';

/// When the installed `xtask` hands a run to the project's own entry point,
/// and how it starts it — decided from the files alone, so no `dart` is run.
void main() {
  late String root;

  /// A repository at [root]: an `xtask.yaml`, a package called [name], and
  /// a `bin/xtask.dart` unless [entry] is false.
  void repository({String name = 'shop', bool entry = true}) {
    File(p.join(root, 'xtask.yaml')).writeAsStringSync('version: 1\n');
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
    if (entry) {
      File(p.join(root, 'bin', 'xtask.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
    }
  }

  /// A package resolution in [directory], naming each of [packages] — name
  /// to its root, relative to [directory].
  void resolution(String directory, Map<String, String> packages) {
    File(p.join(directory, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final MapEntry(key: name, value: at) in packages.entries)
              {'name': name, 'rootUri': '../$at', 'packageUri': 'lib/'},
          ],
        }),
      );
  }

  ProjectEntry? entryFrom(
    String directory, [
    List<String> args = const ['check'],
  ]) => projectEntry(args, workingDirectory: directory);

  /// [entry]'s fields as a list, which compares by what is in it: a record
  /// holding a list compares the list by identity.
  List<Object?>? fields(ProjectEntry? entry) => entry == null
      ? null
      : [entry.root, entry.arguments, entry.workingDirectory];

  setUp(() {
    root = Directory(tempRepo('entry').path).resolveSymbolicLinksSync();
  });

  test('a repository with an entry point of its own is run by package name, '
      'from where the person stands, wherever in its resolution that is', () {
    repository();
    resolution(root, {'shop': ''});
    final inside = Directory(p.join(root, 'packages', 'core', 'lib'))
      ..createSync(recursive: true);

    for (final from in [root, inside.path]) {
      expect(fields(entryFrom(from, ['check', '-j', '4'])), [
        root,
        ['run', 'shop:xtask', 'check', '-j', '4'],
        null,
      ], reason: from);
    }
  });

  test('a package with a resolution of its own below the root runs the '
      "root's entry as a file, still where the person stands", () {
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});

    expect(fields(entryFrom(app)), [
      root,
      ['run', p.join('..', '..', 'bin', 'xtask.dart'), 'check'],
      null,
    ]);
  });

  test("the file form's path is relative, so nothing above the root reaches "
      "a batch file's shell", () {
    root = (Directory(p.join(root, 'Work (2024) & %x%'))..createSync()).path;
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});

    final entry = entryFrom(app, ['check'])!;
    expect(entry.arguments[1], p.join('..', '..', 'bin', 'xtask.dart'));
    expect(shellMetacharacterIn(entry.arguments), isNull);
  });

  test('a resolution that cannot be read, or names the package off this '
      'machine, is not the root: the file form, and no throw', () {
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    final config = File(p.join(app, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true);

    for (final text in [
      '{not json',
      jsonEncode({
        'packages': [
          {'name': 'shop', 'rootUri': 'https://example.com/shop/'},
        ],
      }),
    ]) {
      config.writeAsStringSync(text);
      expect(
        entryFrom(app)?.arguments[1],
        p.join('..', '..', 'bin', 'xtask.dart'),
        reason: text,
      );
    }
  });

  test('a package of the same name elsewhere is not the root', () {
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    // `shop` here is a copy one directory up from `console`, not the root.
    resolution(app, {'shop': 'vendor/shop'});

    expect(entryFrom(app)?.arguments.take(2), [
      'run',
      p.join('..', '..', 'bin', 'xtask.dart'),
    ]);
  });

  test('a root never resolved is run from the root, where `dart run` '
      'resolves it first', () {
    repository();

    expect(fields(entryFrom(root)), [
      root,
      ['run', ':xtask', 'check'],
      root,
    ]);
  });

  test('the engine answers itself: no file, no entry point, its own '
      'repository, and completion while it can read the file', () {
    expect(entryFrom(root), isNull, reason: 'no xtask.yaml');

    repository(entry: false);
    resolution(root, {'shop': ''});
    expect(entryFrom(root), isNull, reason: 'no bin/xtask.dart');

    repository(name: 'xtask');
    expect(entryFrom(root), isNull, reason: "the engine's own repository");

    repository();
    for (final args in [
      ['--names'],
      ['--completion', 'zsh'],
      ['--completion=fish'],
    ]) {
      expect(entryFrom(root, args), isNull, reason: '$args');
    }
  });

  test('`--names` goes to the project when this engine cannot read the file '
      '— one written for a newer xtask', () {
    repository();
    resolution(root, {'shop': ''});
    File(p.join(root, 'xtask.yaml')).writeAsStringSync(
      'version: 1\ntasks:\n  a:\n    run: [x]\n    from-the-future: true\n',
    );

    expect(entryFrom(root, ['--names'])?.arguments, [
      'run',
      'shop:xtask',
      '--names',
    ]);
  });

  test("what follows `--` is a task's, and decides nothing here", () {
    repository();
    resolution(root, {'shop': ''});

    expect(
      entryFrom(root, ['test', '--', '--names', '--completion'])?.arguments,
      ['run', 'shop:xtask', 'test', '--', '--names', '--completion'],
    );
  });

  test('no `dart` to start the entry point with is a missing tool', () async {
    repository();
    final said = <String>[];

    final code = await runProjectEntry(
      entryFrom(root)!,
      environment: const {},
      err: said.add,
      resolver: ExecutableResolver(
        environment: const {'PATH': ''},
        windows: false,
        isRunnable: (_) => false,
      ),
    );

    expect(code, ExitCode.missingTool);
    expect(said.single, contains('bin/xtask.dart'));
  });

  test('a `dart` that cannot be started is said, and answers 1', () async {
    repository();
    final said = <String>[];
    final nowhere = p.join(root, 'no-such-dir');

    final code = await runProjectEntry(
      entryFrom(root)!,
      environment: const {},
      err: said.add,
      resolver: ExecutableResolver(
        environment: {'PATH': nowhere},
        windows: false,
        isRunnable: (_) => true,
      ),
    );

    expect(code, ExitCode.taskFailed);
    expect(said.single, contains('could not be started'));
  });

  test('a run handed over $handOverLimit times deep is a loop, refused with '
      '2 before anything starts; one less is a run', () async {
    repository();
    final said = <String>[];
    final absent = ExecutableResolver(
      environment: const {'PATH': ''},
      windows: false,
      isRunnable: (_) => false,
    );
    Future<int> at(int depth) => runProjectEntry(
      entryFrom(root)!,
      environment: {handOverVariable: '$depth'},
      err: said.add,
      resolver: absent,
    );

    expect(await at(handOverLimit), ExitCode.invalidFile);
    expect(said.last, contains('loop'));
    expect(
      await at(handOverLimit - 1),
      ExitCode.missingTool,
      reason: 'past the check, to the lookup of `dart`',
    );
  });

  test("a batch-file `dart` refuses a metacharacter the person's command "
      'line carries', () async {
    repository();
    resolution(root, {'shop': ''});
    final said = <String>[];

    final code = await runProjectEntry(
      entryFrom(root, ['check', 'a&b'])!,
      environment: const {},
      err: said.add,
      resolver: ExecutableResolver(
        environment: const {'PATH': r'C:\dart', 'PATHEXT': '.BAT'},
        windows: true,
        isRunnable: (path) => path.toLowerCase().endsWith('dart.bat'),
      ),
    );

    expect(code, ExitCode.invalidFile);
    expect(said.single, contains('`a&b`'));
  });

  group('`entry:`', () {
    /// [file] under [root], with `entry:` naming it, and a package with
    /// [name] at [package] (from the root).
    void declared(String file, {required String package, String? name}) {
      File(p.join(root, 'xtask.yaml')).writeAsStringSync(
        'version: 1\nentry: $file\n',
      );
      File(p.joinAll([root, ...p.posix.split(file)]))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      if (name != null) {
        File(p.join(root, package, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: $name\n');
      }
    }

    test("a package's own bin/xtask.dart below the root is run by that "
        "package's name where its resolution reaches", () {
      declared('tools/bin/xtask.dart', package: 'tools', name: 'tasks');
      final tools = p.join(root, 'tools');
      resolution(tools, {'tasks': ''});

      final entry = entryFrom(tools)!;
      expect(entry.arguments, ['run', 'tasks:xtask', 'check']);
      expect(entry.entry, 'tools/bin/xtask.dart');
      expect(entry.resolveIn, isNull);

      expect(
        entryFrom(root)!.arguments,
        ['run', p.join('tools', 'bin', 'xtask.dart'), 'check'],
        reason: 'from the root, outside its resolution: the file',
      );
    });

    test('any other file is run as a file, from where the person stands', () {
      repository();
      resolution(root, {'shop': ''});
      declared('tool/xtask.dart', package: '');
      final lib = Directory(p.join(root, 'lib'))..createSync();

      final entry = entryFrom(lib.path)!;
      expect(entry.arguments, [
        'run',
        p.join('..', 'tool', 'xtask.dart'),
        'check',
      ]);
      expect(entry.workingDirectory, isNull);
      expect(entry.resolveIn, isNull);
    });

    test('a file in a package with no resolution has one got first', () {
      declared('tools/run.dart', package: 'tools', name: 'tasks');

      final entry = entryFrom(root)!;
      expect(entry.arguments.take(2), ['run', p.join('tools', 'run.dart')]);
      expect(entry.resolveIn, p.join(root, 'tools'));
    });

    test('a bin/xtask.dart with no resolution is run by `dart run :xtask` '
        'in its package', () {
      declared('tools/bin/xtask.dart', package: 'tools', name: 'tasks');

      expect(fields(entryFrom(root)), [
        root,
        ['run', ':xtask', 'check'],
        p.join(root, 'tools'),
      ]);
    });

    test('the engine answers itself where the file is not there, is in no '
        'package, or is no path it accepts', () {
      File(p.join(root, 'xtask.yaml')).writeAsStringSync(
        'version: 1\nentry: tool/xtask.dart\n',
      );
      expect(entryFrom(root), isNull, reason: 'no such file');

      declared('tool/xtask.dart', package: 'tool');
      expect(entryFrom(root), isNull, reason: 'no pubspec.yaml above it');

      File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: shop\n');
      File(p.join(root, 'xtask.yaml')).writeAsStringSync(
        'version: 1\nentry: ../tool/xtask.dart\n',
      );
      expect(entryFrom(root), isNull, reason: 'left for the parser to refuse');
    });

    test('a missing `dart` names the entry point the file names', () async {
      declared('tools/run.dart', package: 'tools', name: 'tasks');
      final said = <String>[];

      await runProjectEntry(
        entryFrom(root)!,
        environment: const {},
        err: said.add,
        resolver: ExecutableResolver(
          environment: const {'PATH': ''},
          windows: false,
          isRunnable: (_) => false,
        ),
      );
      expect(said.single, contains('`tools/run.dart`'));
    });
  });
}
