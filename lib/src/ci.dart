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
/// **And what belongs to the workflow, this must not refuse.** Two of those
/// four arrive as `uses:` and are passed over here; a browser driver does not
/// — Playwright's own action says "you don't need this GitHub Action" and
/// sends you to `npx playwright install --with-deps` — and neither does a line
/// writing `$GITHUB_ENV`. So the rule below is blanket and [exemptionMarker]
/// is what it costs, rather than a rule that tries to tell infrastructure from
/// logic. Nothing does: no workflow linter classifies a `run:` step that way,
/// and one inventing the axis here would be reading shell.
///
/// A check closes the same drift and needs none of that. It reads the workflow
/// that a person wrote and compares it with the gate sets, in both directions.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';
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
  const CiStep(this.workflow, this.job, this.command, {this.exemption});

  /// The file it came from, relative to the repository root.
  final String workflow;

  final String job;

  /// The `run:` block, trimmed. A block written with `|` keeps its newlines:
  /// GitHub writes the whole of it to one file and runs it as one script, so
  /// splitting it into commands here would be this checker deciding what a
  /// shell means — which is the second grammar [_readStep] exists not to
  /// keep. A block this cannot read is a block to exempt.
  final String command;

  /// The reason written beside it, when a person said this step is not a gate.
  ///
  /// Null unless the step carries [exemptionMarker].
  final String? exemption;
}

/// What a person writes beside a `run:` step that is not a gate set.
///
/// **A blanket rule, paid for out loud.** The rule below is that a `run:` step
/// is one invocation of one gate set, and it is kept blanket on purpose: a
/// checker that tried to tell a step installing a browser driver from a step
/// running the build would be classifying shell, which nothing does and this
/// least of all. So the rule stays absolute and the exception is written
/// where the exception is, by the person who knows why.
///
/// The reason is required. An exemption whose reason is missing is refused
/// like any other bad step, because a marker with nothing after it is the
/// form this grows into when it is used to make a red gate green.
const exemptionMarker = '# xtask: not a gate';

/// Why a shell step is not a job running a gate set.
///
/// **A value, not a sentence.** This module computed the prose as well as the
/// finding, while `report.dart` is the declared home of everything the tool
/// says to a person — and built the same `workflow: job … runs` prefix a
/// fourth time for the one case that is not a problem. A reason that carries
/// its own facts cannot be put into the wrong sentence.
sealed class CiProblem {
  const CiProblem(this.step);

  /// The step it is about.
  final CiStep step;
}

/// A step that names a command rather than a gate set.
///
/// The duplicate list growing back, and it grows exactly like this: somebody
/// adds `- run: dart analyze` instead of a task to the file.
final class RunsACommand extends CiProblem {
  const RunsACommand(super.step);
}

/// A step the command line itself would turn away.
///
/// It may name a gate set correctly and still exit before doing anything —
/// `-j abc`, a trailing `-j`, arguments after `--` for a gate set that has no
/// body. [refusal] is the command line's own sentence about it.
final class RunsSomethingRefused extends CiProblem {
  const RunsSomethingRefused(super.step, this.refusal);

  final String refusal;
}

/// A step that names a gate set in a mode, so the job does not run it.
///
/// `xtask --dry-run ci-analyze` reads, in a job called `ci-analyze`, as though
/// the gate is covered; nothing of it happens. It is the shape a step takes
/// when somebody was debugging and did not take the flag back out, and the
/// green tick afterwards is the whole problem.
final class NamesAGateWithoutRunningIt extends CiProblem {
  const NamesAGateWithoutRunningIt(super.step, this.mode, this.named);

  /// The mode flag that made it a question rather than a run.
  final String mode;

  /// The gate set or task the step named.
  final String named;
}

/// An exemption marker with nothing after it.
///
/// The reason is the whole price of the exemption, so a marker without one is
/// refused rather than honoured: `# xtask: not a gate` alone is what this
/// grows into when somebody reaches for it to make a red gate green.
final class ExemptsWithoutSaying extends CiProblem {
  const ExemptsWithoutSaying(super.step);
}

/// An exemption on a step that reaches xtask after all.
///
/// The marker says the step is not a gate set. On a step that names one — or
/// asks xtask a question — it says something untrue, and excuses nothing: the
/// step was never going to be reported as a command. Refused, because a marker
/// that excuses nothing is how the load-bearing ones become impossible to
/// find, and because it was hiding real findings — a misspelled gate set
/// stopped being reported the moment somebody wrote one above it.
final class ExemptsNothing extends CiProblem {
  const ExemptsNothing(super.step, this.reaches);

  /// What the step turned out to be: a gate set, or the mode it asks for.
  final String reaches;
}

/// A step naming a gate set this file does not declare — so the job runs
/// nothing.
final class RunsAnUndeclaredGate extends CiProblem {
  const RunsAnUndeclaredGate(super.step, this.gate, this.declared);

  final String gate;

  /// The gate sets the file does declare, for the message to name.
  final Set<String> declared;
}

/// What `--check-ci` found.
final class CiReport {
  const CiReport({
    required this.invocations,
    required this.problems,
    required this.unrun,
    this.questions = const [],
    this.exempted = const [],
  });

  /// Every shell step that is a well-formed invocation, by gate set.
  final List<({CiStep step, String gate})> invocations;

  /// Steps that reach xtask without running a gate — `--validate`, `--list`,
  /// `--check-ci`.
  ///
  /// **Reported and not judged**, like [unrun] and for a related reason. Such
  /// a step names no command that could drift from the task file: it names
  /// this tool, asking it a question. Filing it under "what runs belongs in
  /// the task file" sent a reader to move something that is not a task and
  /// has nowhere to be moved to — and said it about `--check-ci` itself, the
  /// step §7.1 asks a project to add.
  final List<({CiStep step, String mode})> questions;

  /// Steps a person exempted, with the reason each gave.
  ///
  /// Counted here rather than passed over silently: an exemption nobody can
  /// see is one nobody revisits, and the count is what makes a workflow that
  /// has quietly exempted its way to green visible in one line.
  final List<CiStep> exempted;

  /// Steps that are not one, and gates named by one that is not declared.
  final List<CiProblem> problems;

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
  final questions = <({CiStep step, String mode})>[];
  final exempted = <CiStep>[];
  final problems = <CiProblem>[];

  for (final step in steps) {
    final read = _readStep(step.command);
    final exemption = step.exemption;

    // **The exemption is asked last, and only of a step that would otherwise
    // be a command.** Asked first, it swallowed everything: a marker on
    // `xtask check -j abc` hid the command line's own refusal, and a marker on
    // `xtask chekc` hid a misspelled gate set — so a job that runs nothing
    // passed, which is the silent green this mode exists to prevent. What the
    // marker says is "this step is not a gate set", and that is a sentence
    // about exactly one of the outcomes below.
    if (read.refused case final refusal?) {
      problems.add(RunsSomethingRefused(step, refusal));
      continue;
    }
    if (read.gate case final gate?) {
      if (exemption != null) {
        problems.add(ExemptsNothing(step, gate));
      } else if (!declared.contains(gate)) {
        problems.add(RunsAnUndeclaredGate(step, gate, declared));
      } else {
        invocations.add((step: step, gate: gate));
      }
      continue;
    }
    if (read.named case final named?) {
      problems.add(
        exemption != null
            ? ExemptsNothing(step, named)
            : NamesAGateWithoutRunningIt(step, read.mode ?? '', named),
      );
      continue;
    }
    if (read.mode case final mode?) {
      if (exemption != null) {
        problems.add(ExemptsNothing(step, mode));
      } else {
        questions.add((step: step, mode: mode));
      }
      continue;
    }
    if (exemption != null) {
      if (exemption.isEmpty) {
        problems.add(ExemptsWithoutSaying(step));
      } else {
        exempted.add(step);
      }
      continue;
    }
    problems.add(RunsACommand(step));
  }

  if (invocations.isEmpty &&
      questions.isEmpty &&
      exempted.isEmpty &&
      problems.isEmpty) {
    throw XtaskFormatException(
      'nothing under `$workflowDirectory` invokes xtask, so there is nothing '
      'to check this file against',
    );
  }

  final run = {for (final invocation in invocations) invocation.gate};
  return CiReport(
    invocations: List.unmodifiable(invocations),
    questions: List.unmodifiable(questions),
    exempted: List.unmodifiable(exempted),
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

/// Whether splitting on whitespace cut [word] out of a quoted string.
///
/// An odd count is what says so. A balanced pair is a quoted argument that
/// survived the split whole, and `-j "2"` is a thing somebody writes.
bool _cutThroughAQuote(String word) =>
    '"'.allMatches(word).length.isOdd || "'".allMatches(word).length.isOdd;

/// [word] without the quotes a shell would take off it.
String _unquoted(String word) => word.replaceAll('"', '').replaceAll("'", '');

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
({String? gate, String? refused, String? mode, String? named}) _readStep(
  String command,
) {
  const notAnInvocation = (
    gate: null,
    refused: null,
    mode: null,
    named: null,
  );
  final words = command.split(RegExp(r'\s+'));
  final at = words.indexWhere(_namesXtask);
  if (at == -1) {
    return notAnInvocation;
  }

  // **Only the words this is about to parse, and only unbalanced quotes.**
  // Splitting on whitespace is not what a shell does, so a word may still be
  // wearing half of the quote it was written inside: `echo "install xtask
  // first"` gives `first"` after the xtask word, and reading on from it
  // reported `first"` as a gate set the file does not declare. An odd number
  // of quotes is what says the split cut through a string.
  //
  // Judged on these words rather than on the whole step, because a step may
  // quote something before reaching xtask — a `run: |` block that echoes a
  // line and then runs the gate — and a balanced pair is an ordinary argument
  // that survives the split whole.
  final arguments = words.skip(at + 1).toList();
  if (arguments.any(_cutThroughAQuote)) {
    return notAnInvocation;
  }

  final request = parseArguments(
    arguments.map(_unquoted).toList(),
    // The number is discarded — only whether it PARSES is being asked — and a
    // check that read this machine's width would vouch differently for one
    // workflow on two runners.
    processors: () => 1,
  );
  return switch (request) {
    RunTask(:final task, arguments: []) => (
      gate: task,
      refused: null,
      mode: null,
      named: null,
    ),
    // A gate set has no body, so the arguments reach nothing and the step
    // exits 2. The command line does not refuse this — only the file can say
    // whether the name has a body — so the sentence is written here.
    RunTask() => (
      gate: null,
      mode: null,
      named: null,
      refused:
          'a gate set gathers tasks and runs nothing of its own, so there is '
          'nothing for the arguments after `--` to be arguments to',
    ),
    // Everything the command line itself would turn away, in its own words.
    ShowUsage(problem: final problem?) => (
      gate: null,
      mode: null,
      named: null,
      refused: problem,
    ),
    // **A mode that names a gate set is a job that does not run it.** The
    // step reads as though the gate is covered and nothing of it happens, so
    // this stays a finding — but its own, because "what runs belongs in the
    // task file" tells a reader to move a gate that is already there.
    DryRunTask(:final task) => _names(task, words, at),
    GateMembers(:final gate) => _names(gate, words, at),
    WhyTask(:final task) => _names(task, words, at),
    ListTasks(gate: final gate?) => _names(gate, words, at),
    // **A mode that names nothing is a question, not a broken step.** This
    // said so in a comment and then answered `notAnInvocation`, which the
    // caller cannot tell from "no xtask here at all" — so `- run: xtask
    // --validate` was filed under "what runs belongs in the task file", and
    // so was `--check-ci`, the step §7.1 asks a project to add.
    _ => (
      gate: null,
      refused: null,
      named: null,
      mode: _modeIn(words.skip(at + 1)),
    ),
  };
}

/// A mode that names [what], for the finding to quote both.
({String? gate, String? refused, String? mode, String? named}) _names(
  String what,
  List<String> words,
  int at,
) => (
  gate: null,
  refused: null,
  mode: _modeIn(words.skip(at + 1)),
  named: what,
);

/// The mode flag among [arguments], for the report to name.
String? _modeIn(Iterable<String> arguments) {
  for (final argument in arguments) {
    if (modes.contains(argument)) {
      return argument;
    }
  }
  return null;
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
  final lines = source.split('\n');
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
        yield CiStep(
          name,
          '${entry.key}',
          command.trim(),
          exemption: _exemptionNear(lines, step.nodes['run']?.span),
        );
      }
    }
  }
}

/// The reason written beside the `run:` key at [span], if there is one.
///
/// **Read out of the source, because the parse does not keep it.**
/// `package:yaml` discards comments — there is no comment on a `YamlNode` to
/// ask — so the only place [exemptionMarker] survives is the text, and a span
/// is what says which text. Looked for on the `run:` line itself and on the
/// line above it, which are the two places a person writes a note about a
/// step; anywhere further and it stops being beside the thing it excuses.
///
/// A marker with nothing after it comes back as the empty string rather than
/// null, so that the caller can tell "no exemption" from "an exemption that
/// gave no reason" and refuse the second.
String? _exemptionNear(List<String> lines, SourceSpan? span) {
  if (span == null) {
    return null;
  }
  // A block scalar's span starts at the `|`, and the marker belongs to the
  // line that carries the key. Both candidates are read for that reason.
  final at = span.start.line;
  for (final line in [
    if (at < lines.length) lines[at],
    // **Only when the line above is nothing but a comment.** Taken as written,
    // a marker trailing one step's own line was also found by the step under
    // it: `- run: npm ci # xtask: not a gate — deps` exempted the `- run: dart
    // analyze` beneath it, which is the duplicate list growing back, green,
    // under somebody else's reason.
    if (at > 0 &&
        at - 1 < lines.length &&
        lines[at - 1].trimLeft().startsWith('#'))
      lines[at - 1],
  ]) {
    final marker = line.indexOf(exemptionMarker);
    if (marker != -1) {
      // The dash or colon somebody writes between the marker and the reason
      // is punctuation, and the report supplies its own — kept, it renders as
      // `exempts \u0060x\u0060 — — the reason`.
      return line
          .substring(marker + exemptionMarker.length)
          .replaceFirst(RegExp(r'^[\s\u2014\u2013:,-]+'), '')
          .trim();
    }
  }
  return null;
}
