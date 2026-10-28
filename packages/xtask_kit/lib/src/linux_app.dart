/// Installing a built Linux app for whoever runs the verb: under `~/.local`,
/// on `PATH` by a link, and in the desktop's menu.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

import 'home.dart';
import 'on_path.dart';
import 'replace.dart';

/// A built Linux app, and what [linuxAppInstall] needs to know to install it.
///
/// Data, not steps: what is built, under which names. Building it is a task
/// of its own — a `run:` the install task `needs:` — so that a build failure
/// is reported as the build's, and `--dry-run` shows the command.
final class LinuxApp {
  const LinuxApp({
    required this.binary,
    required this.applicationId,
    required this.bundle,
    required this.desktopEntry,
    this.contents,
    this.requires = const [],
    this.icons,
    this.adopt,
  });

  /// The executable's file name in [bundle], and the command it goes onto
  /// `PATH` as.
  final String binary;

  /// The app's id: the name of its menu entry and of its icons, and the
  /// `StartupWMClass` a desktop matches a window to the entry by. Flutter's
  /// `APPLICATION_ID`.
  final String applicationId;

  /// The built app — [binary] with its `lib/` and `data/` beside it — from
  /// the root.
  final String bundle;

  /// What of [bundle] is installed, by name; null for all of it. A staged
  /// release that also carries its `README` and its licences names the three
  /// the app runs from.
  final List<String>? contents;

  /// Files, from [bundle], without which it is not the app to install — a
  /// release build's `lib/libapp.so`, say, which a debug one lacks. [binary]
  /// is always required and need not be listed.
  final List<String> requires;

  /// The menu entry, from the root. Its `Exec=` and `TryExec=` name the bare
  /// [binary]; what is installed names the link instead, which works where
  /// the session's `PATH` has no `~/.local/bin` on it — a login from a
  /// display manager, typically.
  final String desktopEntry;

  /// The app's icons, or null for none.
  final LinuxIcons? icons;

  /// What shows a `~/.local/lib/<binary>` without the install's mark to be
  /// the app's own earlier install, to replace and remove like a marked one;
  /// null for none, which refuses it. [EarlierInstall.linked] takes
  /// `~/.local/bin/<binary>` leading into it as that.
  final EarlierInstall? adopt;
}

/// Where a [LinuxApp]'s icons come from.
sealed class LinuxIcons {
  const LinuxIcons();
}

/// Icons already laid out as a hicolor theme — `256x256/apps/<id>.png` and
/// so on — in [directory], from the root. All of it is copied, and what
/// [linuxAppUninstall] removes is what is named for the app's id, so a file
/// in the tree named otherwise stays behind.
final class IconTree extends LinuxIcons {
  const IconTree(this.directory);

  final String directory;
}

/// Icons one file at a time: each source, from the root, by where it goes
/// in the hicolor theme.
///
/// `IconFiles({'256x256/apps/my.app.png': 'assets/icon-256.png'})`.
final class IconFiles extends LinuxIcons {
  const IconFiles(this.files);

  final Map<String, String> files;
}

/// Where a [LinuxApp] is installed for a person whose home is `home`.
final class LinuxAppPlaces {
  /// The places for [app] under [home], the data ones under `XDG_DATA_HOME`
  /// from [environment] when it is set and absolute.
  factory LinuxAppPlaces.of(
    LinuxApp app, {
    required String home,
    Map<String, String> environment = const {},
  }) {
    final data = dataHome(environment, home: home);
    return LinuxAppPlaces._(
      app: p.join(home, '.local', 'lib', app.binary),
      binary: p.join(home, '.local', 'bin', app.binary),
      desktopEntry: p.join(
        data,
        'applications',
        '${app.applicationId}.desktop',
      ),
      icons: p.join(data, 'icons', 'hicolor'),
    );
  }

  const LinuxAppPlaces._({
    required this.app,
    required this.binary,
    required this.desktopEntry,
    required this.icons,
  });

  /// The app's own directory: what [LinuxApp.bundle] holds.
  final String app;

  /// The link onto `PATH`.
  final String binary;

  /// The menu entry.
  final String desktopEntry;

  /// The hicolor theme the icons go into.
  final String icons;
}

/// `do:` a verb installing [app] for whoever runs it, on Linux:
///
/// - the bundle into `~/.local/lib/<binary>`, replacing an earlier one whole
///   ([replaceDirectory]) and marked as the app's ([markDirectory]);
/// - `~/.local/bin/<binary>`, a link to it;
/// - the menu entry into `$XDG_DATA_HOME/applications` (`~/.local/share`
///   without it), starting that link;
/// - the icons into `$XDG_DATA_HOME/icons/hicolor`.
///
/// It refuses, naming why, off Linux, without `HOME`, when the bundle lacks
/// what [LinuxApp.requires] says it has, when `~/.local/bin/<binary>` is
/// something other than a link into the app's directory, and when
/// `~/.local/lib/<binary>` is there without the app's mark and
/// [LinuxApp.adopt] does not show it the app's — either would be somebody
/// else's. It ends by saying whether `PATH` reaches what it installed
/// ([onPathLine]).
Verb linuxAppInstall(LinuxApp app) =>
    (context) => _install(context, app);

/// `do:` a verb removing what [linuxAppInstall] laid down for [app].
///
/// Tolerant and safe to repeat: a teardown that fails on a machine already
/// clean is a puzzle rather than a tool. Where `~/.local/bin/<binary>` is
/// not a link into the app's directory, or that directory is there without
/// the app's mark or what [LinuxApp.adopt] asks, the install is somebody
/// else's: nothing at all is removed — the menu entry and the icons by the
/// same name are that install's too — and it says why and succeeds. Off
/// Linux there is nothing it could have installed, and it says so and
/// succeeds.
Verb linuxAppUninstall(LinuxApp app) =>
    (context) => _uninstall(context, app);

/// The desktop entry [text] with its `Exec=` and `TryExec=` starting
/// [installed], an absolute path, where they started the bare [binary]; its
/// other lines as they are.
///
/// **`Exec=` is a command line and `TryExec=` is a path**, so the desktop
/// entry specification writes them differently. In `Exec=` a path with a
/// space or another reserved character is quoted — unquoted, a home of
/// `/home/my name` starts `/home/my` — with `"`, `` ` ``, `$` and `\`
/// escaped inside the quotes, every `\` then doubled because the value is a
/// string, and `%` written `%%` because it would start a field code.
/// `TryExec=` is the path unquoted, but a string all the same, so its `\` is
/// written `\\` too.
String installedDesktopEntry(
  String text, {
  required String binary,
  required String installed,
}) => text.replaceAllMapped(
  RegExp('^(Exec|TryExec)=${RegExp.escape(binary)}(?=\\s|\$)', multiLine: true),
  (match) => switch (match[1]) {
    'Exec' => 'Exec=${_execArgument(installed)}',
    _ => 'TryExec=${installed.replaceAll(r'\', r'\\')}',
  },
);

/// [argument] as one argument of an `Exec=` line, by the desktop entry
/// specification's rules for one.
String _execArgument(String argument) {
  // The characters the specification reserves, which an argument holding
  // any of them has to be quoted for.
  final reserved = RegExp('[ \\t\\n"\'\\\\><~|&;\$*?#()`]');
  final quoted = reserved.hasMatch(argument)
      ? '"${argument.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}')}"'
      : argument;
  return quoted.replaceAll(r'\', r'\\').replaceAll('%', '%%');
}

/// What the bundle at [bundle] lacks of [app], as a sentence, or null when
/// it has it all.
String? missingFromBundle(LinuxApp app, String bundle) {
  if (!Directory(bundle).existsSync()) {
    return 'there is no bundle at $bundle — build it first';
  }
  for (final file in [app.binary, ...app.requires]) {
    if (FileSystemEntity.typeSync(p.join(bundle, file)) ==
        FileSystemEntityType.notFound) {
      return '$bundle has no $file — build it first';
    }
  }
  for (final name in app.contents ?? const <String>[]) {
    if (FileSystemEntity.typeSync(p.join(bundle, name)) ==
        FileSystemEntityType.notFound) {
      return '$bundle has no $name, which the install is to copy';
    }
  }
  return null;
}

Future<int> _install(VerbContext context, LinuxApp app) async {
  if (!Platform.isLinux) {
    context.log('installing ${app.binary} this way is for Linux only');
    return ExitCode.taskFailed;
  }
  final home = homeOf(context.env, windows: false);
  if (home == null) {
    context.log('HOME is not set');
    return ExitCode.taskFailed;
  }
  final bundle = context.directory(app.bundle).path;
  if (missingFromBundle(app, bundle) case final missing?) {
    context.log(missing);
    return ExitCode.taskFailed;
  }
  final places = LinuxAppPlaces.of(app, home: home, environment: context.env);
  if (notOurLink(places.binary, within: places.app) case final refusal?) {
    context.log(refusal);
    return ExitCode.taskFailed;
  }
  // Read before anything is replaced: a missing entry or icon is a mistake
  // in the project's description of itself, and finding it after the swap
  // leaves a new app with an old menu entry.
  final entry = context.file(app.desktopEntry);
  if (!entry.existsSync()) {
    context.log('there is no menu entry at ${entry.path}');
    return ExitCode.taskFailed;
  }
  if (app.icons case IconTree(
    :final directory,
  ) when !context.directory(directory).existsSync()) {
    context.log('there are no icons at ${context.directory(directory).path}');
    return ExitCode.taskFailed;
  }
  final icons = _icons(context, app.icons);
  for (final MapEntry(key: to, value: source) in icons.entries) {
    // Where an icon goes is the project's to write and the theme's to hold:
    // a destination that leaves the theme would be a file written anywhere
    // in the person's home.
    if (p.isAbsolute(to) || p.split(to).contains('..')) {
      context.log('an icon cannot go to $to, which is outside the theme');
      return ExitCode.taskFailed;
    }
    if (!File(source).existsSync()) {
      context.log('there is no icon at $source');
      return ExitCode.taskFailed;
    }
  }

  final replaced = await replaceDirectory(
    context,
    sources: [
      for (final name
          in app.contents ??
              [
                for (final entry in Directory(bundle).listSync())
                  p.basename(entry.path),
              ])
        p.join(bundle, name),
    ],
    into: places.app,
    owner: _owner(app),
    adopt: app.adopt,
    links: [places.binary],
  );
  if (replaced != ExitCode.success) {
    return replaced;
  }

  final target = p.join(places.app, app.binary);
  pointLink(places.binary, target);
  File(places.desktopEntry)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      installedDesktopEntry(
        entry.readAsStringSync(),
        binary: app.binary,
        installed: places.binary,
      ),
    );
  for (final MapEntry(key: to, value: from) in icons.entries) {
    final file = File(p.join(places.icons, to));
    file.parent.createSync(recursive: true);
    File(from).copySync(file.path);
  }

  context
    ..log('✓ ${app.binary} in ${places.app}')
    ..log('  ${places.binary} -> $target')
    ..log('  ${places.desktopEntry}')
    ..log(
      onPathLine(
        context.env,
        command: app.binary,
        installed: places.binary,
        windows: false,
      ),
    );
  return ExitCode.success;
}

Future<int> _uninstall(VerbContext context, LinuxApp app) async {
  final home = homeOf(context.env, windows: false);
  if (!Platform.isLinux || home == null) {
    context.log('${app.binary}: nothing installed here to remove');
    return ExitCode.success;
  }
  final places = LinuxAppPlaces.of(app, home: home, environment: context.env);
  // All or nothing: a link another installer made under the same name, or a
  // directory of that name without the mark, says the app installed here is
  // somebody else's, and the menu entry and icons named for its id are then
  // theirs as well.
  if (notOurLink(places.binary, within: places.app) ??
          notOurDirectory(
            places.app,
            owner: _owner(app),
            adopt: app.adopt,
            links: [places.binary],
          )
      case final why?) {
    context.log('$why — nothing removed');
    return ExitCode.success;
  }
  // Marked before anything goes, where it was taken as the app's on
  // [LinuxApp.adopt]'s evidence: the link that may be that evidence goes
  // first, and a run stopped after it would find the directory nobody's.
  if (Directory(places.app).existsSync()) {
    markDirectory(places.app, owner: _owner(app));
  }
  if (FileSystemEntity.typeSync(places.binary, followLinks: false) ==
      FileSystemEntityType.link) {
    Link(places.binary).deleteSync();
  }
  // The install lays the directory down before anything else and the
  // uninstall removes it last, so without it the menu entry and icons by
  // the app's id were not laid down by this install: only the link into it,
  // dangling, is.
  if (!Directory(places.app).existsSync()) {
    context.log('${app.binary}: nothing installed in ${places.app}');
    return ExitCode.success;
  }
  if (File(places.desktopEntry).existsSync()) {
    File(places.desktopEntry).deleteSync();
  }
  // By name rather than by list: the icons a tree held at install time are
  // not known now, and every icon this install lays down is named for the
  // app — `<size>/apps/<id>.<ext>` — which is also what makes it this app's.
  final theme = Directory(places.icons);
  if (theme.existsSync()) {
    for (final size in theme.listSync().whereType<Directory>()) {
      final apps = Directory(p.join(size.path, 'apps'));
      if (!apps.existsSync()) {
        continue;
      }
      for (final icon in apps.listSync().whereType<File>()) {
        if (p.basenameWithoutExtension(icon.path) == app.applicationId) {
          icon.deleteSync();
        }
      }
    }
  }
  if (Directory(places.app).existsSync()) {
    deleteMarkLast(Directory(places.app));
  }
  context.log('✓ ${app.binary} removed from ${places.app}');
  return ExitCode.success;
}

/// Who [app]'s directory belongs to, as its mark says: by the id, which is
/// what names the menu entry and the icons the uninstall would remove too.
String _owner(LinuxApp app) => 'linux-app ${app.applicationId}';

/// Each icon's source, absolute, by where it goes in the hicolor theme.
Map<String, String> _icons(VerbContext context, LinuxIcons? icons) =>
    switch (icons) {
      null => const {},
      IconFiles(:final files) => {
        for (final MapEntry(key: to, value: from) in files.entries)
          to: context.file(from).path,
      },
      IconTree(:final directory) => {
        for (final file
            in context
                .directory(directory)
                .listSync(recursive: true)
                .whereType<File>())
          p.relative(file.path, from: context.directory(directory).path):
              file.path,
      },
    };
