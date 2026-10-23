import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

const _cli = DartCli(
  name: 'demo',
  bundles: ['build/cli/bundle', 'build/server/bundle'],
  commands: {'demo': 'demo_cli', 'demo-server': 'demo_server'},
  retired: ['demo-old'],
);

void main() {
  final windows = Platform.isWindows;
  late Directory root;
  late Directory home;
  late List<String> said;
  late CliPlaces places;

  String exe(String name) => windows ? '$name.exe' : name;

  VerbContext context() => VerbContext(
    args: const [],
    env: {'HOME': home.path, 'USERPROFILE': home.path, 'PATH': ''},
    root: root.path,
    workingDirectory: root.path,
    log: said.add,
    start: (argv, {workingDirectory}) async => ExitCode.taskFailed,
  );

  void write(String path, String content) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void bundles() {
    write('build/cli/bundle/bin/${exe('demo_cli')}', 'cli');
    write('build/cli/bundle/lib/libshared.so', 'shared');
    write('build/server/bundle/bin/${exe('demo_server')}', 'server');
    write('build/server/bundle/lib/libshared.so', 'shared');
    write('build/server/bundle/lib/libmodel.so', 'model');
  }

  String installed(String command) => p.join(places.bindir, exe(command));

  setUp(() {
    root = Directory.systemTemp.createTempSync('xtask_kit_root_');
    home = Directory.systemTemp.createTempSync('xtask_kit_home_');
    said = [];
    places = CliPlaces.of(_cli, home: home.path, windows: windows);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    home.deleteSync(recursive: true);
  });

  test('every bundle goes into one bin/ and one lib/', () async {
    bundles();
    expect(await cliInstall(_cli)(context()), ExitCode.success);
    expect(
      Directory(places.bin).listSync().map((e) => p.basename(e.path)),
      unorderedEquals([exe('demo_cli'), exe('demo_server')]),
    );
    expect(
      Directory(places.lib).listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['libshared.so', 'libmodel.so']),
    );
  });

  test('and each command reaches its executable from PATH', () async {
    bundles();
    await cliInstall(_cli)(context());
    expect(File(installed('demo')).readAsStringSync(), 'cli');
    expect(File(installed('demo-server')).readAsStringSync(), 'server');
    if (windows) {
      expect(
        File(p.join(places.bindirLib, 'libmodel.so')).existsSync(),
        isTrue,
        reason: 'a copy in bin/ loads ../lib',
      );
    } else {
      expect(
        Link(installed('demo')).targetSync(),
        p.join(places.bin, 'demo_cli'),
      );
    }
    expect(said.where((line) => line.contains('not on PATH')), hasLength(2));
  });

  test(
    'a second install replaces the first, and its retired commands go',
    () async {
      bundles();
      await cliInstall(_cli)(context());
      File(p.join(places.bin, 'stale')).writeAsStringSync('left over');
      File(installed('demo-old'))
        ..createSync(recursive: true)
        ..writeAsStringSync('an older command');

      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(File(p.join(places.bin, 'stale')).existsSync(), isFalse);
      expect(File(installed('demo-old')).existsSync(), isFalse);
    },
  );

  test(
    'two different libraries of one name are refused, before anything',
    () async {
      bundles();
      write('build/server/bundle/lib/libshared.so', 'another build');

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('libshared.so differs'));
      expect(Directory(places.share).existsSync(), isFalse);
    },
  );

  test('a command whose executable no bundle has is refused', () async {
    bundles();
    File(
      p.join(root.path, 'build/server/bundle/bin/${exe('demo_server')}'),
    ).deleteSync();

    expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
    expect(said.single, contains('which no bundle has'));
  });

  test('a bundle that was never built is refused', () async {
    expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
    expect(said.single, contains('build it first'));
  });

  test('uninstalling removes it all, and twice is fine', () async {
    bundles();
    await cliInstall(_cli)(context());

    expect(await cliUninstall(_cli)(context()), ExitCode.success);
    for (final gone in [installed('demo'), installed('demo-server')]) {
      expect(
        FileSystemEntity.typeSync(gone, followLinks: false),
        FileSystemEntityType.notFound,
      );
    }
    expect(Directory(places.bin).existsSync(), isFalse);
    if (windows) {
      expect(
        File(p.join(places.bindirLib, 'libmodel.so')).existsSync(),
        isFalse,
      );
    }
    expect(await cliUninstall(_cli)(context()), ExitCode.success);
  });
}
