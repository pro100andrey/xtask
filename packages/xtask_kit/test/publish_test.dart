import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
// From `src/` until the library exports it — what this test needs is the
// verb, not where the package chooses to show it.
import 'package:xtask_kit/src/publish.dart';

const _package = PubPackage(
  'packages/demo',
  waits: [Duration.zero, Duration(seconds: 5), Duration(seconds: 10)],
);

/// What `dart pub publish --dry-run` prints for the demo package.
const _listing = '''
Resolving dependencies...
Got dependencies!
Publishing demo 1.2.0 to https://pub.dev:
├── CHANGELOG.md (<1 KB)
├── lib
│   └── demo.dart (<1 KB)
└── pubspec.yaml (<1 KB)

Total compressed archive size: <1 KB.
Validating package...
Package has 0 warnings.
''';

void main() {
  late Directory root;
  late List<String> said;
  late List<({List<String> argv, String? workingDirectory})> started;
  late List<({List<String> argv, String? workingDirectory})> captured;
  late List<Duration> paused;
  late List<String> asked;

  // What the fakes answer, set per test.
  late String porcelain;
  late List<String> tracked;
  late String listing;
  late Map<String, String> env;
  late int published;
  late List<Object> registry;

  VerbContext context() => VerbContext(
    args: const [],
    env: env,
    root: root.path,
    workingDirectory: root.path,
    log: said.add,
    start: (argv, {workingDirectory}) async {
      started.add((argv: argv, workingDirectory: workingDirectory));
      return published;
    },
    collect: (argv, {workingDirectory, timeout}) async {
      captured.add((argv: argv, workingDirectory: workingDirectory));
      return switch (argv) {
        ['git', 'status', ...] => (exitCode: 0, stdout: porcelain, stderr: ''),
        ['git', 'ls-files', ...] => (
          exitCode: 0,
          stdout: tracked.map((path) => '$path\u0000').join(),
          stderr: '',
        ),
        // 65 as pub answers a dry run with warnings: the listing is there all
        // the same.
        ['dart', 'pub', 'publish', '--dry-run'] => (
          exitCode: 65,
          stdout: listing,
          stderr: '',
        ),
        _ => throw StateError('nothing captures $argv'),
      };
    },
  );

  /// Answers with each of [registry] in turn — a set of versions, or a
  /// [RegistryUnavailable] to throw — and with the last one from then on.
  Future<Set<String>> probe(String url, String name) async {
    asked.add('$url $name');
    final answer = registry.length > 1 ? registry.removeAt(0) : registry.first;
    if (answer is RegistryUnavailable) {
      throw answer;
    }
    return answer as Set<String>;
  }

  Future<int> run([PubPackage package = _package]) => pubPublish(
    package,
    probe: probe,
    pause: (delay) async => paused.add(delay),
  )(context());

  void write(String path, String content) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void manifest({String version = '1.2.0', String? publishTo}) => write(
    'packages/demo/pubspec.yaml',
    'name: demo\n'
        'description: A demo.\n'
        'version: $version\n'
        '${publishTo == null ? '' : 'publish_to: $publishTo\n'}'
        '\n'
        'environment:\n'
        '  sdk: ^3.12.0\n',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_kit_publish_');
    said = [];
    started = [];
    captured = [];
    paused = [];
    asked = [];
    porcelain = '';
    env = {};
    // As `git ls-files` answers in the package: from it.
    tracked = ['CHANGELOG.md', 'lib/demo.dart', 'pubspec.yaml'];
    listing = _listing;
    published = ExitCode.success;
    registry = [
      {'1.1.0'},
      {'1.1.0', '1.2.0'},
    ];
    manifest();
    write('packages/demo/CHANGELOG.md', '# Changelog\n\n## 1.2.0\n\n- New.\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('before the upload', () {
    test('a package that is not there is refused, and nothing runs', () async {
      expect(
        await run(const PubPackage('packages/absent')),
        ExitCode.invalidFile,
      );
      expect(said.join('\n'), contains('packages/absent'));
      expect(started, isEmpty);
    });

    test('so is one marked `publish_to: none`', () async {
      manifest(publishTo: 'none');
      expect(await run(), ExitCode.invalidFile);
      expect(said.join('\n'), contains('publish_to: none'));
      expect(started, isEmpty);
    });

    test('so is one whose manifest is not YAML, naming it', () async {
      write('packages/demo/pubspec.yaml', 'name: demo\nversion: [1.2.0\n');
      expect(await run(), ExitCode.invalidFile);
      expect(said.join('\n'), contains('pubspec.yaml'));
      expect(started, isEmpty);
    });

    test('a manifest written in flow style is read as pub reads it', () async {
      write('packages/demo/pubspec.yaml', '{name: demo, version: 1.2.0}\n');
      expect(await run(), ExitCode.success);
      expect(asked.first, 'https://pub.dev demo');
    });

    test('a CHANGELOG that does not name the version refuses', () async {
      write('packages/demo/CHANGELOG.md', '# Changelog\n\n## Unreleased\n');
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('names no 1.2.0'));
      expect(started, isEmpty);
    });

    test('and so does no CHANGELOG at all', () async {
      File(p.join(root.path, 'packages/demo/CHANGELOG.md')).deleteSync();
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('CHANGELOG.md'));
      expect(started, isEmpty);
    });

    test('a tree that differs from HEAD refuses, naming each path', () async {
      porcelain =
          ' M packages/demo/lib/demo.dart\n'
          '?? packages/demo/lib/scratch.dart\n';
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('packages/demo/lib/demo.dart'));
      expect(said.join('\n'), contains('packages/demo/lib/scratch.dart'));
      expect(started, isEmpty);
    });

    test('asking git about the package only, from the root', () async {
      await run();
      expect(captured.first.argv, [
        'git',
        'status',
        '--porcelain',
        '--',
        'packages/demo',
      ]);
      expect(captured.first.workingDirectory, root.path);
    });

    test('a file pub would upload and git does not track refuses', () async {
      // What `git status` cannot see: a file git ignores, which pub packs
      // all the same once a `.pubignore` stands beside the `.gitignore`.
      listing = _listing.replaceFirst(
        '└── pubspec.yaml (<1 KB)',
        '├── pubspec.yaml (<1 KB)\n└── secret.env (<1 KB)',
      );
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('secret.env'));
      expect(started, isEmpty);
      expect(
        captured.map((c) => c.argv.take(4).join(' ')),
        containsAll(['git ls-files -z', 'dart pub publish --dry-run']),
      );
      expect(
        captured.firstWhere((c) => c.argv[0] == 'dart').workingDirectory,
        'packages/demo',
      );
      expect(
        captured.firstWhere((c) => c.argv[1] == 'ls-files').workingDirectory,
        'packages/demo',
      );
    });

    test('and a dry run that lists nothing is no permission', () async {
      listing = 'Resolving dependencies...\nBecause demo depends on ...\n';
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('--dry-run'));
      expect(started, isEmpty);
    });

    test('a version the registry already serves refuses', () async {
      registry = [
        {'1.1.0', '1.2.0'},
      ];
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('already serves demo 1.2.0'));
      expect(started, isEmpty);
    });

    group('where a version already served is a skip', () {
      const skipping = PubPackage(
        'packages/demo',
        waits: [Duration.zero],
        alreadyServed: AlreadyServed.skip,
      );

      test('one the registry serves is a 0, and nothing else runs', () async {
        registry = [
          {'1.1.0', '1.2.0'},
        ];
        // A package nobody bumped is not held to a tree or a changelog.
        porcelain = ' M packages/demo/lib/demo.dart\n';
        write('packages/demo/CHANGELOG.md', '# Changelog\n');
        expect(await run(skipping), ExitCode.success);
        expect(
          said.join('\n'),
          contains('⊘ https://pub.dev already serves demo 1.2.0'),
        );
        expect(captured, isEmpty);
        expect(started, isEmpty);
      });

      test('one it does not serve is published, asked again before', () async {
        registry = [
          {'1.1.0'},
          {'1.1.0'},
          {'1.1.0', '1.2.0'},
        ];
        expect(await run(skipping), ExitCode.success);
        expect(started.single.argv, ['dart', 'pub', 'publish', '--force']);
        expect(asked, hasLength(3));
      });

      test('and one served while it was checked is skipped then', () async {
        // Another run published it between the first look and the upload.
        registry = [
          {'1.1.0'},
          {'1.1.0', '1.2.0'},
        ];
        expect(await run(skipping), ExitCode.success);
        expect(said.join('\n'), contains('⊘'));
        expect(started, isEmpty);
      });

      test('and is checked as any other before the upload', () async {
        porcelain = ' M packages/demo/lib/demo.dart\n';
        expect(await run(skipping), ExitCode.taskFailed);
        expect(started, isEmpty);
      });

      test('a registry that cannot be asked still refuses', () async {
        registry = [const RegistryUnavailable('connection refused')];
        expect(await run(skipping), ExitCode.taskFailed);
        expect(said.join('\n'), contains('connection refused'));
        expect(captured, isEmpty);
        expect(started, isEmpty);
      });
    });

    test('a registry that cannot be asked refuses rather than guess', () async {
      registry = [const RegistryUnavailable('connection refused')];
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('connection refused'));
      expect(started, isEmpty);
    });

    test('the registry is pub.dev unless `publish_to:` names one', () async {
      await run();
      expect(asked.first, 'https://pub.dev demo');
      asked.clear();
      registry = [
        <String>{},
        const {'1.2.0'},
      ];
      manifest(publishTo: 'https://deps.example/');
      await run();
      expect(asked.first, 'https://deps.example/ demo');
    });

    test('or PUB_HOSTED_URL, which pub uploads to without one', () async {
      env = {'PUB_HOSTED_URL': 'https://mirror.example'};
      await run();
      expect(asked.first, 'https://mirror.example demo');
      asked.clear();
      registry = [
        <String>{},
        const {'1.2.0'},
      ];
      manifest(publishTo: 'https://deps.example/');
      await run();
      expect(asked.first, 'https://deps.example/ demo');
    });
  });

  group('the upload', () {
    test('is `dart pub publish --force`, in the package', () async {
      expect(await run(), ExitCode.success);
      expect(started.single.argv, ['dart', 'pub', 'publish', '--force']);
      expect(started.single.workingDirectory, 'packages/demo');
    });

    test('refused by pub is a 1, and nothing is waited for', () async {
      published = 65;
      registry = [
        {'1.1.0'},
      ];
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('65'));
      // Asked once after, because a failing pub is not proof of nothing
      // uploaded.
      expect(asked, hasLength(2));
      expect(paused, isEmpty);
    });

    test('failing after the archive went up is a 0 if it is served', () async {
      published = 1;
      expect(await run(), ExitCode.success);
      expect(said.last, contains('serves demo 1.2.0'));
    });

    test('failing otherwise and not served is a 4: it may still be', () async {
      // Pub answers 65 for a refusal before the upload — its validation, its
      // credentials — and 1 for an upload that failed, which the connection
      // can do after the archive went up.
      published = 1;
      registry = [
        {'1.1.0'},
      ];
      expect(await run(), ExitCode.continuationFailed);
      expect(said.last, contains('may have been uploaded'));
    });

    test('and a 4 where the registry cannot say', () async {
      published = 1;
      registry = [
        {'1.1.0'},
        const RegistryUnavailable('connection reset'),
      ];
      expect(await run(), ExitCode.continuationFailed);
      expect(said.last, contains('may have been uploaded'));
    });
  });

  group('after the upload', () {
    test('waits until the registry serves the version', () async {
      // The first answer is the check before the upload's.
      registry = [
        {'1.1.0'},
        {'1.1.0'},
        {'1.1.0', '1.2.0'},
      ];
      expect(await run(), ExitCode.success);
      expect(paused, [Duration.zero, const Duration(seconds: 5)]);
      expect(said.last, contains('serves demo 1.2.0'));
    });

    test('a registry that cannot be asked yet is waited out too', () async {
      registry = [
        {'1.1.0'},
        const RegistryUnavailable('timed out'),
        {'1.2.0'},
      ];
      expect(await run(), ExitCode.success);
      expect(said.join('\n'), contains('timed out'));
    });

    test(
      'a probe that throws anything at all is waited out, never a 1',
      () async {
        var calls = 0;
        final code = await pubPublish(
          _package,
          probe: (url, name) async {
            if (calls++ == 0) {
              return {'1.1.0'};
            }
            throw StateError("a probe of the project's own, broken");
          },
          pause: (delay) async {},
        )(context());
        expect(code, ExitCode.continuationFailed);
        expect(said.join('\n'), contains('broken'));
      },
    );

    test('one that never serves it is a 4: the upload is not undone', () async {
      registry = [
        {'1.1.0'},
      ];
      expect(await run(), ExitCode.continuationFailed);
      expect(paused, _package.waits);
      expect(said.join('\n'), contains('the upload succeeded'));
    });
  });

  group('against a real git', () {
    // Git itself, because what these are about is what git answers — for a
    // submodule, for a link — and a fake would answer what the test assumed.
    // The dry run stays faked: what pub lists is read from [listing].
    late VerbContext real;

    void git(String directory, List<String> args) {
      final result = Process.runSync('git', [
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        '-c',
        'protocol.file.allow=always',
        ...args,
      ], workingDirectory: directory);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')}: ${result.stderr}');
      }
    }

    setUp(() {
      real = VerbContext(
        args: const [],
        env: env,
        root: root.path,
        workingDirectory: root.path,
        log: said.add,
        start: (argv, {workingDirectory}) async {
          started.add((argv: argv, workingDirectory: workingDirectory));
          return published;
        },
        collect: (argv, {workingDirectory, timeout}) async {
          if (argv case ['dart', 'pub', 'publish', '--dry-run']) {
            return (exitCode: 0, stdout: listing, stderr: '');
          }
          final result = await Process.run(
            argv.first,
            argv.skip(1).toList(),
            workingDirectory: p.join(root.path, workingDirectory ?? '.'),
          );
          return (
            exitCode: result.exitCode,
            stdout: result.stdout as String,
            stderr: result.stderr as String,
          );
        },
      );
    });

    Future<int> publish() => publishToPub(
      real,
      _package,
      probe: probe,
      pause: (delay) async => paused.add(delay),
    );

    test('a submodule package is read from its own repository', () async {
      // From the superproject `git ls-files -- packages/demo` lists the
      // gitlink alone, which would leave every file of the package untracked.
      write('packages/demo/lib/demo.dart', 'void demo() {}\n');
      final demo = p.join(root.path, 'packages', 'demo');
      final source = Directory.systemTemp.createTempSync('xtask_kit_sub_');
      addTearDown(() => source.deleteSync(recursive: true));
      for (final file in Directory(demo).listSync(recursive: true)) {
        if (file is File) {
          File(p.join(source.path, p.relative(file.path, from: demo)))
            ..createSync(recursive: true)
            ..writeAsStringSync(file.readAsStringSync());
        }
      }
      Directory(demo).deleteSync(recursive: true);
      git(source.path, ['init', '-q']);
      git(source.path, ['add', '.']);
      git(source.path, ['commit', '-qm', 'demo']);
      git(root.path, ['init', '-q']);
      git(root.path, ['submodule', 'add', '-q', source.path, 'packages/demo']);
      git(root.path, ['commit', '-qm', 'with demo']);

      expect(await publish(), ExitCode.success, reason: said.join('\n'));
    });

    test('a committed link to a directory covers what is under it', () async {
      // Git keeps `lib/linked` as one entry; pub follows it and lists the
      // files under it, each of which git knows only through the link.
      write('packages/demo/lib/demo.dart', 'void demo() {}\n');
      write('packages/demo/extra/e.dart', 'void e() {}\n');
      Link(
        p.join(root.path, 'packages/demo/lib/linked'),
      ).createSync('../extra');
      git(root.path, ['init', '-q']);
      git(root.path, ['add', '.']);
      git(root.path, ['commit', '-qm', 'demo']);
      listing = _listing.replaceFirst(
        '├── lib\n│   └── demo.dart (<1 KB)\n',
        '├── extra\n'
            '│   └── e.dart (<1 KB)\n'
            '├── lib\n'
            '│   ├── demo.dart (<1 KB)\n'
            '│   └── linked\n'
            '│       └── e.dart (<1 KB)\n',
      );
      expect(publishedFiles(listing), contains('lib/linked/e.dart'));

      expect(await publish(), ExitCode.success, reason: said.join('\n'));
    });

    test('and a file under no tracked entry still refuses', () async {
      write('packages/demo/lib/demo.dart', 'void demo() {}\n');
      write('packages/demo/.gitignore', 'secret.env\n');
      write('packages/demo/secret.env', 'TOKEN=1\n');
      git(root.path, ['init', '-q']);
      git(root.path, ['add', '.']);
      git(root.path, ['commit', '-qm', 'demo']);
      listing = _listing.replaceFirst(
        '└── pubspec.yaml (<1 KB)',
        '├── pubspec.yaml (<1 KB)\n└── secret.env (<1 KB)',
      );

      expect(await publish(), ExitCode.taskFailed);
      expect(said.last, contains('secret.env'));
      expect(started, isEmpty);
    });
  });

  group('a CHANGELOG names a version', () {
    test('in a heading, bracketed or dated', () {
      expect(changelogNames('## 1.2.0\n', '1.2.0'), isTrue);
      expect(changelogNames('## [1.2.0] - 2026-10-23\n', '1.2.0'), isTrue);
      expect(changelogNames('# v1.2.0\n', '1.2.0'), isTrue);
    });

    test('and not in passing, nor as part of another', () {
      expect(changelogNames('- fixed since 1.2.0\n', '1.2.0'), isFalse);
      expect(changelogNames('## 11.2.0\n', '1.2.0'), isFalse);
      expect(changelogNames('## 1.2.0-dev.1\n', '1.2.0'), isFalse);
      expect(changelogNames('## 1.2.0.1\n', '1.2.0'), isFalse);
    });
  });

  group("pub's dry run lists", () {
    test('every file, by its path in the package', () {
      expect(publishedFiles(_listing), [
        'CHANGELOG.md',
        'lib/demo.dart',
        'pubspec.yaml',
      ]);
    });

    test('nested, and with a name pub would not have shortened', () {
      expect(
        publishedFiles(
          'Publishing demo 1.2.0 to https://pub.dev:\n'
          '├── lib\n'
          '│   ├── src\n'
          '│   │   └── a (1 KB).dart (<1 KB)\n'
          '│   └── demo.dart (2 KB)\n'
          '└── pubspec.yaml (<1 KB)\n'
          '\n'
          'Total compressed archive size: 3 KB.\n',
        ),
        ['lib/src/a (1 KB).dart', 'lib/demo.dart', 'pubspec.yaml'],
      );
    });

    test('drawn in ASCII where the terminal has no Unicode', () {
      expect(
        publishedFiles(
          'Publishing demo 1.2.0 to https://pub.dev:\n'
          '|-- lib\n'
          "|   '-- demo.dart (<1 KB)\n"
          "'-- pubspec.yaml (<1 KB)\n",
        ),
        ['lib/demo.dart', 'pubspec.yaml'],
      );
    });

    test('or nothing, where pub listed none', () {
      expect(publishedFiles('Resolving dependencies...\n'), isNull);
    });
  });

  group('a manifest field', () {
    test('is read plain, quoted, or with a comment after it', () {
      expect(manifestField('version: 1.2.0\n', 'version'), '1.2.0');
      expect(manifestField("version: '1.2.0'\n", 'version'), '1.2.0');
      expect(manifestField('version: "1.2.0" # next\n', 'version'), '1.2.0');
    });

    test('and only at the top level', () {
      expect(manifestField('dev:\n  version: 1.2.0\n', 'version'), isNull);
    });

    test('and however YAML writes it — a pubspec is YAML, not lines', () {
      expect(manifestField('version: >-\n  1.2.0\n', 'version'), '1.2.0');
      expect(manifestField('version : 1.2.0\n', 'version'), '1.2.0');
      expect(manifestField('"version": 1.2.0\n', 'version'), '1.2.0');
      expect(manifestField("name: 'it''s'\n", 'name'), "it's");
      expect(
        manifestField('{name: demo, version: 1.2.0}\n', 'version'),
        '1.2.0',
      );
    });

    test('and is refused where the manifest is not a map of YAML', () {
      expect(
        () => manifestField('version: 1\nversion: 2\n', 'version'),
        throwsFormatException,
      );
      expect(
        () => manifestField('name: demo\nversion: [1.2.0\n', 'name'),
        throwsFormatException,
      );
      expect(() => manifestField('- demo\n', 'name'), throwsFormatException);
    });

    test('or where the field is not a string', () {
      expect(
        () => manifestField('version: 1.0\n', 'version'),
        throwsFormatException,
      );
      expect(
        () => manifestField('name: [demo]\n', 'name'),
        throwsFormatException,
      );
    });
  });

  group('the pub registry', () {
    test("answers with the versions it lists, from pub's API", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        request.response
          ..statusCode = request.uri.path.endsWith('/demo')
              ? HttpStatus.ok
              : HttpStatus.notFound
          ..write(
            jsonEncode({
              'name': 'demo',
              'versions': [
                {'version': '1.1.0'},
                {'version': '1.2.0'},
              ],
            }),
          );
        await request.response.close();
      });
      final url = 'http://${server.address.host}:${server.port}';
      expect(await askRegistry('$url/', 'demo'), {'1.1.0', '1.2.0'});
      expect(paths.single, '/api/packages/demo');
      // An unknown package is a package with no versions, not a failure: it
      // is what the first publish of every package sees.
      expect(await askRegistry(url, 'absent'), isEmpty);
    });

    test(
      'and is unavailable when TLS fails or the answer is not text',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        server.listen((request) async {
          request.response
            ..statusCode = HttpStatus.ok
            ..add([0xff, 0xfe, 0xfd]);
          await request.response.close();
        });
        // HTTPS against a server that speaks plain HTTP: the handshake fails.
        await expectLater(
          askRegistry('https://127.0.0.1:${server.port}', 'demo'),
          throwsA(isA<RegistryUnavailable>()),
        );
        await expectLater(
          askRegistry('http://127.0.0.1:${server.port}', 'demo'),
          throwsA(isA<RegistryUnavailable>()),
        );
      },
    );

    test('and is unavailable when nothing answers', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      expect(
        askRegistry('http://127.0.0.1:$port', 'demo'),
        throwsA(isA<RegistryUnavailable>()),
      );
    });
  });
}
