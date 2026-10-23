/// Installing command-line tools built by `dart build cli` for whoever runs
/// the verb: under `~/.local`, and onto `PATH`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

import 'home.dart';
import 'on_path.dart';

/// Command-line tools built by `dart build cli`, and what [cliInstall] needs
/// to know to install them.
///
/// Each bundle is what that command leaves: `bin/` with the executables and
/// `lib/` with the native libraries they load from `../lib`. Several bundles
/// install into one `bin/` and one `lib/`, so that every executable finds
/// every library where it looks — which is why a library two bundles both
/// carry has to be the same file ([conflictingLibraries]).
final class DartCli {
  const DartCli({
    required this.name,
    required this.bundles,
    required this.commands,
    this.retired = const [],
  });

  /// The directory under `~/.local/share` the bundles go into.
  final String name;

  /// The bundles, from the root.
  final List<String> bundles;

  /// The commands put on `PATH`, each with the executable in a bundle's
  /// `bin/` it starts — both without `.exe`, which is added on Windows.
  final Map<String, String> commands;

  /// Commands an earlier version laid down and this one does not, removed by
  /// an install as well as an uninstall: a command left behind would go on
  /// starting a binary that is no longer there.
  final List<String> retired;
}

/// Where a [DartCli] is installed for a person whose home is `home`.
final class CliPlaces {
  CliPlaces.of(DartCli cli, {required String home, required this.windows})
    : share = p.join(home, '.local', 'share', cli.name),
      bindir = p.join(home, '.local', 'bin'),
      bindirLib = p.join(home, '.local', 'lib');

  /// Whether executables carry `.exe` and are copied rather than linked.
  final bool windows;

  /// Where the bundles are laid down: one `bin/` and one `lib/`.
  final String share;

  /// The directory on `PATH`.
  final String bindir;

  /// On Windows, the libraries the copies in [bindir] load: `../lib` from
  /// them, as from any Dart executable. A link resolves past it on POSIX.
  final String bindirLib;

  /// The installed `bin/`.
  String get bin => p.join(share, 'bin');

  /// The installed `lib/`.
  String get lib => p.join(share, 'lib');

  /// [name] as this platform spells an executable.
  String exe(String name) => windows ? '$name.exe' : name;
}

/// `do:` a verb installing [cli] for whoever runs it ([installCli]).
Verb cliInstall(DartCli cli) =>
    (context) => installCli(context, cli);

/// `do:` a verb removing what [cliInstall] laid down ([uninstallCli]).
Verb cliUninstall(DartCli cli) =>
    (context) => uninstallCli(context, cli);

/// Installs [cli] for whoever runs [context]'s task, and answers with an
/// [ExitCode]. A function as well as a verb, for a project whose install does
/// more after it — it calls this first and goes on where it succeeds.
///
/// - every bundle's `bin/` and `lib/` into `~/.local/share/<name>`, replacing
///   what an earlier install put there;
/// - each command at `~/.local/bin/<command>`: a link to its executable on
///   POSIX, a copy on Windows — no symlink without developer mode — with the
///   libraries copied to `~/.local/lib`, where the copy looks for them.
///
/// **Windows holds what is running.** A file a running process has open
/// cannot be deleted there — the very tool being reinstalled, serving an
/// editor — but it can be renamed, and the process keeps running from the
/// renamed file. So what cannot be removed is moved aside to
/// `<file>.old-<time>`, and the next install removes what nothing holds any
/// more.
///
/// It refuses, naming why, without a home, when a bundle has no `bin/` or a
/// command's executable is in none of them, and when two bundles carry
/// different files of one name for the shared `lib/`. It ends by saying
/// whether `PATH` reaches each command ([onPathLine]).
Future<int> installCli(VerbContext context, DartCli cli) async {
  final windows = Platform.isWindows;
  final home = homeOf(context.env, windows: windows);
  if (home == null) {
    context.log('no HOME${windows ? ' or USERPROFILE' : ''} is set');
    return ExitCode.taskFailed;
  }
  final places = CliPlaces.of(cli, home: home, windows: windows);
  final bundles = [
    for (final bundle in cli.bundles) context.directory(bundle).path,
  ];
  for (final bundle in bundles) {
    if (!Directory(p.join(bundle, 'bin')).existsSync()) {
      context.log('there is no bundle at $bundle — build it first');
      return ExitCode.taskFailed;
    }
  }
  for (final MapEntry(key: command, value: executable)
      in cli.commands.entries) {
    if (!bundles.any(
      (bundle) => File(
        p.join(bundle, 'bin', places.exe(executable)),
      ).existsSync(),
    )) {
      context.log(
        '`$command` starts ${places.exe(executable)}, which no bundle has',
      );
      return ExitCode.taskFailed;
    }
  }
  if (conflictingLibraries(bundles) case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }

  final aside = '.old-${DateTime.now().millisecondsSinceEpoch}';
  for (final directory in [places.bin, places.lib]) {
    _clear(Directory(directory), aside);
  }
  Directory(places.bin).createSync(recursive: true);
  Directory(places.lib).createSync(recursive: true);
  Directory(places.bindir).createSync(recursive: true);
  for (final bundle in bundles) {
    _copyInto(p.join(bundle, 'bin'), places.bin, aside);
    _copyInto(p.join(bundle, 'lib'), places.lib, aside);
  }

  for (final command in cli.retired) {
    _retire(p.join(places.bindir, places.exe(command)), aside);
  }
  for (final MapEntry(key: command, value: executable)
      in cli.commands.entries) {
    final target = p.join(places.bin, places.exe(executable));
    final onPath = p.join(places.bindir, places.exe(command));
    _retire(onPath, aside);
    if (windows) {
      File(target).copySync(onPath);
    } else {
      Link(onPath).createSync(target);
    }
  }
  if (windows) {
    Directory(places.bindirLib).createSync(recursive: true);
    _copyInto(places.lib, places.bindirLib, aside);
  }

  context.log('✓ ${cli.name} in ${places.share}');
  for (final command in cli.commands.keys) {
    context.log(
      onPathLine(
        context.env,
        command: command,
        installed: p.join(places.bindir, places.exe(command)),
        windows: windows,
      ),
    );
  }
  return ExitCode.success;
}

/// Removes what [installCli] laid down for [cli], and answers with an
/// [ExitCode].
///
/// Tolerant and safe to repeat. On Windows the libraries copied to
/// `~/.local/lib` are removed by the names the installed `lib/` has, because
/// that directory is not only this tool's.
Future<int> uninstallCli(VerbContext context, DartCli cli) async {
  final windows = Platform.isWindows;
  final home = homeOf(context.env, windows: windows);
  if (home == null) {
    context.log('no HOME${windows ? ' or USERPROFILE' : ''} is set');
    return ExitCode.taskFailed;
  }
  final places = CliPlaces.of(cli, home: home, windows: windows);
  final aside = '.old-${DateTime.now().millisecondsSinceEpoch}';
  if (windows && Directory(places.lib).existsSync()) {
    for (final library in Directory(places.lib).listSync().whereType<File>()) {
      _retire(p.join(places.bindirLib, p.basename(library.path)), aside);
    }
  }
  for (final directory in [places.bin, places.lib]) {
    _clear(Directory(directory), aside);
  }
  for (final command in [...cli.commands.keys, ...cli.retired]) {
    _retire(p.join(places.bindir, places.exe(command)), aside);
  }
  context.log('✓ ${cli.name} removed from ${places.share}');
  return ExitCode.success;
}

/// Why [bundles] cannot share one `lib/`, or null when they can: a library
/// two of them carry under one name must be the same file, since one `lib/`
/// holds only one of them and every executable then loads that one.
String? conflictingLibraries(List<String> bundles) {
  final seen = <String, File>{};
  for (final bundle in bundles) {
    final lib = Directory(p.join(bundle, 'lib'));
    if (!lib.existsSync()) {
      continue;
    }
    for (final file in lib.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      final earlier = seen[name];
      if (earlier == null) {
        seen[name] = file;
      } else if (!_same(earlier, file)) {
        return '$name differs between ${p.dirname(earlier.parent.path)} and '
            '$bundle';
      }
    }
  }
  return null;
}

bool _same(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) {
    return false;
  }
  final left = a.readAsBytesSync();
  final right = b.readAsBytesSync();
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

/// Empties [directory], moving aside what is held, and removes it where it
/// can.
void _clear(Directory directory, String aside) {
  if (!directory.existsSync()) {
    return;
  }
  try {
    directory.deleteSync(recursive: true);
    return;
  } on FileSystemException {
    // Something inside is held; take it file by file.
  }
  for (final entry in directory.listSync()) {
    if (entry is File) {
      _retire(entry.path, aside);
    } else {
      try {
        entry.deleteSync(recursive: true);
      } on FileSystemException {
        // Left for the next install's sweep.
      }
    }
  }
}

/// Removes [path], or moves it aside to `<path><aside>` where it is held;
/// and removes what an earlier install moved aside beside it, where nothing
/// holds that any more.
void _retire(String path, String aside) {
  final directory = Directory(p.dirname(path));
  if (directory.existsSync()) {
    final prefix = '${p.basename(path)}.old-';
    for (final old in directory.listSync().whereType<File>()) {
      if (p.basename(old.path).startsWith(prefix)) {
        try {
          old.deleteSync();
        } on FileSystemException {
          // Still held; the next install tries again.
        }
      }
    }
  }
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  try {
    if (type == FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else {
      File(path).deleteSync();
    }
  } on FileSystemException {
    File(path).renameSync('$path$aside');
  }
}

/// Copies every file directly in [from] into [to], moving aside what is
/// held there. A missing [from] copies nothing: a bundle with no native
/// libraries has no `lib/`.
void _copyInto(String from, String to, String aside) {
  final source = Directory(from);
  if (!source.existsSync()) {
    return;
  }
  for (final file in source.listSync().whereType<File>()) {
    final target = p.join(to, p.basename(file.path));
    _retire(target, aside);
    file.copySync(target);
  }
}
