import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/src/vscode.dart';

const _extension = VsCodeExtension(directory: 'vscode');

void main() {
  late Directory root;
  late Directory home;
  late List<String> said;
  late List<List<String>> started;
  late List<List<String>> asked;

  /// What `code --list-extensions --show-versions` answers, by the profile
  /// it was asked about — `Default` where no `--profile` was given.
  late Map<String, String> listed;

  /// What a `code` that is started answers with.
  late int answer;

  /// Whether `code` is on `PATH`.
  late bool onPath;

  Map<String, String> environment({String? profile}) => {
    'HOME': home.path,
    'XDG_CONFIG_HOME': p.join(home.path, '.config'),
    'APPDATA': p.join(home.path, 'AppData'),
    'PROFILE': ?profile,
  };

  VerbContext context({
    Map<String, String>? env,
    List<String> args = const [],
  }) => VerbContext(
    args: args,
    env: env ?? environment(),
    root: root.path,
    workingDirectory: root.path,
    log: said.add,
    start: (argv, {workingDirectory}) async {
      started.add(argv);
      return answer;
    },
    locate: (name, {workingDirectory}) =>
        onPath && name == 'code' ? '/usr/bin/code' : null,
    collect: (argv, {workingDirectory, timeout}) async {
      asked.add(argv);
      final at = argv.indexOf('--profile');
      final profile = at < 0 ? 'Default' : argv[at + 1];
      return (exitCode: 0, stdout: listed[profile] ?? '', stderr: '');
    },
  );

  void write(String path, String content) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void manifest({String version = '1.2.3'}) => write(
    'vscode/package.json',
    jsonEncode({'name': 'demo', 'publisher': 'acme', 'version': version}),
  );

  String vsix({String version = '1.2.3'}) {
    write('vscode/demo-$version.vsix', 'vsix');
    return p.join(root.path, 'vscode', 'demo-$version.vsix');
  }

  /// VS Code's own record of the profiles, as it keeps it.
  void profiles(List<String> names) {
    final user = vsCodeUserDir(environment())!;
    File(p.join(user, 'globalStorage', 'storage.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'userDataProfiles': [
            for (final name in names) {'location': name, 'name': name},
          ],
        }),
      );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_kit_root_');
    home = Directory.systemTemp.createTempSync('xtask_kit_home_');
    said = [];
    started = [];
    asked = [];
    listed = {};
    answer = ExitCode.success;
    onPath = true;
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    home.deleteSync(recursive: true);
  });

  group('install', () {
    test('puts the built VSIX into the profile PROFILE names', () async {
      manifest();
      final built = vsix();
      profiles(['Dart Work']);
      expect(
        await vsCodeInstall(_extension)(
          context(env: environment(profile: 'Dart Work')),
        ),
        ExitCode.success,
      );
      expect(started, [
        [
          'code',
          '--profile',
          'Dart Work',
          '--install-extension',
          built,
          '--force',
        ],
      ]);
      expect(said.last, contains('profile "Dart Work"'));
    });

    test('takes the profile from `--profile` over PROFILE', () async {
      manifest();
      vsix();
      profiles(['Work', 'Play']);
      await vsCodeInstall(_extension)(
        context(
          env: environment(profile: 'Play'),
          args: const ['--profile', 'Work'],
        ),
      );
      expect(started.single.sublist(1, 3), ['--profile', 'Work']);
    });

    test('into the Default profile without one, and says so', () async {
      manifest();
      vsix();
      expect(await vsCodeInstall(_extension)(context()), ExitCode.success);
      expect(started.single, isNot(contains('--profile')));
      expect(said.join('\n'), contains('Default profile'));
    });

    test(
      'refuses a profile that does not exist, naming those that do',
      () async {
        manifest();
        vsix();
        profiles(['Work']);
        expect(
          await vsCodeInstall(_extension)(
            context(env: environment(profile: 'Wrok')),
          ),
          ExitCode.taskFailed,
        );
        expect(started, isEmpty);
        expect(said.join('\n'), allOf(contains('"Wrok"'), contains('Work')));
      },
    );

    test('uses a profile it cannot check, and warns', () async {
      manifest();
      vsix();
      expect(
        await vsCodeInstall(_extension)(
          context(env: {'PROFILE': 'Work'}),
        ),
        ExitCode.success,
      );
      expect(started.single.sublist(1, 3), ['--profile', 'Work']);
      expect(said.join('\n'), contains('unverified'));
    });

    test('refuses without `code` on PATH, starting nothing', () async {
      manifest();
      vsix();
      onPath = false;
      expect(
        await vsCodeInstall(_extension)(context()),
        ExitCode.missingTool,
      );
      expect(started, isEmpty);
      expect(said.join('\n'), contains('`code`'));
    });

    test('refuses a VSIX not built yet', () async {
      manifest();
      expect(
        await vsCodeInstall(_extension)(context()),
        ExitCode.taskFailed,
      );
      expect(started, isEmpty);
      expect(said.join('\n'), contains('demo-1.2.3.vsix'));
    });

    test('refuses an extension without a manifest', () async {
      expect(
        await vsCodeInstall(_extension)(context()),
        ExitCode.taskFailed,
      );
      expect(said.join('\n'), contains('package.json'));
    });

    test('refuses a manifest without a version', () async {
      write(
        'vscode/package.json',
        jsonEncode({'name': 'demo', 'publisher': 'acme'}),
      );
      expect(
        await vsCodeInstall(_extension)(context()),
        ExitCode.taskFailed,
      );
      expect(said.join('\n'), contains('"version"'));
    });

    test('refuses an argument it does not know', () async {
      manifest();
      vsix();
      expect(
        await vsCodeInstall(_extension)(context(args: const ['--force'])),
        ExitCode.taskFailed,
      );
      expect(started, isEmpty);
      expect(said.join('\n'), contains('--force'));
    });

    test("answers with `code`'s own failure", () async {
      manifest();
      vsix();
      answer = 7;
      expect(await vsCodeInstall(_extension)(context()), 7);
      expect(said.join('\n'), isNot(contains('✓')));
    });
  });

  group('uninstall', () {
    test('removes the extension from the profile that has it', () async {
      manifest();
      profiles(['Work']);
      listed = {'Work': 'acme.demo@1.2.3\nother.thing@0.1.0\n'};
      expect(
        await vsCodeUninstall(_extension)(
          context(env: environment(profile: 'Work')),
        ),
        ExitCode.success,
      );
      expect(started, [
        ['code', '--profile', 'Work', '--uninstall-extension', 'acme.demo'],
      ]);
    });

    test('starts nothing where it is not installed, and succeeds', () async {
      manifest();
      listed = {'Default': 'other.thing@0.1.0\n'};
      expect(await vsCodeUninstall(_extension)(context()), ExitCode.success);
      expect(started, isEmpty);
      expect(said.join('\n'), contains('not installed'));
    });

    test('refuses a profile that does not exist', () async {
      manifest();
      profiles(['Work']);
      expect(
        await vsCodeUninstall(_extension)(
          context(env: environment(profile: 'Wrok')),
        ),
        ExitCode.taskFailed,
      );
      expect(asked, isEmpty);
      expect(started, isEmpty);
    });

    test('refuses without `code` on PATH', () async {
      manifest();
      onPath = false;
      expect(
        await vsCodeUninstall(_extension)(context()),
        ExitCode.missingTool,
      );
    });
  });

  group('profiles', () {
    test('lists each profile with the build it holds', () async {
      manifest();
      profiles(['Dart Work', 'Play']);
      listed = {
        'Default': 'acme.demo@1.0.0\n',
        'Dart Work': 'Acme.Demo@1.2.3\n',
        'Play': 'notacme.demo@9.9.9\n',
      };
      expect(await vsCodeProfiles(_extension)(context()), ExitCode.success);
      final rows = said.skip(2).toList();
      expect(rows, hasLength(3));
      expect(rows[0], allOf(startsWith('Default'), endsWith('1.0.0')));
      expect(rows[1], allOf(startsWith('Dart Work'), endsWith('1.2.3')));
      expect(rows[2], allOf(startsWith('Play'), endsWith('—')));
    });

    test('refuses without `code` on PATH', () async {
      manifest();
      onPath = false;
      expect(
        await vsCodeProfiles(_extension)(context()),
        ExitCode.missingTool,
      );
    });
  });

  group('readProfileNames', () {
    test('is Default alone without a state file', () {
      final names = readProfileNames(environment());
      expect(names.names, ['Default']);
      expect(names.unreadable, isNull);
    });

    test('is Default alone for a state file of the wrong shape', () {
      final user = vsCodeUserDir(environment())!;
      File(p.join(user, 'globalStorage', 'storage.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"userDataProfiles": "nope"}');
      expect(readProfileNames(environment()).names, ['Default']);
    });

    test('says it could not look where no user directory is known', () {
      final names = readProfileNames(const {});
      expect(names.names, ['Default']);
      expect(names.unreadable, isNotNull);
    });
  });

  test('profileArgs addresses the Default profile with nothing', () {
    expect(profileArgs(null), isEmpty);
    expect(profileArgs('Default'), isEmpty);
    expect(profileArgs('My Work'), ['--profile', 'My Work']);
  });
}
