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

import 'errors.dart';
import 'gates.dart';
import 'model.dart';

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
  final directory = Directory(
    p.join(
      root,
      p.joinAll(
        p.posix.split(
          workflowDirectory,
        ),
      ),
    ),
  );
  if (!directory.existsSync()) {
    throw XtaskFormatException(
      'there is no `$workflowDirectory` under `$root`, so there is nothing to '
      'check this file against',
    );
  }

  final declared = file.gates.keys.toSet();

  final steps = <CiStep>[];
  for (final workflow in directory.listSync().whereType<File>()) {
    final name = p.basename(workflow.path);
    if (!name.endsWith('.yml') && !name.endsWith('.yaml')) {
      continue;
    }
    steps.addAll(_shellSteps(workflow, p.posix.join(workflowDirectory, name)));
  }

  final invocations = <({CiStep step, String gate})>[];
  final problems = <String>[];

  for (final step in steps) {
    final gate = _gateOf(step.command);
    if (gate == null) {
      // The duplicate list growing back, and it grows exactly like this:
      // somebody adds `- run: dart analyze` instead of a task to the file.
      problems.add(
        '${step.workflow}: job `${step.job}` runs `${step.command}`. What runs '
        'belongs in the task file as a task in a gate set; a job runs the '
        'gate, so that the two cannot drift apart',
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

/// The gate set [command] invokes, or null if it is not an invocation at all.
///
/// Deliberately loose about HOW xtask is reached — `dart run :xtask check`,
/// `dart run bin/xtask.dart check`, a compiled `./xtask check` — because §9
/// leaves the entry point to the project and a checker that only recognised
/// one spelling would report a working workflow as broken.
String? _gateOf(String command) {
  final words = command.split(RegExp(r'\s+'));
  final at = words.indexWhere(
    (word) =>
        word == 'xtask' ||
        word.endsWith(':xtask') ||
        word.endsWith('xtask.dart') ||
        word.endsWith('/xtask'),
  );
  if (at == -1) {
    return null;
  }

  // **Flags are allowed after the name; a second operand is not.** This asked
  // for exactly one word after the token and refused anything starting with
  // `-`, which made `xtask check -j 4` — and `--keep-going`, and every other
  // modifier — impossible to write in a workflow. §7.1 sends all parallelism
  // to CI and this forbade the one construct that provides it. What must
  // stay refused is a step doing two THINGS, which is a second operand.
  final after = words.skip(at + 1).toList();
  final operands = <String>[];
  for (var i = 0; i < after.length; i++) {
    final word = after[i];
    if (!word.startsWith('-')) {
      operands.add(word);
      continue;
    }

    // **Named, not guessed.** Skipping a following word whenever a flag had
    // no `=` swallowed the gate set after `-j4` — the attached spelling this
    // very change advertises — and reported a valid workflow as a step doing
    // something other than running a gate.
    final flag = word.startsWith('--')
        ? (word.contains('=') ? word.substring(0, word.indexOf('=')) : word)
        : word.substring(0, 2);
    if (!_runModifiers.contains(flag)) {
      // A mode rather than a modifier — `--dry-run check` names a gate set
      // and does not run it, which is not what a job is being vouched for.
      return null;
    }
    final attached = word.length > flag.length;
    if (!attached && _takesAValue.contains(flag) && i + 1 < after.length) {
      i++;
    }
  }
  return operands.length == 1 ? operands.single : null;
}

/// The flags that modify a run rather than replacing it. Anything else after
/// the name means the step is doing something other than running a gate set.
const _runModifiers = {'-j', '--jobs', '--keep-going'};

/// Of those, the ones whose value may be a separate word.
const _takesAValue = {'-j', '--jobs'};

Iterable<CiStep> _shellSteps(File workflow, String name) sync* {
  final YamlNode document;
  try {
    document = loadYamlNode(workflow.readAsStringSync());
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
