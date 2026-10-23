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

void main() {
  late Directory root;
  late List<String> said;
  late List<({List<String> argv, String? workingDirectory})> started;
  late List<({List<String> argv, String? workingDirectory})> captured;
  late List<Duration> paused;
  late List<String> asked;

  // What the fakes answer, set per test.
  late String porcelain;
  late int published;
  late List<Object> registry;

  VerbContext context() => VerbContext(
    args: const [],
    env: const {},
    root: root.path,
    workingDirectory: root.path,
    log: said.add,
    start: (argv, {workingDirectory}) async {
      started.add((argv: argv, workingDirectory: workingDirectory));
      return published;
    },
    collect: (argv, {workingDirectory, timeout}) async {
      captured.add((argv: argv, workingDirectory: workingDirectory));
      return (exitCode: 0, stdout: porcelain, stderr: '');
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
      expect(captured.single.argv, [
        'git',
        'status',
        '--porcelain',
        '--',
        'packages/demo',
      ]);
      expect(captured.single.workingDirectory, root.path);
    });

    test('a version the registry already serves refuses', () async {
      registry = [
        {'1.1.0', '1.2.0'},
      ];
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('already serves demo 1.2.0'));
      expect(started, isEmpty);
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
  });

  group('the upload', () {
    test('is `dart pub publish --force`, in the package', () async {
      expect(await run(), ExitCode.success);
      expect(started.single.argv, ['dart', 'pub', 'publish', '--force']);
      expect(started.single.workingDirectory, 'packages/demo');
    });

    test('refused by pub is a 1, and nothing is waited for', () async {
      published = 65;
      expect(await run(), ExitCode.taskFailed);
      expect(said.join('\n'), contains('65'));
      expect(asked, hasLength(1));
      expect(paused, isEmpty);
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

    test('one that never serves it is a 4: the upload is not undone', () async {
      registry = [
        {'1.1.0'},
      ];
      expect(await run(), ExitCode.continuationFailed);
      expect(paused, _package.waits);
      expect(said.join('\n'), contains('the upload succeeded'));
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

  group('a manifest field', () {
    test('is read plain, quoted, or with a comment after it', () {
      expect(manifestField('version: 1.2.0\n', 'version'), '1.2.0');
      expect(manifestField("version: '1.2.0'\n", 'version'), '1.2.0');
      expect(manifestField('version: "1.2.0" # next\n', 'version'), '1.2.0');
    });

    test('and only at the top level', () {
      expect(manifestField('dev:\n  version: 1.2.0\n', 'version'), isNull);
    });

    test('and is refused where it is not a single plain value', () {
      expect(
        () => manifestField('version: >\n  1.2.0\n', 'version'),
        throwsFormatException,
      );
      expect(
        () => manifestField('version: 1\nversion: 2\n', 'version'),
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
