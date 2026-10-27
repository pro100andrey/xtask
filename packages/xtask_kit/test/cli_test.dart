import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
// For the Windows rules on any machine: `installCliOn` takes the platform as
// an argument, which the exported verbs read from the process.
import 'package:xtask_kit/src/cli.dart' show installCliOn, uninstallCliOn;
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

  /// The two bundles, their executables named as [windowsNames] says or as
  /// this platform names them.
  void bundles({bool? windowsNames}) {
    String exe(String name) => (windowsNames ?? windows) ? '$name.exe' : name;
    write('build/cli/bundle/bin/${exe('demo_cli')}', 'cli');
    write('build/cli/bundle/lib/libshared.so', 'shared');
    write('build/server/bundle/bin/${exe('demo_server')}', 'server');
    write('build/server/bundle/lib/libshared.so', 'shared');
    write('build/server/bundle/lib/libmodel.so', 'model');
  }

  String installed(String command) => p.join(places.bindir, exe(command));

  /// An install under the Windows rules, whatever this machine is.
  Future<int> windowsInstall() => installCliOn(context(), _cli, windows: true);

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
      // What an earlier version laid down: a link on POSIX, a copy of an
      // installed executable on Windows.
      if (windows) {
        File(
          p.join(places.bin, exe('demo_cli')),
        ).copySync(installed('demo-old'));
      } else {
        Link(installed('demo-old')).createSync(p.join(places.bin, 'gone'));
      }

      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(File(p.join(places.bin, 'stale')).existsSync(), isFalse);
      expect(
        FileSystemEntity.typeSync(installed('demo-old'), followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
  );

  group("somebody else's file on PATH", () {
    test('is refused on POSIX, and left as it was', () async {
      bundles();
      File(installed('demo'))
        ..createSync(recursive: true)
        ..writeAsStringSync('my own demo');

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('is not a link'));
      expect(File(installed('demo')).readAsStringSync(), 'my own demo');
      expect(Directory(places.share).existsSync(), isFalse);
    }, testOn: '!windows');

    test('under a retired name too', () async {
      bundles();
      File(installed('demo-old'))
        ..createSync(recursive: true)
        ..writeAsStringSync('my own demo-old');

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(File(installed('demo-old')).readAsStringSync(), 'my own demo-old');
    }, testOn: '!windows');

    group('where retired names are to be left', () {
      const leaving = DartCli(
        name: 'demo',
        bundles: ['build/cli/bundle', 'build/server/bundle'],
        commands: {'demo': 'demo_cli', 'demo-server': 'demo_server'},
        retired: ['demo-old'],
        foreignRetired: ForeignRetired.leave,
      );

      test('one under a retired name is left, with a warning', () async {
        bundles();
        File(installed('demo-old'))
          ..createSync(recursive: true)
          ..writeAsStringSync('my own demo-old');

        expect(await cliInstall(leaving)(context()), ExitCode.success);
        expect(
          File(installed('demo-old')).readAsStringSync(),
          'my own demo-old',
        );
        expect(
          said.first,
          startsWith('⚠ ${installed('demo-old')} is not a link'),
        );
        expect(said.first, endsWith('retired, so left as it is'));
      });

      test('while a link it made under that name still goes', () async {
        bundles();
        Link(installed('demo-old'))
          ..parent.createSync(recursive: true)
          ..createSync(p.join(places.bin, 'gone'));

        expect(await cliInstall(leaving)(context()), ExitCode.success);
        expect(
          FileSystemEntity.typeSync(installed('demo-old'), followLinks: false),
          FileSystemEntityType.notFound,
        );
      });

      test("and one under a command's name is still refused", () async {
        bundles();
        File(installed('demo'))
          ..createSync(recursive: true)
          ..writeAsStringSync('my own demo');

        expect(await cliInstall(leaving)(context()), ExitCode.taskFailed);
        expect(File(installed('demo')).readAsStringSync(), 'my own demo');
      });
    }, testOn: '!windows');

    test('and an uninstall leaves it, saying so', () async {
      File(installed('demo'))
        ..createSync(recursive: true)
        ..writeAsStringSync('my own demo');

      expect(await cliUninstall(_cli)(context()), ExitCode.success);
      expect(File(installed('demo')).readAsStringSync(), 'my own demo');
      expect(said.join('\n'), contains('is not a link'));
    }, testOn: '!windows');

    test(
      'is refused on Windows unless it is a copy this install made',
      () async {
        bundles(windowsNames: true);
        File(p.join(home.path, '.local', 'bin', 'demo.exe'))
          ..createSync(recursive: true)
          ..writeAsStringSync('my own demo');

        expect(await windowsInstall(), ExitCode.taskFailed);
        expect(said.single, contains('not a copy'));
        expect(
          File(
            p.join(home.path, '.local', 'bin', 'demo.exe'),
          ).readAsStringSync(),
          'my own demo',
        );
      },
    );

    test('and left by a Windows uninstall', () async {
      final mine = File(p.join(home.path, '.local', 'bin', 'demo.exe'))
        ..createSync(recursive: true)
        ..writeAsStringSync('my own demo');

      expect(
        await uninstallCliOn(context(), _cli, windows: true),
        ExitCode.success,
      );
      expect(mine.readAsStringSync(), 'my own demo');
    });

    test('and a copy it made is replaced, retired or not', () async {
      final bin = p.join(home.path, '.local', 'bin');
      bundles(windowsNames: true);
      expect(await windowsInstall(), ExitCode.success);
      File(p.join(bin, 'demo.exe')).copySync(p.join(bin, 'demo-old.exe'));
      write('build/cli/bundle/bin/demo_cli.exe', 'cli, rebuilt');

      expect(await windowsInstall(), ExitCode.success);
      expect(File(p.join(bin, 'demo.exe')).readAsStringSync(), 'cli, rebuilt');
      expect(File(p.join(bin, 'demo-old.exe')).existsSync(), isFalse);
    });
  });

  group("somebody else's link on PATH", () {
    // pipx, `uv tool` and others lay down links in `~/.local/bin` too; only
    // one into this install's own directory is this install's.
    late String theirs;

    setUp(() {
      theirs = p.join(home.path, '.local', 'pipx', 'venvs', 'demo', 'demo');
      File(theirs)
        ..createSync(recursive: true)
        ..writeAsStringSync('their demo');
    });

    test('is refused by an install, and left as it was', () async {
      bundles();
      Link(installed('demo'))
        ..parent.createSync(recursive: true)
        ..createSync(theirs);

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not a link this install made'));
      expect(Link(installed('demo')).targetSync(), theirs);
      expect(Directory(places.share).existsSync(), isFalse);
    });

    test('and left by an uninstall, under a retired name too', () async {
      for (final command in ['demo', 'demo-old']) {
        Link(installed(command))
          ..parent.createSync(recursive: true)
          ..createSync(theirs);
      }

      expect(await cliUninstall(_cli)(context()), ExitCode.success);
      expect(Link(installed('demo')).targetSync(), theirs);
      expect(Link(installed('demo-old')).targetSync(), theirs);
      expect(said.join('\n'), contains('left as it is'));
    });
  }, testOn: '!windows');

  group("somebody else's directory under ~/.local/share", () {
    // `~/.local/share/<name>` is a name any application may have taken; a
    // directory there is this install's only where its mark says so.
    late File theirs;

    setUp(() {
      theirs = File(p.join(places.share, 'bin', 'their-file'))
        ..createSync(recursive: true)
        ..writeAsStringSync('theirs');
    });

    test('is refused by an install, and left as it was', () async {
      bundles();

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not a directory this install made'));
      expect(theirs.readAsStringSync(), 'theirs');
      expect(Directory(places.bin).listSync(), hasLength(1));
      expect(Directory('${places.share}.new').existsSync(), isFalse);
    });

    test('and so is one marked by another owner', () async {
      bundles();
      File(p.join(places.share, '.xtask_kit')).writeAsStringSync('cli other');

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(theirs.readAsStringSync(), 'theirs');
    });

    test('and left whole by an uninstall, with what links into it', () async {
      Link(installed('demo'))
        ..parent.createSync(recursive: true)
        ..createSync(theirs.path);

      expect(await cliUninstall(_cli)(context()), ExitCode.success);
      expect(theirs.readAsStringSync(), 'theirs');
      expect(Link(installed('demo')).targetSync(), theirs.path);
      expect(said.single, contains('nothing removed'));
    }, testOn: '!windows');

    test('while its own install, marked, is replaced and removed', () async {
      theirs.parent.parent.deleteSync(recursive: true);
      bundles();
      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(await cliUninstall(_cli)(context()), ExitCode.success);
      expect(Directory(places.share).existsSync(), isFalse);
    });
  });

  group('an install from before the mark', () {
    // What a project's own verbs laid down before it used this package: the
    // tool's directory, unmarked, with a stamp only they wrote.
    late File earlier;

    setUp(() {
      earlier = File(p.join(places.bin, exe('demo_cli')))
        ..createSync(recursive: true)
        ..writeAsStringSync('earlier build');
    });

    DartCli adopting(EarlierInstall adopt) => DartCli(
      name: _cli.name,
      bundles: _cli.bundles,
      commands: _cli.commands,
      retired: _cli.retired,
      adopt: adopt,
    );

    test('is replaced where a command on PATH links into it', () async {
      bundles();
      Link(installed('demo'))
        ..parent.createSync(recursive: true)
        ..createSync(earlier.path);

      final cli = adopting(const EarlierInstall(linked: true));
      expect(await cliInstall(cli)(context()), ExitCode.success);
      expect(earlier.readAsStringSync(), 'cli');
      expect(
        File(p.join(places.share, ownerMark)).readAsStringSync(),
        'cli demo\n',
      );
    }, testOn: '!windows');

    test('or a retired one does', () async {
      bundles();
      Link(installed('demo-old'))
        ..parent.createSync(recursive: true)
        ..createSync(earlier.path);

      final cli = adopting(const EarlierInstall(linked: true));
      expect(await cliInstall(cli)(context()), ExitCode.success);
      expect(
        FileSystemEntity.typeSync(installed('demo-old'), followLinks: false),
        FileSystemEntityType.notFound,
      );
    }, testOn: '!windows');

    test('or where it holds the file named as its trace', () async {
      bundles();
      File(p.join(places.bin, 'BUILD')).writeAsStringSync('commit=abc');

      final cli = adopting(const EarlierInstall(files: ['bin/BUILD']));
      expect(await cliInstall(cli)(context()), ExitCode.success);
      expect(File(p.join(places.bin, 'BUILD')).existsSync(), isFalse);
    });

    test('and removed by an uninstall on the same evidence', () async {
      File(p.join(places.bin, 'BUILD')).writeAsStringSync('commit=abc');

      final cli = adopting(const EarlierInstall(files: ['bin/BUILD']));
      expect(await cliUninstall(cli)(context()), ExitCode.success);
      expect(Directory(places.share).existsSync(), isFalse);
    });

    test('but is refused without the evidence asked for', () async {
      bundles();

      final cli = adopting(
        const EarlierInstall(linked: true, files: ['bin/BUILD']),
      );
      expect(await cliInstall(cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not a directory this install made'));
      expect(earlier.readAsStringSync(), 'earlier build');
    });
  });

  group('a library a bundle must not carry', () {
    DartCli forbidding(Map<String, List<String>> libraries) => DartCli(
      name: _cli.name,
      bundles: _cli.bundles,
      commands: _cli.commands,
      forbiddenLibraries: libraries,
    );

    test('is refused before anything is copied', () async {
      bundles();
      write('build/cli/bundle/lib/libmodel.so', 'model');

      final cli = forbidding({
        'build/cli/bundle': ['libmodel.so'],
      });
      expect(await cliInstall(cli)(context()), ExitCode.taskFailed);
      expect(
        said.single,
        'build/cli/bundle carries libmodel.so in its lib/, which it must not '
        '— check what its package depends on',
      );
      expect(Directory(places.share).existsSync(), isFalse);
      expect(Directory('${places.share}.new').existsSync(), isFalse);
    });

    test('while the bundle meant to carry it installs', () async {
      bundles();

      final cli = forbidding({
        'build/cli/bundle': ['libmodel.so'],
      });
      expect(await cliInstall(cli)(context()), ExitCode.success);
      expect(File(p.join(places.lib, 'libmodel.so')).existsSync(), isTrue);
    });

    test('and one named for no bundle is a mistake, said as one', () async {
      bundles();

      final cli = forbidding({
        'build/clii/bundle': ['libmodel.so'],
      });
      expect(await cliInstall(cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not one of the bundles'));
    });
  });

  group("the project's own steps", () {
    late List<String> steps;

    setUp(() => steps = []);

    DartCli stepping({CliStep? afterInstall, CliStep? beforeUninstall}) =>
        DartCli(
          name: _cli.name,
          bundles: _cli.bundles,
          commands: _cli.commands,
          afterInstall: afterInstall,
          beforeUninstall: beforeUninstall,
        );

    test('run after an install, with what it installed in place', () async {
      bundles();
      final cli = stepping(
        afterInstall: (context, at) async {
          steps.add(at.share);
          // What was installed is there to stamp beside.
          File(p.join(at.bin, 'BUILD')).writeAsStringSync('commit=abc');
          return ExitCode.success;
        },
      );

      expect(await cliInstall(cli)(context()), ExitCode.success);
      expect(steps, [places.share]);
      expect(File(p.join(places.bin, 'BUILD')).existsSync(), isTrue);
    });

    test("whose answer is the install's", () async {
      bundles();
      final cli = stepping(afterInstall: (context, at) async => 7);

      expect(await cliInstall(cli)(context()), 7);
    });

    test('and not where the install failed', () async {
      final cli = stepping(
        afterInstall: (context, at) async {
          steps.add('ran');
          return ExitCode.success;
        },
      );

      expect(await cliInstall(cli)(context()), ExitCode.taskFailed);
      expect(steps, isEmpty);
    });

    test('run before an uninstall, while what it removes is there', () async {
      bundles();
      final cli = stepping(
        beforeUninstall: (context, at) async {
          steps.add(
            File(p.join(at.bin, exe('demo_cli'))).existsSync()
                ? 'installed'
                : 'gone',
          );
          return ExitCode.success;
        },
      );
      await cliInstall(cli)(context());

      expect(await cliUninstall(cli)(context()), ExitCode.success);
      expect(steps, ['installed']);
      expect(Directory(places.share).existsSync(), isFalse);
    });

    test('which stops the uninstall where it fails', () async {
      bundles();
      final cli = stepping(beforeUninstall: (context, at) async => 1);
      await cliInstall(cli)(context());
      said.clear();

      expect(await cliUninstall(cli)(context()), 1);
      expect(said.single, contains('nothing removed'));
      expect(Directory(places.bin).existsSync(), isTrue);
    });

    test("and is not run over somebody else's install", () async {
      File(p.join(places.share, 'bin', 'their-file'))
        ..createSync(recursive: true)
        ..writeAsStringSync('theirs');
      final cli = stepping(
        beforeUninstall: (context, at) async {
          steps.add('ran');
          return ExitCode.success;
        },
      );

      expect(await cliUninstall(cli)(context()), ExitCode.success);
      expect(steps, isEmpty);
    });
  });

  test('an uninstall removes what a failed install left beside it', () async {
    final fresh = Directory('${places.share}.new');
    File(p.join(fresh.path, 'bin', 'half'))
      ..createSync(recursive: true)
      ..writeAsStringSync('half a copy');

    expect(await cliUninstall(_cli)(context()), ExitCode.success);
    expect(fresh.existsSync(), isFalse);
  });

  test(
    'an earlier install that cannot be removed does not fail this one',
    () async {
      bundles();
      expect(await cliInstall(_cli)(context()), ExitCode.success);
      // What stops the earlier install being deleted once it is moved
      // aside: a directory in it that cannot be written.
      final bin = Directory(places.bin);
      Process.runSync('chmod', ['555', bin.path]);
      addTearDown(() {
        for (final old in home.listSync(recursive: true)) {
          if (old is Directory) {
            Process.runSync('chmod', ['755', old.path]);
          }
        }
      });
      write('build/cli/bundle/bin/${exe('demo_cli')}', 'cli, rebuilt');

      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(File(installed('demo')).readAsStringSync(), 'cli, rebuilt');
      final share = Directory(p.dirname(places.share));
      final left = share
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.startsWith('demo.old-'))
          .toList();
      expect(left, hasLength(1), reason: 'moved aside, not removed');

      // Writable again, the next install takes away what this one could not.
      Process.runSync('chmod', [
        '755',
        p.join(share.path, left.single, 'bin'),
      ]);
      expect(await cliInstall(_cli)(context()), ExitCode.success);
      expect(
        share.listSync().map((e) => p.basename(e.path)),
        isNot(contains(startsWith('demo.old-'))),
      );
    },
    testOn: '!windows',
  );

  test(
    'a Windows copy onto PATH that broke off blocks no later install',
    () async {
      final bin = p.join(home.path, '.local', 'bin');
      bundles(windowsNames: true);
      expect(await windowsInstall(), ExitCode.success);
      // What a copy cut off halfway leaves: written under a name of its
      // own, the command itself either the earlier copy or not there yet.
      File(p.join(bin, 'demo.exe')).deleteSync();
      File(p.join(bin, 'demo.exe.new')).writeAsStringSync('cl');

      expect(await windowsInstall(), ExitCode.success);
      expect(File(p.join(bin, 'demo.exe')).readAsStringSync(), 'cli');
      expect(File(p.join(bin, 'demo.exe.new')).existsSync(), isFalse);

      File(p.join(bin, 'demo.exe.new')).writeAsStringSync('cl');
      expect(
        await uninstallCliOn(context(), _cli, windows: true),
        ExitCode.success,
      );
      expect(File(p.join(bin, 'demo.exe.new')).existsSync(), isFalse);
    },
  );

  test(
    'only what a Windows install moved aside is swept, and only there',
    () async {
      final bin = p.join(home.path, '.local', 'bin');
      bundles();
      bundles(windowsNames: true);
      for (final name in [
        'demo.old-backup',
        'demo.old-1700000000000',
        'demo.exe.old-backup',
        'demo.exe.old-1700000000000',
      ]) {
        File(p.join(bin, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('kept?');
      }

      if (!windows) {
        expect(await installCliOn(context(), _cli, windows: false), 0);
        expect(File(p.join(bin, 'demo.old-backup')).existsSync(), isTrue);
        expect(
          File(p.join(bin, 'demo.old-1700000000000')).existsSync(),
          isTrue,
        );
      }
      expect(await windowsInstall(), ExitCode.success);
      expect(File(p.join(bin, 'demo.exe.old-backup')).existsSync(), isTrue);
      expect(
        File(p.join(bin, 'demo.exe.old-1700000000000')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'a copy that fails halfway leaves the earlier install working',
    () async {
      bundles();
      expect(await cliInstall(_cli)(context()), ExitCode.success);
      write('build/cli/bundle/bin/${exe('demo_cli')}', 'cli, rebuilt');
      final unreadable = File(
        p.join(root.path, 'build/server/bundle/lib/libmodel.so'),
      );
      Process.runSync('chmod', ['000', unreadable.path]);
      addTearDown(() => Process.runSync('chmod', ['644', unreadable.path]));

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.last, contains('libmodel.so'));
      expect(said.last, contains('nothing installed was changed'));
      expect(File(installed('demo')).readAsStringSync(), 'cli');
      expect(
        Directory(places.lib).listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['libshared.so', 'libmodel.so']),
      );
    },
    testOn: '!windows',
  );

  test(
    'two different executables of one name are refused, before anything',
    () async {
      bundles();
      write('build/server/bundle/bin/${exe('demo_cli')}', 'another cli');

      expect(await cliInstall(_cli)(context()), ExitCode.taskFailed);
      expect(said.single, contains('${exe('demo_cli')} differs'));
      expect(Directory(places.share).existsSync(), isFalse);
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
