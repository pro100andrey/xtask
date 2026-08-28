/// Checking that the CI file and the gate sets still agree — §7.1's residual.
///
/// **A checker, and the generator was refused.** §7.1 named `--emit-ci` as the
/// way to close this and marked it considered-and-deferred; doing it means
/// producing the workflow, and the workflow contains what §7.1 explicitly
/// leaves to it — the checkout, the toolchain, a browser driver, an artifact
/// upload. Generating those needs somewhere to write them down, which means a
/// template inside `xtask.yaml`, which is templating: §10 rules it out, and
/// the first `${...}` in it is the start of the expression language R1 exists
/// to prevent.
///
/// A check closes the same drift and needs none of that. It reads the workflow
/// that a person wrote and compares it with the gate sets, in both directions.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'boundary.dart';
import 'errors.dart';
import 'gates.dart';
import 'model.dart';
import 'request.dart';

/// Where a workflow lives, relative to the repository root.
const workflowDirectory = '.github/workflows';

/// One shell step of one job.
final class CiStep {
  const CiStep(this.workflow, this.job, this.command);

  /// The file it came from, relative to the repository root.
  final String workflow;

  final String job;

  /// The `run:` line, trimmed.
  final String command;
}

/// What `--check-ci` found.
final class CiReport {
  const CiReport({
    required this.invocations,
    required this.problems,
    required this.unrun,
  });

  /// Every shell step that is a well-formed invocation, by gate set.
  final List<({CiStep step, String gate})> invocations;

  /// Steps that are not one, and gates named by one that is not declared.
  final List<String> problems;

  /// Gate sets no job runs.
  ///
  /// **Not a problem, and that is the honest part.** A gate set is named after
  /// who runs it, and §7.1 says that is the set of jobs *plus the set of human
  /// entry points* — so a gate nothing in CI runs is right when somebody runs
  /// it by hand and wrong when a job was forgotten. Nothing in the file
  /// distinguishes those, and a key that claimed to would be a second place
  /// saying what the workflow already says. So it is reported and not judged.
  final List<String> unrun;

  bool get ok => problems.isEmpty;
}

/// What the workflows under [root] run, checked against [file]'s gate sets.
///
/// Throws [XtaskFormatException] when there is nothing to check. A repository
/// with no workflow, or one whose workflow never invokes `xtask`, is not a
/// repository this question has an answer for — and answering 0 would let a
/// gate that asks it pass after somebody deleted the CI file.
CiReport checkCi(XtaskFile file, {required String root}) {
  final directory = Directory(underRoot(root, workflowDirectory));
  if (!directory.existsSync()) {
    throw XtaskFormatException(
      'there is no `$workflowDirectory` under `$root`, so there is nothing to '
      'check this file against',
    );
  }

  final declared = file.gates.keys.toSet();

  final List<FileSystemEntity> present;
  try {
    present = directory.listSync();
  } on FileSystemException catch (problem) {
    // Unguarded, this ended `--check-ci` on a stack trace and exit 255 — from
    // the gate the README tells every project to run in CI, about the very
    // directory it was pointed at. `existsSync` above is also a window: it can
    // be true and this still fail.
    throw XtaskFormatException(
      'cannot read `$workflowDirectory` under `$root`: '
      '${problem.osError?.message ?? problem.message}',
    );
  }

  final steps = <CiStep>[];
  for (final workflow in present.whereType<File>()) {
    final name = p.basename(workflow.path);
    if (!name.endsWith('.yml') && !name.endsWith('.yaml')) {
      continue;
    }
    steps.addAll(_shellSteps(workflow, p.posix.join(workflowDirectory, name)));
  }

  final invocations = <({CiStep step, String gate})>[];
  final problems = <String>[];

  for (final step in steps) {
    final read = _readStep(step.command);
    final gate = read.gate;
    if (gate == null) {
      final refused = read.refused;
      problems.add(
        refused == null
            // The duplicate list growing back, and it grows exactly like this:
            // somebody adds `- run: dart analyze` instead of a task to the
            // file.
            ? '${step.workflow}: job `${step.job}` runs `${step.command}`. '
                  'What runs belongs in the task file as a task in a gate set; '
                  'a job runs the gate, so that the two cannot drift apart'
            // **The command line's own sentence, not a guess at it.** This
            // step names a gate set correctly and would still exit before
            // doing anything, and saying "what runs belongs in the task file"
            // about it sends the reader to move a task that is already there.
            : '${step.workflow}: job `${step.job}` runs `${step.command}`, '
                  'which xtask refuses: $refused',
      );
      continue;
    }
    if (!declared.contains(gate)) {
      problems.add(
        '${step.workflow}: job `${step.job}` runs the gate set `$gate`, which '
        'this file does not declare — so the job runs nothing'
        '${declared.isEmpty ? '' : '. Declared: '
                  '${(declared.toList()..sort()).join(', ')}'}',
      );
      continue;
    }
    invocations.add((step: step, gate: gate));
  }

  if (invocations.isEmpty && problems.isEmpty) {
    throw XtaskFormatException(
      'nothing under `$workflowDirectory` invokes xtask, so there is nothing '
      'to check this file against',
    );
  }

  final run = {for (final invocation in invocations) invocation.gate};
  return CiReport(
    invocations: List.unmodifiable(invocations),
    problems: List.unmodifiable(problems),
    unrun: List.unmodifiable([
      for (final gate in declared.toList()..sort())
        if (!run.contains(gate) && tasksInGate(file, gate).isNotEmpty) gate,
    ]),
  );
}

/// Whether [word] is how this project reaches xtask.
///
/// Deliberately loose about HOW — `dart run :xtask check`, `dart run
/// bin/xtask.dart check`, a compiled `./xtask check` — because §9 leaves the
/// entry point to the project and a checker that only recognised one spelling
/// would report a working workflow as broken.
bool _namesXtask(String word) =>
    word == 'xtask' ||
    word.endsWith(':xtask') ||
    word.endsWith('xtask.dart') ||
    word.endsWith('/xtask');

/// What shell step [command] turns out to be.
///
/// **Decided by parsing it, not by reading it a second way.** This used to walk
/// the words itself — attached values against separate ones, `--jobs=` against
/// `-j4`, a lone `-`, a second operand — which is the command line's grammar
/// written twice, in a checker whose whole job is that one thing is not written
/// twice. Both copies had already been wrong: `-j4` swallowed the gate set
/// after it, and a lone `-` raised a `RangeError` out of `--check-ci`.
///
/// So the words go to the parser the command line uses, and what comes back is
/// asked a question. A mode names a gate set without running it; anything the
/// command line refuses is a step that exits before it does anything; and
/// arguments after `--` have nothing to reach, because a gate set has no body.
/// Each of those is a [Request] that is not a bare [RunTask], and none of them
/// is spelled out here.
({String? gate, String? refused}) _readStep(String command) {
  const notAnInvocation = (gate: null, refused: null);
  final words = command.split(RegExp(r'\s+'));
  final at = words.indexWhere(_namesXtask);
  if (at == -1) {
    return notAnInvocation;
  }

  final request = parseArguments(
    words.skip(at + 1).toList(),
    // The number is discarded — only whether it PARSES is being asked — and a
    // check that read this machine's width would vouch differently for one
    // workflow on two runners.
    processors: () => 1,
  );
  return switch (request) {
    RunTask(:final task, arguments: []) => (gate: task, refused: null),
    // A gate set has no body, so the arguments reach nothing and the step
    // exits 2. The command line does not refuse this — only the file can say
    // whether the name has a body — so the sentence is written here.
    RunTask() => (
      gate: null,
      refused:
          'a gate set gathers tasks and runs nothing of its own, so there is '
          'nothing for the arguments after `--` to be arguments to',
    ),
    // Everything the command line itself would turn away, in its own words.
    ShowUsage(problem: final problem?) => (gate: null, refused: problem),
    // A mode names a gate set without running it, which is a step doing
    // something other than running a gate rather than a broken one.
    _ => notAnInvocation,
  };
}

Iterable<CiStep> _shellSteps(File workflow, String name) sync* {
  final String source;
  try {
    source = workflow.readAsStringSync();
  } on FileSystemException catch (problem) {
    // A workflow that is not UTF-8, or that this process may not open. Only
    // `YamlException` was caught, so either ended the run at 255.
    throw XtaskFormatException(
      '$name: ${problem.osError?.message ?? problem.message}',
    );
  }

  final YamlNode document;
  try {
    document = loadYamlNode(source);
  } on YamlException catch (e) {
    throw XtaskFormatException('$name: ${e.message}');
  }
  if (document is! YamlMap) {
    return;
  }
  final jobs = document['jobs'];
  if (jobs is! YamlMap) {
    return;
  }
  for (final entry in jobs.entries) {
    final job = entry.value;
    if (job is! YamlMap) {
      continue;
    }
    final steps = job['steps'];
    if (steps is! YamlList) {
      continue;
    }
    for (final step in steps) {
      if (step is! YamlMap) {
        continue;
      }
      if (step['run'] case final String command) {
        yield CiStep(name, '${entry.key}', command.trim());
      }
    }
  }
}
