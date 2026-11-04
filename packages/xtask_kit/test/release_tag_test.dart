import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

/// What `dart pub publish --dry-run` prints for the demo package.
const _listing = '''
Publishing demo 1.2.0 to https://pub.dev:
├── CHANGELOG.md (<1 KB)
├── lib
│   └── demo.dart (<1 KB)
└── pubspec.yaml (<1 KB)

Package has 0 warnings.
''';

void main() {
  group('a release tag', () {
    test('is the pattern with the name and the version in it', () {
      expect(
        releaseTag(releaseTagPattern, 'twk_core', '0.2.0'),
        'twk_core-v0.2.0',
      );
      expect(releaseTag('v{{version}}', 'demo', '1.2.0-dev.1'), 'v1.2.0-dev.1');
    });

    test('takes no pattern without the version', () {
      expect(
        () => releaseTag('{{name}}', 'demo', '1.2.0'),
        throwsArgumentError,
      );
    });
  });

  group("a changelog's entry", () {
    const changelog = '''
# Changelog

## 1.2.0

### Added

- New.

## [1.1.0] - 2026-10-01

- Old.
''';

    test('is what its heading has under it, up to the next of its level', () {
      expect(changelogEntry(changelog, '1.2.0'), '### Added\n\n- New.');
      expect(changelogEntry(changelog, '1.1.0'), '- Old.');
    });

    test('is none where no heading names the version', () {
      expect(changelogEntry(changelog, '1.0.0'), isNull);
      expect(changelogEntry('- 1.2.0 in passing\n', '1.2.0'), isNull);
    });
  });

  group('against a real git', () {
    // Git itself, with a bare repository for its remote: what a tag here and
    // there is is git's answer, not one the test assumed. Only gh is faked,
    // as the commands it was given and what it answered.
    late Directory root;
    late Directory remote;
    late List<String> said;
    late List<List<String>> gh;
    late bool ghInstalled;
    late bool releaseThere;

    String git(List<String> args, {String? directory}) {
      final result = Process.runSync(
        'git',
        args,
        workingDirectory: directory ?? root.path,
      );
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')}: ${result.stderr}');
      }
      return (result.stdout as String).trim();
    }

    void write(String path, String content) => File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    String commit(String version) {
      write(
        'packages/demo/pubspec.yaml',
        'name: demo\nversion: $version\n\nenvironment:\n  sdk: ^3.12.0\n',
      );
      write(
        'packages/demo/CHANGELOG.md',
        '# Changelog\n\n## $version\n\n- In $version.\n',
      );
      write('packages/demo/lib/demo.dart', '// demo\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', version]);
      return git(['rev-parse', 'HEAD']);
    }

    /// A commit after the last that keeps its version: lib/ changed only.
    String again() {
      write('packages/demo/lib/demo.dart', '// demo, again\n');
      git(['commit', '-q', '-am', 'again']);
      return git(['rev-parse', 'HEAD']);
    }

    VerbContext context({List<String> args = const [], int published = 0}) =>
        VerbContext(
          args: args,
          env: const {},
          root: root.path,
          workingDirectory: root.path,
          log: said.add,
          locate: (name, {workingDirectory}) =>
              name == 'gh' && ghInstalled ? '/usr/bin/gh' : null,
          start: (argv, {workingDirectory}) async => published,
          collect: (argv, {workingDirectory, timeout}) async {
            if (argv case ['dart', 'pub', 'publish', '--dry-run']) {
              return (exitCode: 0, stdout: _listing, stderr: '');
            }
            if (argv.first == 'gh') {
              gh.add(argv);
              final view =
                  argv.length > 1 && argv[1] == 'release' && argv[2] == 'view';
              if (view) {
                return (exitCode: releaseThere ? 0 : 1, stdout: '', stderr: '');
              }
              releaseThere = true;
              return (exitCode: 0, stdout: '', stderr: '');
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

    /// The commit [tag] is at here, or null where there is none.
    String? here(String tag) {
      final result = Process.runSync('git', [
        'rev-parse',
        '-q',
        '--verify',
        'refs/tags/$tag^{commit}',
      ], workingDirectory: root.path);
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    }

    /// The commit [tag] is at on the remote, or null where there is none.
    String? there(String tag) {
      final result = Process.runSync('git', [
        'rev-parse',
        '-q',
        '--verify',
        'refs/tags/$tag^{commit}',
      ], workingDirectory: remote.path);
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('xtask_kit_tag_');
      remote = Directory.systemTemp.createTempSync('xtask_kit_remote_');
      said = [];
      gh = [];
      ghInstalled = true;
      releaseThere = false;
      git(['init', '-q', '--bare'], directory: remote.path);
      git(['init', '-q']);
      git(['config', 'user.name', 't']);
      git(['config', 'user.email', 't@t']);
      git(['remote', 'add', 'origin', remote.path]);
    });

    tearDown(() {
      root.deleteSync(recursive: true);
      remote.deleteSync(recursive: true);
    });

    test('tags the version at the commit, pushes it, and releases it with '
        'its changelog entry', () async {
      final sha = commit('1.2.0');
      expect(await tagRelease(context(), 'packages/demo'), ExitCode.success);
      expect(here('demo-v1.2.0'), sha);
      expect(there('demo-v1.2.0'), sha);
      expect(
        git([
          'for-each-ref',
          '--format=%(objecttype) %(contents:subject)',
          'refs/tags/demo-v1.2.0',
        ]),
        'tag demo 1.2.0',
        reason: 'annotated, with the release as its message',
      );
      expect(gh.last, [
        'gh',
        'release',
        'create',
        'demo-v1.2.0',
        '--verify-tag',
        '--title',
        'demo 1.2.0',
        '--notes',
        '- In 1.2.0.',
      ]);
    });

    test('run again, makes nothing that is there already', () async {
      commit('1.2.0');
      await tagRelease(context(), 'packages/demo');
      gh.clear();
      said.clear();
      expect(
        await tagRelease(context(), 'packages/demo'),
        ExitCode.success,
        reason: said.join('\n'),
      );
      expect(gh, [
        ['gh', 'release', 'view', 'demo-v1.2.0'],
      ]);
      expect(said, isNot(anyElement(startsWith('tagged'))));
      expect(said, isNot(anyElement(startsWith('pushed'))));
    });

    test(
      'a version of an older commit is tagged at it, with its notes',
      () async {
        final first = commit('1.1.0');
        commit('1.2.0');
        expect(
          await pubTagRelease()(context(args: ['packages/demo', first])),
          ExitCode.success,
        );
        expect(here('demo-v1.1.0'), first);
        expect(there('demo-v1.1.0'), first);
        expect(gh.last.last, '- In 1.1.0.');
      },
    );

    test('moves no tag, here or on the remote', () async {
      final first = commit('1.2.0');
      git(['tag', '-a', 'demo-v1.2.0', '-m', 'early', first]);
      again();
      expect(await tagRelease(context(), 'packages/demo'), ExitCode.taskFailed);
      expect(there('demo-v1.2.0'), isNull, reason: 'nothing pushed');
      expect(gh, isEmpty);

      // and on the remote alone
      git(['tag', '-d', 'demo-v1.2.0']);
      git(['tag', '-a', 'demo-v1.2.0', '-m', 'early', first]);
      git(['push', '-q', 'origin', 'refs/tags/demo-v1.2.0']);
      git(['tag', '-d', 'demo-v1.2.0']);
      expect(await tagRelease(context(), 'packages/demo'), ExitCode.taskFailed);
      expect(there('demo-v1.2.0'), first);
      expect(gh, isEmpty);
    });

    test(
      'without gh, pushes the tag and says the release is not made',
      () async {
        ghInstalled = false;
        final sha = commit('1.2.0');
        expect(await tagRelease(context(), 'packages/demo'), ExitCode.success);
        expect(there('demo-v1.2.0'), sha);
        expect(gh, isEmpty);
        expect(said.last, contains('no gh on the PATH'));
      },
    );

    test('takes no version its changelog does not name', () async {
      commit('1.2.0');
      write('packages/demo/CHANGELOG.md', '# Changelog\n\n## 1.1.0\n');
      git(['commit', '-q', '-am', 'lost the entry']);
      expect(await tagRelease(context(), 'packages/demo'), ExitCode.taskFailed);
      expect(here('demo-v1.2.0'), isNull);
    });

    group('a publish naming a tag', () {
      const package = PubPackage(
        'packages/demo',
        waits: [Duration.zero],
        alreadyServed: AlreadyServed.skip,
        tag: releaseTagPattern,
      );

      test('tags the version it uploaded, at HEAD', () async {
        final sha = commit('1.2.0');
        final answers = [
          <String>{'1.1.0'},
          <String>{'1.1.0'},
          <String>{'1.1.0', '1.2.0'},
        ];
        final code = await publishToPub(
          context(),
          package,
          probe: (_, _) async =>
              answers.length > 1 ? answers.removeAt(0) : answers.first,
          pause: (_) async {},
        );
        expect(code, ExitCode.success, reason: said.join('\n'));
        expect(there('demo-v1.2.0'), sha);
        expect(gh.last.sublist(0, 4), [
          'gh',
          'release',
          'create',
          'demo-v1.2.0',
        ]);
      });

      test('tags no version the registry served already', () async {
        commit('1.2.0');
        final code = await publishToPub(
          context(),
          package,
          probe: (_, _) async => {'1.2.0'},
          pause: (_) async {},
        );
        expect(code, ExitCode.success);
        expect(here('demo-v1.2.0'), isNull);
        expect(gh, isEmpty);
      });

      test('a tag it cannot make is a 4: the upload stands', () async {
        final first = commit('1.2.0');
        git(['tag', '-a', 'demo-v1.2.0', '-m', 'early', first]);
        again();
        final answers = [
          <String>{},
          <String>{},
          <String>{'1.2.0'},
        ];
        final code = await publishToPub(
          context(),
          package,
          probe: (_, _) async =>
              answers.length > 1 ? answers.removeAt(0) : answers.first,
          pause: (_) async {},
        );
        expect(code, ExitCode.continuationFailed, reason: said.join('\n'));
        expect(said.last, contains('make it with pubTagRelease'));
      });
    });
  });
}
