import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

const _app = LinuxApp(
  binary: 'demo',
  applicationId: 'dev.example.demo',
  bundle: 'build/bundle',
  desktopEntry: 'packaging/dev.example.demo.desktop',
  requires: ['lib/libapp.so'],
  icons: IconFiles({'64x64/apps/dev.example.demo.png': 'packaging/icon.png'}),
);

void main() {
  group('the desktop entry', () {
    test('starts the link instead of the bare name', () {
      expect(
        installedDesktopEntry(
          '[Desktop Entry]\nName=Demo\nExec=demo %U\nTryExec=demo\n',
          binary: 'demo',
          installed: '/home/me/.local/bin/demo',
        ),
        '[Desktop Entry]\nName=Demo\n'
        'Exec=/home/me/.local/bin/demo %U\n'
        'TryExec=/home/me/.local/bin/demo\n',
      );
    });

    test('quoting the path in Exec= where the spec says to', () {
      // A home with a space in it: unquoted, the session would start
      // `/home/my` with the rest as arguments.
      expect(
        installedDesktopEntry(
          'Exec=demo %U\nTryExec=demo\n',
          binary: 'demo',
          installed: r'/home/my "name"/$x\.local/100%/demo',
        ),
        'Exec="/home/my \\\\"name\\\\"/\\\\\$x\\\\\\\\.local/100%%/demo" %U\n'
        'TryExec=/home/my "name"/\$x\\\\.local/100%/demo\n',
      );
    });

    test(r'writing `\` in TryExec= as `\\`, since its value is a string', () {
      // The specification's string type escapes a backslash, so a reader
      // unescaping the value would not find `/home/a\b` written plainly.
      expect(
        installedDesktopEntry(
          'TryExec=demo\n',
          binary: 'demo',
          installed: r'/home/a\b/demo',
        ),
        r'TryExec=/home/a\\b/demo'
        '\n',
      );
    });

    test('and leaves a command that only begins with the name alone', () {
      const text = 'Exec=demo-helper\nExec=/usr/bin/demo\n';
      expect(
        installedDesktopEntry(text, binary: 'demo', installed: '/x/demo'),
        text,
      );
    });
  });

  group('the places', () {
    test('are under ~/.local, by the binary and the id', () {
      final places = LinuxAppPlaces.of(_app, home: '/home/me');
      expect(places.app, '/home/me/.local/lib/demo');
      expect(places.binary, '/home/me/.local/bin/demo');
      expect(
        places.desktopEntry,
        '/home/me/.local/share/applications/dev.example.demo.desktop',
      );
      expect(places.icons, '/home/me/.local/share/icons/hicolor');
    }, testOn: '!windows');

    test('and the data ones follow an absolute XDG_DATA_HOME only', () {
      expect(
        LinuxAppPlaces.of(
          _app,
          home: '/home/me',
          environment: {'XDG_DATA_HOME': '/data'},
        ).icons,
        '/data/icons/hicolor',
      );
      expect(
        LinuxAppPlaces.of(
          _app,
          home: '/home/me',
          environment: {'XDG_DATA_HOME': 'relative'},
        ).icons,
        '/home/me/.local/share/icons/hicolor',
      );
    }, testOn: '!windows');
  });

  group('installing', () {
    late Directory root;
    late Directory home;
    late List<String> said;

    VerbContext context({Map<String, String>? env}) => VerbContext(
      args: const [],
      env: env ?? {'HOME': home.path, 'PATH': ''},
      root: root.path,
      workingDirectory: root.path,
      log: said.add,
      start: (argv, {workingDirectory}) async => (await Process.run(
        argv.first,
        argv.skip(1).toList(),
        workingDirectory: workingDirectory,
      )).exitCode,
    );

    void bundle() {
      for (final file in [
        'build/bundle/demo',
        'build/bundle/lib/libapp.so',
        'build/bundle/data/icudtl.dat',
      ]) {
        File(p.join(root.path, file))
          ..createSync(recursive: true)
          ..writeAsStringSync(file);
      }
      File(p.join(root.path, _app.desktopEntry))
        ..createSync(recursive: true)
        ..writeAsStringSync('[Desktop Entry]\nExec=demo\n');
      File(p.join(root.path, 'packaging/icon.png')).writeAsStringSync('png');
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('xtask_kit_root_');
      home = Directory.systemTemp.createTempSync('xtask_kit_home_');
      said = [];
    });

    tearDown(() {
      root.deleteSync(recursive: true);
      home.deleteSync(recursive: true);
    });

    test('lays down the app, the link, the entry and the icons', () async {
      bundle();
      expect(await linuxAppInstall(_app)(context()), ExitCode.success);

      final places = LinuxAppPlaces.of(_app, home: home.path);
      expect(
        File(p.join(places.app, 'lib', 'libapp.so')).readAsStringSync(),
        'build/bundle/lib/libapp.so',
      );
      expect(
        Link(places.binary).targetSync(),
        p.join(places.app, 'demo'),
      );
      expect(
        File(places.desktopEntry).readAsStringSync(),
        '[Desktop Entry]\nExec=${places.binary}\n',
      );
      expect(
        File(
          p.join(places.icons, '64x64/apps/dev.example.demo.png'),
        ).readAsStringSync(),
        'png',
      );
      expect(said.last, contains('is not on PATH'));
    });

    test('and replaces an earlier install whole', () async {
      bundle();
      await linuxAppInstall(_app)(context());
      final places = LinuxAppPlaces.of(_app, home: home.path);
      File(p.join(places.app, 'stale')).writeAsStringSync('left over');

      expect(await linuxAppInstall(_app)(context()), ExitCode.success);
      expect(File(p.join(places.app, 'stale')).existsSync(), isFalse);
      expect(Directory('${places.app}.new').existsSync(), isFalse);
      expect(Directory('${places.app}.old').existsSync(), isFalse);
    });

    test('says PATH reaches it where it does', () async {
      bundle();
      final bin = p.join(home.path, '.local', 'bin');
      await linuxAppInstall(
        _app,
      )(context(env: {'HOME': home.path, 'PATH': bin}));
      expect(said.last, '✓ ${p.join(bin, 'demo')}');
    });

    test(
      'refuses a bundle without what it requires, before touching anything',
      () async {
        bundle();
        File(p.join(root.path, 'build/bundle/lib/libapp.so')).deleteSync();

        expect(await linuxAppInstall(_app)(context()), ExitCode.taskFailed);
        expect(said.single, contains('has no lib/libapp.so'));
        expect(
          Directory(p.join(home.path, '.local')).existsSync(),
          isFalse,
        );
      },
    );

    test('refuses to replace a file that is not a link', () async {
      bundle();
      final binary = LinuxAppPlaces.of(_app, home: home.path).binary;
      File(binary)
        ..createSync(recursive: true)
        ..writeAsStringSync('somebody else');

      expect(await linuxAppInstall(_app)(context()), ExitCode.taskFailed);
      expect(said.single, contains('is not a link'));
      expect(File(binary).readAsStringSync(), 'somebody else');
    });

    test('replaces a dangling link of an earlier install', () async {
      bundle();
      final places = LinuxAppPlaces.of(_app, home: home.path);
      // Relative, as a link may be, and into an install that is gone: it is
      // still this install's, since it leads into the app's own directory.
      Link(
        places.binary,
      ).createSync('../lib/demo/gone/demo', recursive: true);

      expect(await linuxAppInstall(_app)(context()), ExitCode.success);
      expect(Link(places.binary).targetSync(), p.join(places.app, 'demo'));
    });

    test('refuses to replace a link another installer made', () async {
      bundle();
      final binary = LinuxAppPlaces.of(_app, home: home.path).binary;
      final foreign = p.join(home.path, '.local/share/pipx/venvs/demo/demo');
      Link(binary).createSync(foreign, recursive: true);

      expect(await linuxAppInstall(_app)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not a link this install made'));
      expect(Link(binary).targetSync(), foreign);
    });

    test('refuses an icon that would land outside the theme', () async {
      bundle();
      const escaping = LinuxApp(
        binary: 'demo',
        applicationId: 'dev.example.demo',
        bundle: 'build/bundle',
        desktopEntry: 'packaging/dev.example.demo.desktop',
        icons: IconFiles({'../../../.bashrc': 'packaging/icon.png'}),
      );
      expect(await linuxAppInstall(escaping)(context()), ExitCode.taskFailed);
      expect(said.single, contains('outside the theme'));
    });

    test('copies only the contents named, where they are', () async {
      bundle();
      File(
        p.join(root.path, 'build/bundle/README'),
      ).writeAsStringSync('not the app');
      const staged = LinuxApp(
        binary: 'demo',
        applicationId: 'dev.example.demo',
        bundle: 'build/bundle',
        desktopEntry: 'packaging/dev.example.demo.desktop',
        contents: ['demo', 'lib', 'data'],
      );
      expect(await linuxAppInstall(staged)(context()), ExitCode.success);
      final app = LinuxAppPlaces.of(staged, home: home.path).app;
      expect(File(p.join(app, 'README')).existsSync(), isFalse);
      expect(File(p.join(app, 'demo')).existsSync(), isTrue);
    });

    test('takes the icons of a hicolor tree as they are laid out', () async {
      bundle();
      File(p.join(root.path, 'icons/128x128/apps/dev.example.demo.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('tree png');
      const tree = LinuxApp(
        binary: 'demo',
        applicationId: 'dev.example.demo',
        bundle: 'build/bundle',
        desktopEntry: 'packaging/dev.example.demo.desktop',
        icons: IconTree('icons'),
      );
      expect(await linuxAppInstall(tree)(context()), ExitCode.success);
      expect(
        File(
          p.join(
            LinuxAppPlaces.of(tree, home: home.path).icons,
            '128x128/apps/dev.example.demo.png',
          ),
        ).readAsStringSync(),
        'tree png',
      );
    });

    test('and uninstalling removes what it laid down, and only that', () async {
      bundle();
      await linuxAppInstall(_app)(context());
      final places = LinuxAppPlaces.of(_app, home: home.path);
      final neighbour = File(p.join(places.icons, '64x64/apps/other.png'))
        ..writeAsStringSync('another app');

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      for (final gone in [places.app, places.binary, places.desktopEntry]) {
        expect(
          FileSystemEntity.typeSync(gone, followLinks: false),
          FileSystemEntityType.notFound,
          reason: gone,
        );
      }
      expect(neighbour.existsSync(), isTrue);

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
    });

    test('refuses to replace a directory it did not lay down', () async {
      bundle();
      final places = LinuxAppPlaces.of(_app, home: home.path);
      // An app unpacked there by hand, with no link onto PATH at all.
      final unpacked = File(p.join(places.app, 'demo'))
        ..createSync(recursive: true)
        ..writeAsStringSync('unpacked by hand');

      expect(await linuxAppInstall(_app)(context()), ExitCode.taskFailed);
      expect(said.single, contains('not a directory this install made'));
      expect(unpacked.readAsStringSync(), 'unpacked by hand');
      for (final untouched in [places.binary, places.desktopEntry]) {
        expect(
          FileSystemEntity.typeSync(untouched, followLinks: false),
          FileSystemEntityType.notFound,
          reason: untouched,
        );
      }
    });

    group('an install from before the mark', () {
      // What a project's own verbs laid down before it used this package:
      // the app's directory, unmarked, and maybe its link onto PATH.
      late LinuxAppPlaces places;

      setUp(() {
        places = LinuxAppPlaces.of(_app, home: home.path);
        File(p.join(places.app, 'demo'))
          ..createSync(recursive: true)
          ..writeAsStringSync('earlier build');
      });

      LinuxApp adopting(EarlierInstall adopt) => LinuxApp(
        binary: _app.binary,
        applicationId: _app.applicationId,
        bundle: _app.bundle,
        desktopEntry: _app.desktopEntry,
        requires: _app.requires,
        icons: _app.icons,
        adopt: adopt,
      );

      test('is replaced where the link on PATH leads into it', () async {
        bundle();
        Link(places.binary).createSync(
          p.join(places.app, 'demo'),
          recursive: true,
        );

        final app = adopting(const EarlierInstall(linked: true));
        expect(await linuxAppInstall(app)(context()), ExitCode.success);
        expect(
          File(p.join(places.app, 'demo')).readAsStringSync(),
          'build/bundle/demo',
        );
        expect(
          File(p.join(places.app, ownerMark)).readAsStringSync(),
          'linux-app dev.example.demo\n',
        );
      });

      test('or where it holds the file named as its trace', () async {
        bundle();
        File(p.join(places.app, 'BUILD')).writeAsStringSync('commit=abc');

        final app = adopting(const EarlierInstall(files: ['BUILD']));
        expect(await linuxAppInstall(app)(context()), ExitCode.success);
        expect(File(p.join(places.app, 'BUILD')).existsSync(), isFalse);
      });

      test('and removed by an uninstall on the same evidence', () async {
        Link(places.binary).createSync(
          p.join(places.app, 'demo'),
          recursive: true,
        );

        final app = adopting(const EarlierInstall(linked: true));
        expect(await linuxAppUninstall(app)(context()), ExitCode.success);
        expect(Directory(places.app).existsSync(), isFalse);
        expect(
          FileSystemEntity.typeSync(places.binary, followLinks: false),
          FileSystemEntityType.notFound,
        );
      });

      test('but is refused without the evidence asked for', () async {
        bundle();
        // A link would show it, but only the trace was asked for.
        Link(places.binary).createSync(
          p.join(places.app, 'demo'),
          recursive: true,
        );

        final app = adopting(const EarlierInstall(files: ['BUILD']));
        expect(await linuxAppInstall(app)(context()), ExitCode.taskFailed);
        expect(said.single, contains('not a directory this install made'));
        expect(
          File(p.join(places.app, 'demo')).readAsStringSync(),
          'earlier build',
        );
      });

      test('and so is one marked by another owner, evidence or not', () async {
        bundle();
        File(p.join(places.app, 'BUILD')).writeAsStringSync('commit=abc');
        File(
          p.join(places.app, ownerMark),
        ).writeAsStringSync('linux-app other\n');

        final app = adopting(const EarlierInstall(files: ['BUILD']));
        expect(await linuxAppInstall(app)(context()), ExitCode.taskFailed);
        expect(
          File(p.join(places.app, 'demo')).readAsStringSync(),
          'earlier build',
        );
      });
    });

    /// Somebody else's install of the app, as another installer lays it
    /// down: its directory, its menu entry and its icon, none marked.
    List<String> theirs(LinuxAppPlaces places) {
      final paths = [
        p.join(places.app, 'demo'),
        places.desktopEntry,
        p.join(places.icons, '64x64/apps/dev.example.demo.png'),
      ];
      for (final path in paths) {
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync('theirs');
      }
      return paths;
    }

    test('and uninstalling removes nothing of an install that is not its '
        "own, where the link is somebody else's", () async {
      final places = LinuxAppPlaces.of(_app, home: home.path);
      final kept = theirs(places);
      final foreign = p.join(home.path, '.local/share/pipx/venvs/demo/demo');
      Link(places.binary).createSync(foreign, recursive: true);

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      for (final path in kept) {
        expect(File(path).readAsStringSync(), 'theirs', reason: path);
      }
      expect(said.single, contains('nothing removed'));
    });

    test('or where the directory has no mark of its own', () async {
      final places = LinuxAppPlaces.of(_app, home: home.path);
      final kept = theirs(places);
      // A link into the directory, as the other install made it.
      Link(
        places.binary,
      ).createSync(p.join(places.app, 'demo'), recursive: true);

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      for (final path in kept) {
        expect(File(path).readAsStringSync(), 'theirs', reason: path);
      }
      expect(Link(places.binary).existsSync(), isTrue);
      expect(said.single, contains('not a directory this install made'));
    });

    test('and keeps a binary that is not a link', () async {
      final binary = LinuxAppPlaces.of(_app, home: home.path).binary;
      File(binary)
        ..createSync(recursive: true)
        ..writeAsStringSync('somebody else');
      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      expect(File(binary).existsSync(), isTrue);
    });

    test('and keeps a link another installer made, saying so', () async {
      final binary = LinuxAppPlaces.of(_app, home: home.path).binary;
      final foreign = p.join(home.path, '.local/share/pipx/venvs/demo/demo');
      Link(binary).createSync(foreign, recursive: true);

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      expect(Link(binary).targetSync(), foreign);
      expect(said.join('\n'), contains('not a link this install made'));
    });

    test('and removes a dangling link into its own install', () async {
      final places = LinuxAppPlaces.of(_app, home: home.path);
      Link(
        places.binary,
      ).createSync(p.join(places.app, 'demo'), recursive: true);

      expect(await linuxAppUninstall(_app)(context()), ExitCode.success);
      expect(
        FileSystemEntity.typeSync(places.binary, followLinks: false),
        FileSystemEntityType.notFound,
      );
    });
  }, testOn: 'linux');
}
