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

import 'cli.dart';
import 'executables.dart';
import 'exit_codes.dart';

/// The variable a handed-over run carries: the root it was handed over for.
///
/// What stops the hand-over from happening twice. The project's entry calls
/// `runXtask`, not this module, so a loop needs an entry point that is this
/// package's own — `dart run xtask:xtask` written into a project's task — and
/// the variable is the answer for that one too. Keyed on the root rather than
/// set to a flag, so that a run handed over in one repository still hands
/// over in another one nested inside it.
const projectEntryVariable = 'XTASK_ENTRY';

/// How the project's entry point is started: `dart` with `arguments`, in
/// `workingDirectory` where it is not this process's own, for the project
/// at `root`.
typedef ProjectEntry = ({
  String root,
  List<String> arguments,
  String? workingDirectory,
});

/// The run [args] handed to the entry point of the project around
/// [workingDirectory], or null where this engine answers it itself.
///
/// Null where there is no `xtask.yaml` above [workingDirectory] (the engine
/// says so in its own words), where its directory has no `bin/xtask.dart`,
/// where that directory is this package's own repository (whose entry point
/// is this one), where [environment] says the run was handed over for this
/// root already, and for the two requests completion makes: `--completion`
/// prints a script, and `--names` answers every TAB — both read the file
/// alone, and a hand-over would put a Dart start-up behind each keypress.
///
/// **The project is started where the person is standing.** Its entry looks
/// for `xtask.yaml` from its own working directory and reads relative paths
/// on its command line — `--check-schema`, a project's own `--covering` —
/// against it, so the run is started in [workingDirectory] whenever it can
/// be:
///
/// - `dart run <package>:xtask` where the package resolution nearest to
///   [workingDirectory] has the root's package in it at the root. It is
///   `dart run :xtask` by name, with the snapshot `dart run` keeps — a
///   third of a second — and it works from any package of a workspace, where
///   `:xtask` means the package the person is in.
/// - `dart run <root>/bin/xtask.dart` where it does not: a package of its
///   own below the root, which resolves its own packages. Correct, and about
///   a second and a half, since a file is compiled on every run.
/// - `dart run :xtask` in the root where the root has no resolution yet:
///   `dart run` resolves one there first, which a file cannot have done for
///   it. The one form that moves the run, and only until the first `pub get`.
ProjectEntry? projectEntry(
  List<String> args, {
  required String workingDirectory,
  required Map<String, String> environment,
}) {
  if (args.any(_isCompletion)) {
    return null;
  }
  final root = findRoot(workingDirectory);
  if (root == null ||
      !File(p.join(root, 'bin', 'xtask.dart')).existsSync() ||
      environment[projectEntryVariable] == root) {
    return null;
  }
  final name = _packageName(root);
  if (name == null || name == 'xtask') {
    return null;
  }
  if (_resolves(name, root, from: workingDirectory)) {
    return (
      root: root,
      arguments: ['run', '$name:xtask', ...args],
      workingDirectory: null,
    );
  }
  if (File(p.join(root, '.dart_tool', 'package_config.json')).existsSync()) {
    return (
      root: root,
      arguments: ['run', p.join(root, 'bin', 'xtask.dart'), ...args],
      workingDirectory: null,
    );
  }
  return (
    root: root,
    arguments: ['run', ':xtask', ...args],
    workingDirectory: root,
  );
}

/// Starts [entry] on this process's own three descriptors, and answers with
/// the code it ends with.
///
/// Ctrl-C reaches the project's run from the terminal, which signals the
/// whole foreground group; this process waits for it rather than ending
/// first and handing the prompt back over a run still printing. A `SIGTERM`
/// sent to this process alone is passed on.
Future<int> runProjectEntry(
  ProjectEntry entry, {
  required Map<String, String> environment,
  required void Function(String line) err,
  ExecutableResolver? resolver,
}) async {
  final paths = resolver ?? ExecutableResolver.forHost();
  final from = entry.workingDirectory ?? Directory.current.path;
  final dart = paths.resolve('dart', from: from);
  if (dart == null) {
    err(
      'xtask: `${entry.root}` has an entry point of its own, '
      '`bin/xtask.dart`, where its verbs are, and it takes `dart` to run it. '
      '${paths.missingToolMessage('dart', from: from)}',
    );
    return ExitCode.missingTool;
  }
  final shell = paths.needsShell(dart);
  if (shell) {
    // The batch-shim rule, for the person's own command line this time:
    // `cmd.exe` reads it before `dart.bat` does.
    for (final argument in entry.arguments) {
      for (final character in cmdMetacharacters) {
        if (argument.contains(character)) {
          err(
            'xtask: `$argument` cannot be handed to `$dart`, which is a '
            'batch file: `cmd.exe` would read `$character` in it before the '
            'project does. Run `dart run :xtask` from the root instead',
          );
          return ExitCode.invalidFile;
        }
      }
    }
  }

  final process = await Process.start(
    dart,
    entry.arguments,
    workingDirectory: entry.workingDirectory,
    environment: {...environment, projectEntryVariable: entry.root},
    includeParentEnvironment: false,
    runInShell: shell,
    mode: ProcessStartMode.inheritStdio,
  );
  final watching = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) {}),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => process.kill()),
  ];
  try {
    final code = await process.exitCode;
    // A run ended by a signal answers as a shell would say it: 128 and the
    // signal, where Dart reports the signal negated.
    return code < 0 ? 128 - code : code;
  } finally {
    for (final watch in watching) {
      await watch.cancel();
    }
  }
}

bool _isCompletion(String argument) =>
    argument == '--names' ||
    argument == '--completion' ||
    argument.startsWith('--completion=');

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
            return p.equals(
              p.normalize(
                p.fromUri(Uri.directory(p.dirname(config.path)).resolve(uri)),
              ),
              root,
            );
          }
        }
      } on FormatException {
        // Read as having no such package: the file form does not need it.
      }
      return false;
    }
    if (p.dirname(directory) == directory) {
      return false;
    }
  }
}
