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
    Map<String, String> environment = const {},
  ]) => projectEntry(
    args,
    workingDirectory: directory,
    environment: environment,
  );

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
      ['run', p.join(root, 'bin', 'xtask.dart'), 'check'],
      null,
    ]);
  });

  test('a package of the same name elsewhere is not the root', () {
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    // `shop` here is a copy one directory up from `console`, not the root.
    resolution(app, {'shop': 'vendor/shop'});

    expect(entryFrom(app)?.arguments.take(2), [
      'run',
      p.join(root, 'bin', 'xtask.dart'),
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
      'repository, completion, and a run already handed over here', () {
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

    expect(
      entryFrom(root, ['check'], {projectEntryVariable: root}),
      isNull,
      reason: 'handed over once already',
    );
    expect(
      entryFrom(root, ['check'], {projectEntryVariable: p.dirname(root)}),
      isNotNull,
      reason: 'handed over for another root: this one is nested in it',
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
}
