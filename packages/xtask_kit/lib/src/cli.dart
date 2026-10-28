/// Installing command-line tools built by `dart build cli` for whoever runs
/// the verb: under `~/.local`, and onto `PATH`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

import 'home.dart';
import 'on_path.dart';
import 'replace.dart';

/// Command-line tools built by `dart build cli`, and what [cliInstall] needs
/// to know to install them.
///
/// Each bundle is what that command leaves: `bin/` with the executables and
/// `lib/` with the native libraries they load from `../lib`. Several bundles
/// install into one `bin/` and one `lib/`, so that every executable finds
/// every library where it looks — which is why a library two bundles both
/// carry has to be the same file ([conflictingLibraries]), and an executable
/// two of them carry too.
final class DartCli {
  const DartCli({
    required this.name,
    required this.bundles,
    required this.commands,
    this.retired = const [],
    this.foreignRetired = ForeignRetired.refuse,
    this.adopt,
    this.forbiddenLibraries = const {},
    this.afterInstall,
    this.beforeUninstall,
    this.afterUninstall,
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
  /// starting a binary that is no longer there. Only where it is one an
  /// install laid down: a file of that name that is not is refused like any
  /// other on `PATH` ([installCli]).
  final List<String> retired;

  /// What an install does with a file under a [retired] name that it did
  /// not lay down: refuse, as for any command, or leave it and say so. The
  /// second is for a project whose earlier version removed whatever was
  /// there, so that somebody's own file under that name does not stop every
  /// install after the move.
  final ForeignRetired foreignRetired;

  /// What shows a `~/.local/share/<name>` without the install's mark to be
  /// this tool's own earlier install, to replace and remove like a marked
  /// one; null for none, which refuses it. [EarlierInstall.linked] takes a
  /// command or a retired one on `PATH` leading into it as that — on POSIX
  /// only, where a command is a link.
  final EarlierInstall? adopt;

  /// Native libraries a bundle must not carry, by the bundle as [bundles]
  /// writes it: a library the build pulled into the wrong one — a model only
  /// a server is to load, built into the client by a stray dependency —
  /// which the shared `lib/` would then hand to every executable. A bundle
  /// carrying one is refused before anything is copied.
  final Map<String, List<String>> forbiddenLibraries;

  /// A step of the project's after the install has succeeded — a stamp
  /// beside the executables, a key in a registry, a command the installed
  /// tool runs once — with the places it installed to. What it answers is
  /// what the install answers; it is not run where the install failed.
  final CliStep? afterInstall;

  /// A step of the project's before the uninstall removes anything, while
  /// what was installed is still there to run, with the places it is in.
  /// Run wherever the uninstall goes ahead, a machine with nothing installed
  /// included, so it is to be as tolerant as the uninstall; not run where
  /// the install is somebody else's. Anything but `0` stops the uninstall
  /// with nothing removed, and is what it answers.
  final CliStep? beforeUninstall;

  /// A step of the project's once the uninstall has done what it does,
  /// handed what that came to — a key in a registry to forget only where
  /// the tool is gone ([Uninstalled.removed]), say. Run where the uninstall
  /// answered `0`: after a removal, on a machine with nothing installed, and
  /// over an install that is somebody else's. What it answers is what the
  /// uninstall answers.
  final CliUninstallStep? afterUninstall;
}

/// A step a project adds to [installCli] or [uninstallCli]
/// ([DartCli.afterInstall], [DartCli.beforeUninstall]): run in [context],
/// with the [places] the tool is installed to, answering an [ExitCode].
typedef CliStep = Future<int> Function(VerbContext context, CliPlaces places);

/// A step a project adds after [uninstallCli] ([DartCli.afterUninstall]): a
/// [CliStep] handed as well what the uninstall came to.
typedef CliUninstallStep =
    Future<int> Function(
      VerbContext context,
      CliPlaces places,
      Uninstalled outcome,
    );

/// What [installCli] does with a file under a [DartCli.retired] name that is
/// not one it laid down ([DartCli.foreignRetired]).
enum ForeignRetired {
  /// Refuse the install, before anything changes, as for any command.
  refuse,

  /// Leave the file as it is, say so, and go on.
  leave,
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

/// Why [places]' directory is not [cli]'s, as [notOurDirectory] says, with
/// [DartCli.adopt] and its commands on `PATH` as the evidence it weighs.
String? _notOurDirectory(DartCli cli, CliPlaces places) => notOurDirectory(
  places.share,
  owner: _owner(cli),
  adopt: cli.adopt,
  links: [
    for (final command in [...cli.commands.keys, ...cli.retired])
      p.join(places.bindir, places.exe(command)),
  ],
);

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
///   what an earlier install put there, and marked as [DartCli.name]'s
///   ([markDirectory]);
/// - each command at `~/.local/bin/<command>`: a link to its executable on
///   POSIX, a copy on Windows — no symlink without developer mode — with the
///   libraries copied to `~/.local/lib`, where the copy looks for them.
///
/// **Built beside the earlier install, then swapped in.** The bundles are
/// copied into `<name>.new` first and the earlier install is replaced only
/// once that copy is whole, as [replaceDirectory] does — so a full disk or an
/// unreadable file halfway through leaves the earlier install working, and
/// is a `1` naming the file rather than an exception. Once the new one is in
/// place the install has succeeded: an earlier one that cannot be removed is
/// left as `<name>.old-<time>`, which the next install removes.
///
/// **Only its own directory is replaced.** `~/.local/share` is every
/// application's, and a `<name>` there without this install's mark is
/// somebody else's ([notOurDirectory]) unless [DartCli.adopt] shows it to be
/// an earlier install's: it is refused before anything changes, as is
/// anything on `PATH` that links into it.
///
/// **Only its own files on `PATH` are replaced.** `~/.local/bin` is not this
/// tool's alone, and a file of the command's name there may be somebody
/// else's. On POSIX that is anything but a link into `~/.local/share/<name>`;
/// on Windows, where the command is a copy, it is anything other than a copy
/// of an executable the earlier install holds — which is why a copy is
/// written as `<command>.new` and renamed into place, so that one cut off
/// halfway is not mistaken for somebody else's. Either is refused before
/// anything changes, retired commands included — unless
/// [DartCli.foreignRetired] says to leave one under a retired name, which it
/// then does, saying so.
///
/// **Windows holds what is running.** A file a running process has open
/// cannot be deleted there — the very tool being reinstalled, serving an
/// editor — but it can be renamed, and the process keeps running from the
/// renamed file. So what cannot be removed is moved aside to
/// `<file>.old-<time>`, and the next install removes what nothing holds any
/// more. Neither happens on POSIX, where nothing on `PATH` is ever moved
/// aside: a file there named `.old-` is somebody's backup, and is left alone.
///
/// It refuses, naming why, without a home, when a bundle has no `bin/` or a
/// command's executable is in none of them, when a bundle carries a library
/// [DartCli.forbiddenLibraries] keeps out of it, and when two bundles carry
/// different files of one name for the shared `bin/` or `lib/`. It ends by
/// saying whether `PATH` reaches each command ([onPathLine]), and then runs
/// [DartCli.afterInstall], whose answer is its own.
Future<int> installCli(VerbContext context, DartCli cli) =>
    installCliOn(context, cli, windows: Platform.isWindows);

/// [installCli] under [windows]' rules rather than the running platform's,
/// so that both are tested on any machine.
Future<int> installCliOn(
  VerbContext context,
  DartCli cli, {
  required bool windows,
}) async {
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
  if (_forbidden(cli, context) ??
          _conflicting(bundles, 'bin') ??
          conflictingLibraries(bundles)
      case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
  final left = <String>{};
  for (final command in [...cli.commands.keys, ...cli.retired]) {
    if (_notOurs(p.join(places.bindir, places.exe(command)), places)
        case final why?) {
      if (!cli.commands.containsKey(command) &&
          cli.foreignRetired == ForeignRetired.leave) {
        context.log('⚠ $why — retired, so left as it is');
        left.add(command);
        continue;
      }
      context.log(why);
      return ExitCode.taskFailed;
    }
  }
  if (_notOurDirectory(cli, places) case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }

  final aside = '.old-${DateTime.now().millisecondsSinceEpoch}';
  final fresh = '${places.share}.new';
  try {
    _clear(Directory(fresh), aside, windows: windows);
    for (final part in ['bin', 'lib']) {
      final into = Directory(p.join(fresh, part))..createSync(recursive: true);
      for (final bundle in bundles) {
        _copyInto(p.join(bundle, part), into.path, aside, windows: windows);
      }
    }
    markDirectory(fresh, owner: _owner(cli));
  } on FileSystemException catch (error) {
    context.log(
      '${_failure(error)}, so nothing installed was changed; fix that and '
      'install again',
    );
    return ExitCode.taskFailed;
  }

  try {
    _swapIn(fresh, places, aside);
    Directory(places.bindir).createSync(recursive: true);
    for (final command in cli.retired) {
      if (!left.contains(command)) {
        _retire(p.join(places.bindir, places.exe(command)), aside, windows);
      }
    }
    for (final MapEntry(key: command, value: executable)
        in cli.commands.entries) {
      final target = p.join(places.bin, places.exe(executable));
      final onPath = p.join(places.bindir, places.exe(command));
      if (windows) {
        // Copied under a name of its own and renamed into place: a copy cut
        // off halfway at the command's own name is a file no install made,
        // and would refuse every install after it.
        final part = '$onPath.new';
        _retire(part, aside, windows);
        File(target).copySync(part);
        _retire(onPath, aside, windows);
        File(part).renameSync(onPath);
      } else {
        _retire(onPath, aside, windows);
        Link(onPath).createSync(target);
      }
    }
    if (windows) {
      // From the bundles rather than the installed `lib/`, which on Windows
      // may hold what was moved aside — a library the running tool has open
      // — and that is not a library to load.
      Directory(places.bindirLib).createSync(recursive: true);
      for (final bundle in bundles) {
        _copyInto(
          p.join(bundle, 'lib'),
          places.bindirLib,
          aside,
          windows: windows,
        );
      }
    }
  } on FileSystemException catch (error) {
    context.log(
      '${_failure(error)}, and ${cli.name} is installed only in part; fix '
      'that and install again',
    );
    return ExitCode.taskFailed;
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
  return await cli.afterInstall?.call(context, places) ?? ExitCode.success;
}

/// Removes what [installCli] laid down for [cli], and answers with an
/// [ExitCode].
///
/// Tolerant and safe to repeat. A command on `PATH` that is not one this
/// install laid down ([installCli] says which those are) is somebody else's,
/// and stays, with a line saying so. A `~/.local/share/<name>` without this
/// install's mark is somebody else's whole: nothing is removed, neither it
/// nor what on `PATH` leads into it, and the uninstall says why and
/// succeeds. Otherwise [DartCli.beforeUninstall] runs first, and anything but
/// `0` from it stops the uninstall there. Where it answers `0`,
/// [DartCli.afterUninstall] runs last, with what it came to
/// ([uninstallCliWithOutcome] answers that too), and answers for it. On
/// Windows the libraries copied to `~/.local/lib` are removed by the names
/// the installed `lib/` has, because that directory is not only this tool's.
Future<int> uninstallCli(VerbContext context, DartCli cli) =>
    uninstallCliOn(context, cli, windows: Platform.isWindows);

/// [uninstallCli], answering as well what it came to ([Uninstalled]) — for
/// a project whose step after it depends on whether the tool is gone, which
/// the exit code, `0` for a removal and for an install left as somebody
/// else's alike, does not say.
Future<({int code, Uninstalled outcome})> uninstallCliWithOutcome(
  VerbContext context,
  DartCli cli,
) => _uninstallCli(context, cli, windows: Platform.isWindows);

/// [uninstallCli] under [windows]' rules rather than the running platform's.
Future<int> uninstallCliOn(
  VerbContext context,
  DartCli cli, {
  required bool windows,
}) async => (await _uninstallCli(context, cli, windows: windows)).code;

/// What [uninstallCli] came to, whatever it answered.
enum Uninstalled {
  /// It removed something of this install's.
  removed,

  /// There was nothing of this install's to remove.
  nothing,

  /// The install there is somebody else's, and nothing was removed.
  foreign,
}

/// [uninstallCliOn], with what it came to.
Future<({int code, Uninstalled outcome})> _uninstallCli(
  VerbContext context,
  DartCli cli, {
  required bool windows,
}) async {
  final home = homeOf(context.env, windows: windows);
  if (home == null) {
    context.log('no HOME${windows ? ' or USERPROFILE' : ''} is set');
    return (code: ExitCode.taskFailed, outcome: Uninstalled.nothing);
  }
  final places = CliPlaces.of(cli, home: home, windows: windows);
  Future<({int code, Uninstalled outcome})> after(
    Uninstalled outcome,
  ) async => (
    code:
        await cli.afterUninstall?.call(context, places, outcome) ??
        ExitCode.success,
    outcome: outcome,
  );

  if (_notOurDirectory(cli, places) case final why?) {
    context.log('$why — nothing removed');
    return after(Uninstalled.foreign);
  }
  if (cli.beforeUninstall case final step?) {
    final stepped = await step(context, places);
    if (stepped != ExitCode.success) {
      context.log(
        'the step before the uninstall answered $stepped — nothing removed',
      );
      return (code: stepped, outcome: Uninstalled.nothing);
    }
  }
  final aside = '.old-${DateTime.now().millisecondsSinceEpoch}';
  var removed = false;
  void retire(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      removed = true;
    }
    _retire(path, aside, windows);
  }

  void clear(Directory directory) {
    if (directory.existsSync()) {
      removed = true;
    }
    _clear(directory, aside, windows: windows);
  }

  try {
    // The commands first: on Windows whether a copy is this install's is
    // read from the installed `bin/`, which goes next.
    for (final command in [...cli.commands.keys, ...cli.retired]) {
      final onPath = p.join(places.bindir, places.exe(command));
      if (_notOurs(onPath, places) case final why?) {
        context.log('$why — left as it is');
        continue;
      }
      retire(onPath);
      if (windows) {
        retire('$onPath.new');
      }
    }
    if (windows && Directory(places.lib).existsSync()) {
      for (final library in Directory(
        places.lib,
      ).listSync().whereType<File>()) {
        retire(p.join(places.bindirLib, p.basename(library.path)));
      }
    }
    // With what a failed install left beside it, which is this install's
    // too and nothing else removes.
    clear(Directory('${places.share}.new'));
    clear(Directory(places.share));
  } on FileSystemException catch (error) {
    context.log('${_failure(error)}; fix that and uninstall again');
    return (
      code: ExitCode.taskFailed,
      outcome: removed ? Uninstalled.removed : Uninstalled.nothing,
    );
  }
  if (!removed) {
    context.log('${cli.name}: nothing installed in ${places.share}');
    return after(Uninstalled.nothing);
  }
  context.log('✓ ${cli.name} removed from ${places.share}');
  return after(Uninstalled.removed);
}

/// Why one of [cli]'s bundles, read from [context]'s root, must not be
/// installed — it carries a library [DartCli.forbiddenLibraries] keeps out
/// of it — or null where none does.
String? _forbidden(DartCli cli, VerbContext context) {
  for (final MapEntry(key: bundle, value: libraries)
      in cli.forbiddenLibraries.entries) {
    if (!cli.bundles.contains(bundle)) {
      return 'forbiddenLibraries names $bundle, which is not one of the '
          'bundles';
    }
    final lib = p.join(context.directory(bundle).path, 'lib');
    for (final library in libraries) {
      if (File(p.join(lib, library)).existsSync()) {
        return '$bundle carries $library in its lib/, which it must not — '
            'check what its package depends on';
      }
    }
  }
  return null;
}

/// Why [bundles] cannot share one `lib/`, or null when they can: a library
/// two of them carry under one name must be the same file, since one `lib/`
/// holds only one of them and every executable then loads that one.
String? conflictingLibraries(List<String> bundles) =>
    _conflicting(bundles, 'lib');

/// Why [bundles] cannot share one [part] — `bin/` or `lib/` — or null when
/// they can: a file two of them carry there under one name must be the same
/// file, since the second copied would silently replace the first.
String? _conflicting(List<String> bundles, String part) {
  final seen = <String, File>{};
  for (final bundle in bundles) {
    final directory = Directory(p.join(bundle, part));
    if (!directory.existsSync()) {
      continue;
    }
    for (final file in directory.listSync().whereType<File>()) {
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

/// Why [path], a command on `PATH`, is not one this install may replace or
/// remove, or null where it is — or where nothing is there.
///
/// On POSIX the install lays down links into [CliPlaces.share], and which
/// link is its own is the rule [notOurLink] holds for every install that
/// links. On Windows it lays down copies, and a copy is told
/// from somebody else's file only by its bytes: it is the install's where it
/// is the same file as an executable the earlier install holds.
String? _notOurs(String path, CliPlaces places) {
  if (!places.windows) {
    return notOurLink(path, within: places.share);
  }
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return null;
  }
  final installed = Directory(places.bin);
  if (type == FileSystemEntityType.file &&
      installed.existsSync() &&
      installed.listSync().whereType<File>().any(
        (executable) => _same(executable, File(path)),
      )) {
    return null;
  }
  return '$path is not a copy this install made; move it away first';
}

/// Replaces [places]' install with [fresh], a complete one beside it.
///
/// Two renames where nothing holds the earlier install. On Windows a running
/// executable keeps its directory from being renamed, so there the earlier
/// install is emptied in place instead ([_clear]) and [fresh] copied in.
void _swapIn(String fresh, CliPlaces places, String aside) {
  final windows = places.windows;
  final share = Directory(places.share);
  // On POSIX too: `<share>.old-<digits>` is the name this install gives the
  // earlier one on every platform, and one is left wherever removing it
  // failed.
  _sweep(share.path);
  if (share.existsSync()) {
    final old = '${share.path}$aside';
    try {
      share.renameSync(old);
    } on FileSystemException {
      if (!windows) {
        rethrow;
      }
      for (final part in ['bin', 'lib']) {
        final into = p.join(share.path, part);
        _clear(Directory(into), aside, windows: windows);
        Directory(into).createSync(recursive: true);
        _copyInto(p.join(fresh, part), into, aside, windows: windows);
      }
      Directory(fresh).deleteSync(recursive: true);
      return;
    }
    try {
      Directory(fresh).renameSync(share.path);
    } on FileSystemException {
      // Put back rather than leave no install at all.
      Directory(old).renameSync(share.path);
      rethrow;
    }
    // The new install is in place, so a failure here is no failure of the
    // install: what could not be removed is left, at a name the next
    // install's sweep takes.
    try {
      _clear(Directory(old), aside, windows: windows);
    } on FileSystemException {
      // Left for the next install's sweep.
    }
    return;
  }
  Directory(p.dirname(share.path)).createSync(recursive: true);
  Directory(fresh).renameSync(share.path);
}

/// Who [cli]'s directory belongs to, as its mark says.
String _owner(DartCli cli) => 'cli ${cli.name}';

/// Whether [a] and [b] hold the same bytes.
///
/// The lengths first, then a block at a time: the files compared are
/// executables and native libraries, and reading two of them whole to tell
/// that they differ in the first block holds both in memory for nothing.
bool _same(File a, File b) {
  if (a.lengthSync() != b.lengthSync()) {
    return false;
  }
  final left = a.openSync();
  final right = b.openSync();
  try {
    const block = 64 * 1024;
    while (true) {
      final l = left.readSync(block);
      final r = right.readSync(block);
      if (l.length != r.length) {
        return false;
      }
      if (l.isEmpty) {
        return true;
      }
      for (var i = 0; i < l.length; i++) {
        if (l[i] != r[i]) {
          return false;
        }
      }
    }
  } finally {
    left.closeSync();
    right.closeSync();
  }
}

/// Removes [directory], and on Windows moves aside what is held in it and
/// removes the rest.
void _clear(Directory directory, String aside, {required bool windows}) {
  if (!directory.existsSync()) {
    return;
  }
  try {
    directory.deleteSync(recursive: true);
    return;
  } on FileSystemException {
    if (!windows) {
      rethrow;
    }
    // Something inside is held; take it file by file.
  }
  for (final entry in directory.listSync()) {
    if (entry is Directory) {
      _clear(entry, aside, windows: windows);
    } else {
      _retire(entry.path, aside, windows);
    }
  }
  try {
    directory.deleteSync();
  } on FileSystemException {
    // Still holding what was moved aside; the next install's sweep.
  }
}

/// Removes [path], a file or a link; on Windows moves it aside to
/// `<path><aside>` where it is held, and first removes what an earlier
/// install moved aside beside it, where nothing holds that any more.
void _retire(String path, String aside, bool windows) {
  if (windows) {
    _sweep(path);
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
    if (!windows) {
      rethrow;
    }
    File(path).renameSync('$path$aside');
  }
}

/// Removes what an install moved aside from [path] — exactly
/// `<path>.old-<digits>`, the name [_retire] gives it — where nothing holds
/// it any more. A `<path>.old-backup` is somebody's, and is not this.
void _sweep(String path) {
  final directory = Directory(p.dirname(path));
  if (!directory.existsSync()) {
    return;
  }
  final aside = RegExp('^${RegExp.escape(p.basename(path))}\\.old-[0-9]+\$');
  for (final old in directory.listSync()) {
    if (aside.hasMatch(p.basename(old.path))) {
      try {
        old.deleteSync(recursive: true);
      } on FileSystemException {
        // Still held; the next install tries again.
      }
    }
  }
}

/// Copies every file directly in [from] into [to], replacing what is there
/// ([_retire]). A missing [from] copies nothing: a bundle with no native
/// libraries has no `lib/`.
void _copyInto(
  String from,
  String to,
  String aside, {
  required bool windows,
}) {
  final source = Directory(from);
  if (!source.existsSync()) {
    return;
  }
  for (final file in source.listSync().whereType<File>()) {
    final target = p.join(to, p.basename(file.path));
    _retire(target, aside, windows);
    file.copySync(target);
  }
}

/// [error] as the first half of a sentence: what failed, and on which file.
String _failure(FileSystemException error) {
  final reason = error.osError?.message ?? error.message;
  return '${error.path ?? 'a file'}: $reason';
}
