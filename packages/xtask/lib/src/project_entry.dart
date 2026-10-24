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
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'parse.dart';
import 'reading.dart';
import 'report.dart' show runReport;
import 'report_file.dart';
import 'request.dart';
import 'secrets.dart';

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

/// How the project's entry point is started: `dart` with `arguments`, for
/// the project at `root` whose entry point is `entry` (from the root, with
/// `/`). Where `resolveIn` is set, the package there has no resolution yet,
/// and `dart pub get` is run in it first. `report` is the `--report` the
/// person's command line asked for, which is written here where the run is
/// refused before it starts, begun before it is started, and finished where
/// the project ended before its engine wrote to it: otherwise the project's
/// engine writes it.
///
/// There is no working directory to name: the run is started in this
/// process's own, where the person stands, because that is what every
/// relative path on its command line was written against.
typedef ProjectEntry = ({
  String root,
  String entry,
  List<String> arguments,
  String? resolveIn,
  ({String path, String? task})? report,
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
/// against it, so the run is always started in [workingDirectory]:
///
/// - `dart run <package>:xtask` where the entry point is its package's
///   `bin/xtask.dart` and the package resolution nearest to
///   [workingDirectory] is that package's own — its `.dart_tool`, or its
///   workspace's where it says `resolution: workspace`. It is `dart run
///   :xtask` by name, with the snapshot `dart run` keeps — a third of a
///   second — and it works from any package of a workspace, where `:xtask`
///   means the package the person is in. A resolution that merely names the
///   package, as a package depending on it has, is not enough: it lacks the
///   package's dev_dependencies, `xtask` usually among them.
/// - `dart run <path to the entry point>` where it is not, or where the
///   entry point is any other file: `dart` resolves a file's packages from
///   where the file is. Correct, and about a second and a half, since a file
///   is compiled on every run. The path is relative to [workingDirectory], so
///   the names of the directories above the root are not on the command line
///   — `cmd.exe` would read a `&` or a `%` in them, which nobody typed.
/// - Where the package has no resolution of its own yet, or one older than
///   its pubspec, lock or overrides: `dart pub get` in it, and then the file
///   form, for a `bin/xtask.dart` as for any other file. `dart run
///   :xtask` in the package would resolve it as well, but only by starting
///   the run there, and a run started anywhere but [workingDirectory] reads
///   every relative path the person typed against the wrong directory —
///   one argument at a time to patch, and the next one added breaks again.
///   The `pub get` is the one `dart run` would have done itself, and it is
///   paid once: from then on the package resolves, and the forms above
///   apply.
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
  final home = _resolutionOf(package);
  final resolved = home != null && _names(home, name, package);
  // **Its own resolution, not any that mentions it.** A resolution has
  // every package it names, but only its own package's dev_dependencies —
  // and the entry point's `xtask` is one more often than not. An `example/`
  // that depends on the library by path, or a root that depends on its
  // tools package, names the package where it is and cannot build its
  // `bin/xtask.dart`: `dart run <name>:xtask` from there fails to compile.
  final nearest = _nearestResolution(workingDirectory);
  if (named && resolved && nearest != null && p.equals(nearest, home)) {
    return (
      root: root,
      entry: entry,
      arguments: ['run', '$name:xtask', ...args],
      resolveIn: null,
      report: reportAskedIn(args),
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
    // `dart run <file>` takes the resolution it finds as it is, where the
    // name form gets it again when it is behind its pubspec: without this a
    // pull that brought a dependency fails to compile until the person runs
    // `dart pub get` themselves.
    resolveIn: resolved && _current(home, package) ? null : package,
    report: reportAskedIn(args),
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
/// engine has the `SIGINT` from the group already and is stopping its run,
/// and it counts only the first signal it receives, so the `SIGTERM` behind
/// it changes nothing — the run answers `130` either way. A `SIGTERM` is
/// passed on as it is; an interrupt sent to this process alone reaches the
/// engine only as that `SIGTERM`, and is answered `143`. On Windows nothing
/// is passed on — see [passSignalsOn].
///
/// What it says itself is masked as the engine's lines are (`secrets.dart`):
/// it quotes the command line, which is where a value typed after `--` is.
/// It says nothing to GitHub: the project's engine does, before its first
/// line, and a run this one could not start printed nothing to mask.
Future<int> runProjectEntry(
  ProjectEntry entry, {
  required Map<String, String> environment,
  required void Function(String line) err,
  ExecutableResolver? resolver,
}) async {
  final paths = resolver ?? ExecutableResolver.forHost();
  final secrets = readSecrets(
    entry.root,
    environment,
    windows: paths.windows,
  );
  void say(String line) => err(secrets.mask(line));
  final from = Directory.current.path;
  // **Every refusal here leaves the report the command line asked for**, as
  // the engine's own refusals do, and by the same function: the run that
  // would have written it never starts, and the file left in its place is
  // the last run's, which reads to whatever waits on it as this one's.
  int refuse(int code, String message) {
    say(message);
    if (entry.report case final asked?) {
      reportRefusal(
        asked,
        workingDirectory: from,
        secrets: secrets,
        code: code,
        refusal: message,
        err: say,
      );
    }
    return code;
  }

  final depth = int.tryParse(environment[handOverVariable] ?? '') ?? 0;
  if (depth >= handOverLimit) {
    return refuse(
      ExitCode.invalidFile,
      'xtask: this run has been handed to a project entry point $depth times '
      'over, which is a loop rather than a run — an entry point at '
      '`${entry.root}` that hands over again instead of calling `runXtask`',
    );
  }
  final dart = paths.resolve('dart', from: from);
  if (dart == null) {
    return refuse(
      ExitCode.missingTool,
      'xtask: `${entry.root}` has an entry point of its own, '
      '`${entry.entry}`, where its verbs are, and it takes `dart` to run it. '
      '${paths.missingToolMessage('dart', from: from)}',
    );
  }
  final shell = paths.needsShell(dart);
  // The batch-shim rule, for the person's own command line this time:
  // `cmd.exe` reads it before `dart.bat` does. Asked before the resolution is
  // got, so that a run refused here has not rewritten the package's lock
  // first. Not `dart run :xtask` as the way round: that goes through the
  // same batch file; the SDK's `dart.exe` does not.
  if (shell) {
    if (shellMetacharacterIn(entry.arguments) case (
      :final argument,
      :final character,
    )) {
      return refuse(
        ExitCode.invalidFile,
        'xtask: `$argument` cannot be handed to `$dart`, which is a batch '
        'file: `cmd.exe` would read `$character` in it before the project '
        "does. Put the Dart SDK's `dart.exe` ahead of it on PATH, or run "
        '`${entry.entry}` with that `dart.exe` yourself',
      );
    }
  }
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
      return refuse(
        ExitCode.taskFailed,
        'xtask: `$dart pub get` could not be started: ${failure.message}',
      );
    }
    if (got.exitCode != ExitCode.success) {
      return refuse(
        ExitCode.taskFailed,
        'xtask: the entry point `${entry.entry}` is in a package with no '
        'resolution, and `dart pub get` in `$package` exited with '
        '${got.exitCode}:\n${got.stdout}${got.stderr}',
      );
    }
    _markResolved(package);
  }
  // **The report is begun before the project is started**, as the engine
  // begins it before it reads anything: a project that is started and ends
  // before its engine has written a word — an entry point that does not
  // compile, a `dart run` that cannot resolve — left the last run's report
  // where this one's belongs. Not written is not refused: the project's
  // engine tries the same file next, and says why it cannot.
  final begun = entry.report == null
      ? null
      : _beginReport(entry, from, secrets);
  final Process process;
  try {
    process = await Process.start(
      dart,
      entry.arguments,
      environment: {...environment, handOverVariable: '${depth + 1}'},
      includeParentEnvironment: false,
      runInShell: shell,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (failure) {
    // 1 and not 3, as the engine answers a task that could not be started:
    // the resolver found `dart`, so this is not the proof of absence 3 is.
    return refuse(
      ExitCode.taskFailed,
      'xtask: `$dart ${entry.arguments.join(' ')}` could not be started: '
      '${failure.message}',
    );
  }
  final watching = passSignalsOn(process.kill, windows: Platform.isWindows);
  try {
    final exited = await process.exitCode;
    // A run ended by a signal answers as a shell would say it, 128 and the
    // signal, where Dart reports the signal negated. Only off Windows: there
    // a negative code is an NTSTATUS the shell reports as it is.
    final code = exited < 0 && !Platform.isWindows ? bySignal(-exited) : exited;
    // Still the report begun above, or the engine's own first one: nothing
    // ran far enough to write another, and the run's code is its answer.
    if (begun != null && _stillBegun(begun)) {
      reportRefusal(
        entry.report!,
        workingDirectory: from,
        secrets: secrets,
        code: code,
        refusal:
            'xtask: the entry point `${entry.entry}` ended with $code before '
            'its run began',
        err: say,
      );
    }
    return code;
  } finally {
    for (final watch in watching) {
      await watch.cancel();
    }
  }
}

/// Writes the report [entry] asked for as a run not begun yet, and answers
/// the file, or null where it could not be written.
File? _beginReport(ProjectEntry entry, String from, Secrets secrets) {
  final asked = entry.report!;
  try {
    ReportFile(
      asked.path,
      workingDirectory: from,
      secrets: secrets,
    ).write(runReport(asked.task, null));
  } on FileSystemException {
    return null;
  }
  return File(p.join(from, asked.path));
}

/// Whether the report at [file] is still one written before any run began:
/// not complete, and no task in it.
bool _stillBegun(File file) {
  try {
    return switch (jsonDecode(file.readAsStringSync())) {
      {'complete': false, 'tasks': []} => true,
      _ => false,
    };
  } on FormatException {
    return false;
  } on FileSystemException {
    return false;
  }
}

/// Passes the signals this process receives on to the run it started, by
/// [kill]; the subscriptions are the caller's to cancel.
///
/// Off Windows, an interrupt goes on as a `SIGTERM` and a `SIGTERM` as it
/// is — [runProjectEntry] says why.
///
/// **On Windows, an interrupt is only listened to.** `Process.kill` there
/// ignores the signal it is given and terminates the process, as the Dart
/// SDK documents it: passing a Ctrl-C on would end the project's engine
/// before it had stopped its run, printed its summary or written its last
/// report — the run answering whatever a terminated process answers, and
/// not `130`. A Ctrl-C at a console reaches every process attached to it,
/// the project's engine among them, which stops its run itself. Listening
/// is what keeps this process from ending first and handing the prompt back
/// over a run still printing; it then waits for the run as it always does.
/// There is no `SIGTERM` to watch on Windows.
///
/// [windows] and the two streams are parameters so that the decision can be
/// tested on a machine that is not the one it is about.
List<StreamSubscription<ProcessSignal>> passSignalsOn(
  bool Function([ProcessSignal signal]) kill, {
  required bool windows,
  Stream<ProcessSignal>? interrupts,
  Stream<ProcessSignal>? terminations,
}) => [
  (interrupts ?? ProcessSignal.sigint.watch()).listen(
    windows ? (_) {} : (_) => kill(),
  ),
  if (!windows) (terminations ?? ProcessSignal.sigterm.watch()).listen(kill),
];

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

/// The directory whose `.dart_tool/package_config.json` is the resolution
/// of the package at [package]: the package itself, or the root of its
/// workspace where its pubspec says `resolution: workspace`.
///
/// The workspace root is the nearest directory above with a pubspec that
/// has a `workspace:` list, past one that is itself a member of a workspace
/// further up. Whether the list names this package is not read here — it
/// may be a glob — and need not be: a member the list leaves out is one
/// `dart pub get` refuses, and the file form runs that and says why. Null
/// where no such directory is there to name.
String? _resolutionOf(String package) {
  if (!_inWorkspace(package)) {
    return package;
  }
  for (var directory = p.dirname(package); ; directory = p.dirname(directory)) {
    if (_pubspec(directory) case {'workspace': _}) {
      if (!_inWorkspace(directory)) {
        return directory;
      }
    }
    if (p.dirname(directory) == directory) {
      return null;
    }
  }
}

bool _inWorkspace(String directory) => switch (_pubspec(directory)) {
  {'resolution': 'workspace'} => true,
  _ => false,
};

/// The `pubspec.yaml` at [directory], read, or null where there is none that
/// reads as YAML.
Object? _pubspec(String directory) {
  final file = File(p.join(directory, 'pubspec.yaml'));
  try {
    return file.existsSync() ? loadYaml(file.readAsStringSync()) : null;
  } on Exception {
    return null;
  }
}

/// The directory with the package resolution nearest to [from], at or above
/// it: the one `dart run` reads there.
String? _nearestResolution(String from) {
  for (var directory = p.absolute(from); ; directory = p.dirname(directory)) {
    if (File(_config(directory)).existsSync()) {
      return directory;
    }
    if (p.dirname(directory) == directory) {
      return null;
    }
  }
}

String _config(String directory) =>
    p.join(directory, '.dart_tool', 'package_config.json');

/// Marks the resolution of [package] as got now, as `dart run` does when it
/// finds it current.
///
/// **`dart pub get` leaves a resolution it did not change as it was** —
/// measured: after `touch pubspec.lock`, neither the lock nor
/// `.dart_tool/package_config.json` is written — so a lock a checkout or a
/// pull had touched stayed newer than the resolution, [_current] answered
/// no on every run after, and every run paid a `pub get` again. `dart run
/// :name` sets the time of `package_config.json` for this very reason, and
/// so is it set here — to now, or to the newest of [_sources] where a clock
/// put one ahead of now: the `pub get` that has just succeeded read them as
/// they are, and a resolution marked older than one of them would be got
/// again on every run, the very thing this is for. A time that cannot be
/// set changes nothing but the next run's `pub get`.
void _markResolved(String package) {
  final home = _resolutionOf(package);
  if (home == null) {
    return;
  }
  try {
    var at = DateTime.now();
    for (final source in _sources(home, package)) {
      final file = File(source);
      if (file.existsSync() && file.lastModifiedSync().isAfter(at)) {
        at = file.lastModifiedSync();
      }
    }
    File(_config(home)).setLastModifiedSync(at);
  } on FileSystemException {
    // Not there, or not ours to touch: the next run gets it again.
  }
}

/// The files a resolution at [home], of the entry point's [package], is got
/// from: what [_current] holds its time against.
Set<String> _sources(String home, String package) => {
  p.join(home, 'pubspec.lock'),
  p.join(home, 'pubspec.yaml'),
  p.join(home, 'pubspec_overrides.yaml'),
  p.join(package, 'pubspec.yaml'),
};

/// Whether the resolution at [home] is no older than what it was got from,
/// as `dart run` judges it for the name form: a `pubspec.lock` there, and
/// neither it nor the `pubspec.yaml` and `pubspec_overrides.yaml` beside
/// it, nor the pubspec of the [package] the entry point is in, written
/// since.
///
/// By the files' times alone — what `pub` looks at before anything else —
/// and not by what they say. A clock that went backwards, or a dependency
/// by path whose own pubspec changed, is not noticed here; the compile that
/// follows says what is missing.
bool _current(String home, String package) {
  final DateTime resolved;
  final lock = File(p.join(home, 'pubspec.lock'));
  try {
    if (!lock.existsSync()) {
      return false;
    }
    resolved = File(_config(home)).lastModifiedSync();
    for (final source in _sources(home, package)) {
      final file = File(source);
      if (file.existsSync() && file.lastModifiedSync().isAfter(resolved)) {
        return false;
      }
    }
  } on FileSystemException {
    // Gone or unreadable between the look and the read: get it again, which
    // says what is wrong if anything is.
    return false;
  }
  return true;
}

/// Whether the package resolution at [home] has [name] in it, as the
/// package at [root] — not merely a package of that name.
///
/// A resolution that cannot be read, or names the package somewhere that is
/// not a directory on this machine, answers no: the file form needs none of
/// it, and a run must not fail here before the engine has said a word.
bool _names(String home, String name, String root) {
  final config = File(_config(home));
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
    // Not there, or there and not readable.
  }
  return false;
}
