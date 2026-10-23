/// Handing a run to the project's own entry point — what lets the installed
/// `xtask` run a project whose tasks name verbs.
///
/// **A global install is the engine and nothing else.** A verb is a Dart
/// function in the project's `bin/xtask.dart`, which a binary compiled from
/// this package cannot contain, so `do: pack` met "the engine ships no
/// project verbs" — in every repository that had grown one verb, which is
/// every repository that had grown past `run:`. The entry point the project
/// wrote is still the one place those verbs exist; this module only finds it
/// and starts it, the way `dart run :xtask` would, so that typing `xtask`
/// means the same thing in such a repository as it does everywhere else.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'boundary.dart';
import 'cli.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'parse.dart';
import 'request.dart';

/// The variable a handed-over run carries: how many hand-overs deep it is.
///
/// **A count, not a mark.** A mark — "handed over for this root" — is
/// inherited by everything the project's run starts, so a task that runs
/// `xtask lint` met an installed `xtask` that would not hand over again and
/// failed on the first verb. A legitimate hand-over happens once per `xtask`
/// typed or written into a task; a loop needs an entry point that hands
/// over itself, which the project's does not (it calls `runXtask`), so the
/// count only grows past a handful when something is wrong, and
/// [handOverLimit] says so instead of starting processes until the machine
/// runs out.
const handOverVariable = 'XTASK_HAND_OVERS';

/// How many hand-overs deep a run may go before it is taken for a loop.
const handOverLimit = 8;

/// How the project's entry point is started: `dart` with `arguments`, in
/// `workingDirectory` where it is not this process's own, for the project
/// at `root` whose entry point is `entry` (from the root, with `/`). Where
/// `resolveIn` is set, the package there has no resolution yet, and `dart
/// pub get` is run in it first.
typedef ProjectEntry = ({
  String root,
  String entry,
  List<String> arguments,
  String? workingDirectory,
  String? resolveIn,
});

/// Where an entry point is when `xtask.yaml` does not say: the file `dart run
/// :xtask` reaches in the root's own package.
const defaultEntry = 'bin/xtask.dart';

/// The run [args] handed to the entry point of the project around
/// [workingDirectory], or null where this engine answers it itself.
///
/// The entry point is the file `entry:` names in `xtask.yaml`, from the
/// root, and [defaultEntry] where it names none. Its package is the nearest
/// `pubspec.yaml` at or above it, inside the root — not the root's, which a
/// tool kept in a package of its own (`tools/bin/xtask.dart`) does not
/// share.
///
/// Null where there is no `xtask.yaml` above [workingDirectory] (the engine
/// says so in its own words), where the entry point is not there or is in no
/// package, and where it is this package's own, whose entry point is this
/// one. Null as well where `entry:` is not a path this engine accepts: the
/// engine reads the file next, and refuses it with the line it is on. And for
/// completion: `--completion` prints a script that is the same whoever
/// prints it, and `--names`, asked on every TAB, is answered here while this
/// engine can read the file — a hand-over would put a Dart start-up behind
/// each keypress — and handed over only where it cannot, a file written for
/// a newer `xtask` than the installed one. Only what comes before `--` is the
/// engine's to read: after it, the arguments are a task's.
///
/// **The project is started where the person is standing.** Its entry looks
/// for `xtask.yaml` from its own working directory and reads relative paths
/// on its command line — `--check-schema`, a project's own `--covering` —
/// against it, so the run is started in [workingDirectory] whenever it can
/// be:
///
/// - `dart run <package>:xtask` where the entry point is its package's
///   `bin/xtask.dart` and the package resolution nearest to
///   [workingDirectory] has that package in it, there. It is `dart run
///   :xtask` by name, with the snapshot `dart run` keeps — a third of a
///   second — and it works from any package of a workspace, where `:xtask`
///   means the package the person is in.
/// - `dart run <path to the entry point>` where it does not, or where the
///   entry point is any other file: `dart` resolves a file's packages from
///   where the file is. Correct, and about a second and a half, since a file
///   is compiled on every run. The path is relative to [workingDirectory], so
///   the names of the directories above the root are not on the command line
///   — `cmd.exe` would read a `&` or a `%` in them, which nobody typed.
/// - Where the package has no resolution yet: `dart run :xtask` in it for a
///   `bin/xtask.dart` — `dart run` resolves one there first, the one form that
///   moves the run, and only until the first `pub get` — and for any other
///   file, `dart pub get` in it before the file form, which cannot resolve
///   anything itself.
ProjectEntry? projectEntry(
  List<String> args, {
  required String workingDirectory,
}) {
  final engines = args.takeWhile((argument) => argument != '--').toList();
  if (engines.any(_isCompletionScript)) {
    return null;
  }
  final root = findRoot(workingDirectory);
  if (root == null) {
    return null;
  }
  final entry = _entryOf(root);
  if (entry == null) {
    return null;
  }
  final file = p.joinAll([root, ...p.posix.split(entry)]);
  if (!File(file).existsSync()) {
    return null;
  }
  final package = packageOf(file, root: root);
  if (package == null) {
    return null;
  }
  if (engines.contains('--names') && _readable(root)) {
    return null;
  }
  final name = _packageName(package);
  if (name == null) {
    return null;
  }
  final named = p.equals(file, p.join(package, 'bin', 'xtask.dart'));
  if (named && name == 'xtask') {
    return null;
  }
  if (named && _resolves(name, package, from: workingDirectory)) {
    return (
      root: root,
      entry: entry,
      arguments: ['run', '$name:xtask', ...args],
      workingDirectory: null,
      resolveIn: null,
    );
  }
  final resolved = _resolves(name, package, from: package);
  if (named && !resolved) {
    return (
      root: root,
      entry: entry,
      arguments: ['run', ':xtask', ...args],
      workingDirectory: package,
      resolveIn: null,
    );
  }
  return (
    root: root,
    entry: entry,
    arguments: [
      'run',
      p.relative(file, from: workingDirectory),
      ...args,
    ],
    workingDirectory: null,
    resolveIn: resolved ? null : package,
  );
}

/// The entry point `xtask.yaml` at [root] names, [defaultEntry] where it
/// names none, and null where what it names is not a path from the root.
///
/// Read here rather than by the parser, so that a file this engine cannot
/// otherwise read — written for a newer `xtask` — is still handed to the
/// project that can.
String? _entryOf(String root) {
  final Object? document;
  try {
    document = loadYaml(
      File(p.join(root, xtaskFileName)).readAsStringSync(),
    );
  } on Exception {
    return defaultEntry;
  }
  return switch (document) {
    {'entry': final String entry} when entryProblem(entry) == null => entry,
    {'entry': _} => null,
    _ => defaultEntry,
  };
}

/// Starts [entry] on this process's own three descriptors, and answers with
/// the code it ends with.
///
/// **Signals.** An interrupt is passed on as a `SIGTERM`, and this process
/// waits for the run to end rather than ending first and handing the prompt
/// back over a run still printing. The process started is `dart run`, which
/// leaves `SIGINT` to the terminal's foreground group and does nothing with
/// one sent to it alone — measured: a run so interrupted went on to its end
/// — while it ends the program it runs on a `SIGTERM`. Whether the
/// interrupt came from the terminal cannot be told here (`stdin.hasTerminal`
/// answers yes for `/dev/null`), and need not be: from Ctrl-C the project's
/// run and what it started have the `SIGINT` from the group already, and
/// the `SIGTERM` reaches only the engine that is ending anyway. A `SIGTERM`
/// is passed on as it is.
Future<int> runProjectEntry(
  ProjectEntry entry, {
  required Map<String, String> environment,
  required void Function(String line) err,
  ExecutableResolver? resolver,
}) async {
  final depth = int.tryParse(environment[handOverVariable] ?? '') ?? 0;
  if (depth >= handOverLimit) {
    err(
      'xtask: this run has been handed to a project entry point $depth times '
      'over, which is a loop rather than a run — an entry point at '
      '`${entry.root}` that hands over again instead of calling `runXtask`',
    );
    return ExitCode.invalidFile;
  }
  final paths = resolver ?? ExecutableResolver.forHost();
  final from = entry.workingDirectory ?? Directory.current.path;
  final dart = paths.resolve('dart', from: from);
  if (dart == null) {
    err(
      'xtask: `${entry.root}` has an entry point of its own, '
      '`${entry.entry}`, where its verbs are, and it takes `dart` to run it. '
      '${paths.missingToolMessage('dart', from: from)}',
    );
    return ExitCode.missingTool;
  }
  final shell = paths.needsShell(dart);
  if (entry.resolveIn case final package?) {
    // Collected rather than inherited: what `pub get` says on success is
    // noise on the stdout of a run that may be `--list` piped somewhere, and
    // what it says on failure is the only thing worth reading.
    final ProcessResult got;
    try {
      got = await Process.run(
        dart,
        const ['pub', 'get'],
        workingDirectory: package,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: shell,
      );
    } on ProcessException catch (failure) {
      err('xtask: `$dart pub get` could not be started: ${failure.message}');
      return ExitCode.taskFailed;
    }
    if (got.exitCode != ExitCode.success) {
      err(
        'xtask: the entry point `${entry.entry}` is in a package with no '
        'resolution, and `dart pub get` in `$package` exited with '
        '${got.exitCode}:\n${got.stdout}${got.stderr}',
      );
      return ExitCode.taskFailed;
    }
  }
  if (shell) {
    // The batch-shim rule, for the person's own command line this time:
    // `cmd.exe` reads it before `dart.bat` does.
    if (shellMetacharacterIn(entry.arguments) case (
      :final argument,
      :final character,
    )) {
      err(
        'xtask: `$argument` cannot be handed to `$dart`, which is a batch '
        'file: `cmd.exe` would read `$character` in it before the project '
        'does. Run `dart run :xtask` from the root instead',
      );
      return ExitCode.invalidFile;
    }
  }

  final Process process;
  try {
    process = await Process.start(
      dart,
      entry.arguments,
      workingDirectory: entry.workingDirectory,
      environment: {...environment, handOverVariable: '${depth + 1}'},
      includeParentEnvironment: false,
      runInShell: shell,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (failure) {
    // 1 and not 3, as the engine answers a task that could not be started:
    // the resolver found `dart`, so this is not the proof of absence 3 is.
    err(
      'xtask: `$dart ${entry.arguments.join(' ')}` could not be started: '
      '${failure.message}',
    );
    return ExitCode.taskFailed;
  }
  final watching = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => process.kill()),
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(process.kill),
  ];
  try {
    final code = await process.exitCode;
    // A run ended by a signal answers as a shell would say it, 128 and the
    // signal, where Dart reports the signal negated. Only off Windows: there
    // a negative code is an NTSTATUS the shell reports as it is.
    return code < 0 && !Platform.isWindows ? 128 - code : code;
  } finally {
    for (final watch in watching) {
      await watch.cancel();
    }
  }
}

bool _isCompletionScript(String argument) =>
    argument == '--completion' || argument.startsWith('--completion=');

/// Whether this engine can read the `xtask.yaml` at [root].
bool _readable(String root) {
  try {
    parseXtaskFile(
      File(p.join(root, xtaskFileName)).readAsStringSync(),
    );
    return true;
  } on XtaskFormatException {
    return false;
  } on FileSystemException {
    // Not for the project to read either; the engine says why.
    return true;
  }
}

/// The `name:` of the package at [root], or null where it has none to read.
String? _packageName(String root) {
  try {
    return switch (loadYaml(
      File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
    )) {
      {'name': final String name} => name,
      _ => null,
    };
  } on Exception {
    return null;
  }
}

/// Whether the package resolution nearest to [from] has [name] in it, as the
/// package at [root] — not merely a package of that name.
///
/// A resolution that cannot be read, or names the package somewhere that is
/// not a directory on this machine, answers no: the file form needs none of
/// it, and a run must not fail here before the engine has said a word.
bool _resolves(String name, String root, {required String from}) {
  for (var directory = p.absolute(from); ; directory = p.dirname(directory)) {
    final config = File(
      p.join(directory, '.dart_tool', 'package_config.json'),
    );
    if (config.existsSync()) {
      try {
        final packages = switch (jsonDecode(config.readAsStringSync())) {
          {'packages': final List<Object?> packages} => packages,
          _ => const <Object?>[],
        };
        for (final package in packages) {
          if (package case {
            'name': final String named,
            'rootUri': final String uri,
          } when named == name) {
            final at = Uri.directory(p.dirname(config.path)).resolve(uri);
            return at.isScheme('file') &&
                p.equals(p.normalize(p.fromUri(at)), root);
          }
        }
      } on FormatException {
        // Not JSON, or a `rootUri` that is not a URI.
      } on FileSystemException {
        // There, and not readable.
      }
      return false;
    }
    if (p.dirname(directory) == directory) {
      return false;
    }
  }
}
