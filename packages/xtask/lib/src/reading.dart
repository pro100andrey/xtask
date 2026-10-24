/// Reading the file from a directory: what every command does first, and what
/// a project's own entry point may ask without starting a second engine.
///
/// **One reading, two callers.** The command line and the exported
/// [gateMembers] both come through here, so the answer a project gets
/// in-process is the answer `--gate-members` prints, refusals included. Kept
/// apart from `cli.dart` because nothing here writes anywhere: a function a
/// project calls must not reach for a terminal that belongs to the project.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'gates.dart';
import 'graph.dart';
import 'model.dart';
import 'parse.dart';
import 'request.dart';

/// The directory holding `xtask.yaml`, looked for from [from] upwards, or
/// null when neither [from] nor any directory above it has one.
///
/// **Upwards, and that is a decision.** The file lives at the repository
/// root, and everything in it is relative to that root: `in:`, a set's globs,
/// what `remove` is allowed to touch. Reading `./xtask.yaml` would be correct
/// only when somebody happens to be standing at the top — from `packages/lake`
/// it finds nothing, and the obvious repair, taking the current directory as
/// the root, resolves every path against the wrong place without saying so.
/// Walking up makes the root a property of the repository rather than of where
/// the terminal is.
String? findRoot(String from) {
  var directory = p.absolute(from);
  while (true) {
    if (File(p.join(directory, xtaskFileName)).existsSync()) {
      return directory;
    }
    final parent = p.dirname(directory);
    if (parent == directory) {
      return null;
    }
    directory = parent;
  }
}

/// The file found from [workingDirectory], read and parsed: where its root
/// is, the path it was read from, and what it says.
///
/// Throws [XtaskFormatException] where there is no file to read, where the
/// one found cannot be read, and where it does not parse. The first two carry
/// no span — they have no line to point at — and are worded as the command
/// line says them, `xtask:` and all, because the command line says exactly
/// what this throws.
({String root, String path, XtaskFile file}) readFrom(
  String workingDirectory,
) {
  final root = findRoot(workingDirectory);
  if (root == null) {
    throw XtaskFormatException(
      'xtask: no `$xtaskFileName` in `$workingDirectory` or any directory '
      'above it. It belongs at the repository root, and every path in it '
      'is relative to wherever it is',
    );
  }
  final path = p.join(root, xtaskFileName);
  final String text;
  try {
    text = File(path).readAsStringSync();
  } on FileSystemException catch (problem) {
    // `findRoot` proved the file is there, so this is a permission or a
    // device — worth a sentence rather than a stack trace.
    throw XtaskFormatException(
      'xtask: cannot read `$path`: ${problem.osError?.message ?? problem}',
    );
  }
  return (
    root: root,
    path: path,
    file: parseXtaskFile(text, sourceUrl: Uri.file(path)),
  );
}

/// The tasks in gate set [gate], in the order a run of it starts them — the
/// lines `xtask --gate-members <gate>` prints, without starting a process to
/// print them.
///
/// The file is looked for from [workingDirectory] upwards, as a command run
/// there would look for it; left out, from the directory this process runs
/// in. It is read afresh on every call, so an answer is never older than the
/// file.
///
/// Throws [XtaskFormatException], with the message `--gate-members` prints
/// for the same case, when:
///
/// - there is no `xtask.yaml` in that directory or any directory above it;
/// - the one found cannot be read (a permission, a device);
/// - it does not parse, or says something the engine refuses on reading;
/// - it declares no gate set called [gate]. A typo answered with an empty
///   list would read as "that gate checks nothing", which is the failure this
///   tool is against; a declared gate set with no members is `--validate`'s
///   question, and answers `[]` here.
List<String> gateMembers(String gate, {String? workingDirectory}) {
  final (root: _, path: _, :file) = readFrom(
    workingDirectory ?? Directory.current.path,
  );
  return [
    for (final task in tasksInGate(file, declaredGate(file, gate))) task.name,
  ];
}

/// [gate], if the file declares it.
///
/// A gate set that is not declared is a typo, and the answer to a typo must
/// not be an empty list: `--gate-members ci-analize` printing nothing reads as
/// "that job checks nothing", which is the failure this whole tool is about.
/// Whether a DECLARED gate has members is `--validate`'s question, not
/// this one's.
String declaredGate(XtaskFile file, String gate) {
  final known = file.gates.keys.toSet();
  if (known.contains(gate)) {
    return gate;
  }
  throw XtaskFormatException(
    'there is no gate set called `$gate`'
    '${unknownNameHint(gate, known, otherwise: theFileHas(known))}',
  );
}

/// What follows an unknown name when nothing is near it: every name there
/// is, where the list is short enough to be the answer.
String theFileHas(Iterable<String> known) => known.isEmpty
    ? ''
    : ' — this file has '
          '${(known.toList()..sort()).map((n) => '`$n`').join(', ')}';
