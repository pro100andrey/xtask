import 'dart:async';
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

  /// When [resolution] says its resolution was got: an hour from now, so
  /// that every `pubspec.yaml` a test writes is older than it, whichever
  /// order the test writes them in, unless the test [touch]es one later.
  final resolved = DateTime.now().add(const Duration(hours: 1));

  /// A package resolution in [directory], naming each of [packages] — name
  /// to its root, relative to [directory] — with the `pubspec.lock` beside
  /// it, both written at [resolved]: as a `pub get` that changed the
  /// resolution leaves them. One that changed nothing writes neither, which
  /// is what the fake `dart` of [fakeDart] does.
  void resolution(String directory, Map<String, String> packages) {
    File(p.join(directory, 'pubspec.lock'))
      ..createSync(recursive: true)
      ..writeAsStringSync('packages: {}\n')
      ..setLastModifiedSync(resolved);
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
      )
      ..setLastModifiedSync(resolved);
  }

  /// [file] written, or rewritten, after the resolution was got.
  void touch(String file, [String text = '']) {
    final written = File(file);
    if (!written.existsSync()) {
      written
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }
    written.setLastModifiedSync(resolved.add(const Duration(hours: 1)));
  }

  /// A `pubspec.yaml` at [directory] for a package called [name], with
  /// [more] after the name.
  void pubspec(String directory, String name, [String more = '']) {
    File(p.join(directory, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: $name\n$more');
  }

  /// A `dart` on a PATH of its own, under [root], that writes nothing: its
  /// `pub get` succeeds having changed nothing, as the real one does for a
  /// resolution that is current, and its `run` ends with [runs] — after
  /// writing a finished report to `$WRITE` where the environment names one,
  /// as a project's engine that got as far as its run would.
  ExecutableResolver fakeDart({int runs = 0}) {
    final bin = Directory(p.join(root, '.fake-bin'))..createSync();
    final dart = File(p.join(bin.path, 'dart'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = pub ]; then exit 0; fi\n'
        'if [ -n "\$WRITE" ]; then\n'
        '  printf \'{"version":1,"complete":true,"code":$runs,"tasks":[]}\' '
        '> "\$WRITE"\n'
        'fi\n'
        'exit $runs\n',
      );
    Process.runSync('chmod', ['+x', dart.path]);
    return ExecutableResolver(
      environment: {'PATH': bin.path},
      windows: false,
      isRunnable: (path) => File(path).existsSync(),
    );
  }

  ProjectEntry? entryFrom(
    String directory, [
    List<String> args = const ['check'],
  ]) => projectEntry(args, workingDirectory: directory);

  /// [entry]'s fields as a list, which compares by what is in it: a record
  /// holding a list compares the list by identity.
  List<Object?>? fields(ProjectEntry? entry) =>
      entry == null ? null : [entry.root, entry.arguments, entry.resolveIn];

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

  test('a root never resolved has a resolution got first, and is then run as '
      'a file from where the person stands', () {
    // `dart run :xtask` would resolve it too, but only in the package — the
    // run moved there, and every relative path on the command line with it.
    repository();
    final inside = Directory(p.join(root, 'packages', 'core'))
      ..createSync(recursive: true);

    final entry = entryFrom(inside.path)!;
    expect(fields(entry), [
      root,
      ['run', p.join('..', '..', 'bin', 'xtask.dart'), 'check'],
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

  test('a root never resolved is handed every path as the person wrote it, '
      'since the run stays where they stand', () {
    // `--report` and `--check-schema` are read against the working
    // directory; a run started where the person typed them reads them as
    // they meant them, `/` and all, on every platform.
    repository();
    final inside = Directory(p.join(root, 'packages', 'core'))
      ..createSync(recursive: true);
    final args = [
      'check',
      '--report',
      'out/run.json',
      '--report=out/run.json',
      '--check-schema',
      'schema/xtask.json',
    ];

    final entry = entryFrom(inside.path, args)!;
    expect(entry.arguments, [
      'run',
      p.join('..', '..', 'bin', 'xtask.dart'),
      ...args,
    ]);
  });

  test('a run started where the person stands is handed it as written', () {
    repository();
    resolution(root, {'shop': ''});

    expect(entryFrom(root, ['check', '--report', 'run.json'])?.arguments, [
      'run',
      'shop:xtask',
      'check',
      '--report',
      'run.json',
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
    resolution(root, {'shop': ''});
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

  test('a hand-over refused before the run starts leaves the report the '
      'command line asked for, as the engine refuses one', () async {
    repository();
    resolution(root, {'shop': ''});
    final at = p.join(root, 'out', 'run.json');
    final absent = ExecutableResolver(
      environment: const {'PATH': ''},
      windows: false,
      isRunnable: (_) => false,
    );
    for (final (depth, code, says) in [
      (handOverLimit, ExitCode.invalidFile, 'loop'),
      (0, ExitCode.missingTool, 'takes `dart` to run it'),
    ]) {
      File(at)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"code": 0}');
      final answered = await runProjectEntry(
        entryFrom(root, ['check', '--report', at, '--', '--report', 'x'])!,
        environment: {handOverVariable: '$depth'},
        err: (_) {},
        resolver: absent,
      );
      expect(answered, code);
      final report =
          jsonDecode(File(at).readAsStringSync()) as Map<String, Object?>;
      expect(report, containsPair('complete', true));
      expect(report, containsPair('code', code));
      expect(report, containsPair('task', 'check'));
      expect(report['why'], contains(says));
      expect(File(p.join(root, 'x')).existsSync(), isFalse);
    }
  });

  group('the signals the installed `xtask` receives', () {
    late List<ProcessSignal> sent;
    late StreamController<ProcessSignal> interrupts;
    late StreamController<ProcessSignal> terminations;

    setUp(() {
      sent = [];
      interrupts = StreamController();
      terminations = StreamController();
      // Not awaited: a controller nothing listened to never finishes
      // closing, and on Windows nothing listens for a `SIGTERM`.
      addTearDown(() {
        unawaited(interrupts.close());
        unawaited(terminations.close());
      });
    });

    Future<void> wired({required bool windows}) async {
      final watching = passSignalsOn(
        ([signal = ProcessSignal.sigterm]) {
          sent.add(signal);
          return true;
        },
        windows: windows,
        interrupts: interrupts.stream,
        terminations: terminations.stream,
      );
      addTearDown(() async {
        for (final watch in watching) {
          await watch.cancel();
        }
      });
      interrupts.add(ProcessSignal.sigint);
      if (!windows) {
        terminations.add(ProcessSignal.sigterm);
      }
      await pumpEventQueue();
    }

    test('off Windows, reach the run as a SIGTERM', () async {
      await wired(windows: false);
      expect(sent, [ProcessSignal.sigterm, ProcessSignal.sigterm]);
    });

    test('on Windows, a Ctrl-C is only heard, and the run is not ended '
        'under itself', () async {
      // `Process.kill` on Windows ignores the signal and terminates the
      // process (the SDK documents it so): the project's engine, which the
      // console's Ctrl-C reaches as well, would be ended before it could
      // stop its run, print its summary or write its report. The interrupt
      // is listened to, so that this process outlives it, and the run ends
      // itself.
      await wired(windows: true);
      expect(interrupts.hasListener, isTrue);
      expect(sent, isEmpty);
    });
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

  test("a package that depends on the root is not the root's resolution: "
      'the file form, which the root resolves itself', () {
    // A library with `xtask` in its dev_dependencies and an `example/` that
    // depends on it by path: the example's resolution names `mylib` at the
    // root, and has none of the root's dev_dependencies in it.
    repository(name: 'mylib');
    resolution(root, {'mylib': ''});
    final example = p.join(root, 'example');
    pubspec(example, 'example', 'dependencies:\n  mylib:\n    path: ..\n');
    resolution(example, {'example': '', 'mylib': '..'});

    expect(fields(entryFrom(example)), [
      root,
      ['run', p.join('..', 'bin', 'xtask.dart'), 'check'],
      null,
    ]);
  });

  test("a workspace member's resolution is the workspace's: run by name from "
      'any package of it, and got in the member where there is none', () {
    pubspec(root, 'shop', 'workspace:\n  - packages/tools\n');
    File(p.join(root, 'xtask.yaml')).writeAsStringSync(
      'version: 1\nentry: packages/tools/bin/xtask.dart\n',
    );
    final tools = p.join(root, 'packages', 'tools');
    pubspec(tools, 'tools', 'resolution: workspace\n');
    File(p.join(tools, 'bin', 'xtask.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');

    expect(fields(entryFrom(root)), [
      root,
      ['run', p.join('packages', 'tools', 'bin', 'xtask.dart'), 'check'],
      tools,
    ], reason: 'never resolved');

    resolution(root, {'shop': '', 'tools': 'packages/tools'});
    for (final from in [root, tools]) {
      expect(fields(entryFrom(from)), [
        root,
        ['run', 'tools:xtask', 'check'],
        null,
      ], reason: from);
    }

    touch(p.join(tools, 'pubspec.yaml'));
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});
    expect(
      entryFrom(app)?.resolveIn,
      tools,
      reason: "a member's pubspec.yaml edited since: got again",
    );
  });

  test('a resolution older than what it was got from is got again before '
      'the file form runs, as `dart run` would for the name form', () {
    // `dart run <file>` does not look whether the resolution is current, and
    // a pull that brought a new dependency would fail to compile until the
    // person ran `dart pub get` themselves.
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});
    expect(entryFrom(app)?.resolveIn, isNull, reason: 'fresh');

    for (final changed in [
      'pubspec.yaml',
      'pubspec.lock',
      'pubspec_overrides.yaml',
    ]) {
      resolution(root, {'shop': ''});
      touch(p.join(root, changed));
      expect(entryFrom(app)?.resolveIn, root, reason: '$changed newer');
      File(p.join(root, 'pubspec_overrides.yaml'))
        ..createSync()
        ..deleteSync();
    }

    resolution(root, {'shop': ''});
    File(p.join(root, 'pubspec.lock')).deleteSync();
    expect(entryFrom(app)?.resolveIn, root, reason: 'no pubspec.lock');
  });

  test('a resolution got again because a source was touched is not got '
      'again on the next run', () async {
    // `dart pub get` writes neither the lock nor the package config where
    // the resolution did not change (measured), so a lock a checkout had
    // touched stayed newer than the config, and every run paid a `pub get`.
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});
    touch(p.join(root, 'pubspec.lock'));
    final first = entryFrom(app)!;
    expect(first.resolveIn, root, reason: 'the lock is newer: got again');

    final code = await runProjectEntry(
      first,
      environment: const {},
      err: (_) {},
      resolver: fakeDart(),
    );

    expect(code, ExitCode.success);
    expect(entryFrom(app)?.resolveIn, isNull, reason: 'got, and marked so');
  }, testOn: '!windows');

  test('a project started that ends before its engine writes the report '
      "leaves that run's answer in it, not the last run's", () async {
    // An entry point that does not compile ends `dart run` with 255 before
    // the project's engine has begun the report the command line asked for.
    repository();
    resolution(root, {'shop': ''});
    final app = p.join(root, 'apps', 'console');
    resolution(app, {'console': ''});
    final at = p.join(root, 'out', 'run.json');
    Map<String, Object?> report() =>
        jsonDecode(File(at).readAsStringSync()) as Map<String, Object?>;

    for (final (runs, writes) in [(255, false), (3, true)]) {
      File(at)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"code": 0}');
      final code = await runProjectEntry(
        entryFrom(app, ['check', '--report', at])!,
        environment: {if (writes) 'WRITE': at},
        err: (_) {},
        resolver: fakeDart(runs: runs),
      );
      expect(code, runs);
      expect(report(), containsPair('complete', true), reason: '$runs');
      expect(report(), containsPair('code', runs), reason: '$runs');
      if (writes) {
        expect(report(), isNot(contains('why')), reason: "the engine's own");
      } else {
        expect(report(), containsPair('task', 'check'));
        expect(report()['why'], contains('ended with 255 before its run'));
      }
    }
  }, testOn: '!windows');

  test('a batch-file `dart` refuses a metacharacter before it gets a '
      'resolution, and names the entry point and the way round it', () async {
    // Refused afterwards, the `pub get` had already rewritten the
    // package's lock for a run that was never going to start.
    repository();
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
    expect(said.single, allOf(contains('`a&b`'), contains('bin/xtask.dart')));
    expect(said.single, contains('dart.exe'));
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

    test("a root that depends on the tools package is not the tools' "
        'resolution: the file form, with the tools resolved first', () {
      // The root's resolution names `tools` at `tools/`, and has none of the
      // tools' own dev_dependencies — `xtask` among them.
      declared('tools/bin/xtask.dart', package: 'tools', name: 'tools');
      pubspec(root, 'app', 'dev_dependencies:\n  tools:\n    path: tools\n');
      resolution(root, {'app': '', 'tools': 'tools'});
      final tools = p.join(root, 'tools');

      expect(fields(entryFrom(root)), [
        root,
        ['run', p.join('tools', 'bin', 'xtask.dart'), 'check'],
        tools,
      ]);
      expect(fields(entryFrom(tools)), [
        root,
        ['run', p.join('bin', 'xtask.dart'), 'check'],
        tools,
      ]);
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
      expect(entry.resolveIn, isNull);
    });

    test('a file in a package with no resolution has one got first', () {
      declared('tools/run.dart', package: 'tools', name: 'tasks');

      final entry = entryFrom(root)!;
      expect(entry.arguments.take(2), ['run', p.join('tools', 'run.dart')]);
      expect(entry.resolveIn, p.join(root, 'tools'));
    });

    test('a bin/xtask.dart with no resolution has one got first, and is '
        'run as a file from where the person stands', () {
      declared('tools/bin/xtask.dart', package: 'tools', name: 'tasks');

      final entry = entryFrom(root)!;
      expect(fields(entry), [
        root,
        ['run', p.join('tools', 'bin', 'xtask.dart'), 'check'],
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
