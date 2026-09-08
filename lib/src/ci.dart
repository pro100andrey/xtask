/// Checking that the CI file and the gate sets still agree.
///
/// A checker rather than a generator: producing the workflow means a template
/// inside `xtask.yaml`, and templating is where an expression language starts.
/// A check closes the same drift by reading the workflow somebody wrote and
/// comparing it with the gate sets, in both directions.
///
/// The rule is that a `run:` step is one invocation of one declared gate set,
/// and it is applied to the step **as written**. This module reads no shell:
/// no quotes, no `&&`, no builtins. Every reading of shell a checker attempts
/// is a way for a step that runs nothing to be counted as running something,
/// so a step this cannot read whole is reported rather than guessed at, and
/// [exemptionMarker] is what a person writes where the rule is wrong.
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

/// One `run:` step of one job.
final class CiStep {
  const CiStep(
    this.workflow,
    this.job,
    this.command, {
    this.exemption,
    this.condition,
    this.readsAnotherFile,
    this.cannotFail = false,
    this.jobCannotFail = false,
  });

  /// The file it came from, relative to the repository root.
  final String workflow;

  final String job;

  /// The step's `run:`, trimmed, with a `\` at the end of a line joining it to
  /// the next. A step whose `run:` still holds a line break is a script.
  final String command;

  /// The reason written after [exemptionMarker] on the `run:` line, or null
  /// when there is no marker. Empty when the marker gives no reason.
  final String? exemption;

  /// The step's `if:`, as written, or null.
  ///
  /// Reported beside the gate the step runs and not judged: whether the
  /// condition holds is the workflow's business, and a checker that decided
  /// it would be reading an expression language it does not have.
  final String? condition;

  /// The step's `working-directory:` when a different `xtask.yaml` is there,
  /// as written; null otherwise.
  ///
  /// **`working-directory:` is the sanctioned prefix and stays one.** A step
  /// that moves into a directory with no file of its own still reaches this
  /// one, because the file is looked for upwards — so the gate it names is
  /// this file's gate and the credit is right. What is not right is a
  /// directory holding its own `xtask.yaml`: the invocation reads THAT file,
  /// runs its gate set of that name, and says nothing about this one, while
  /// being counted here as the job that runs it. A silent green in the mode
  /// written to prevent them.
  ///
  /// Decided where the root is known and carried as a fact, so that judging a
  /// step stays a question about the step.
  final String? readsAnotherFile;

  /// Whether `continue-on-error:` on the step or its job means the result
  /// cannot fail the job.
  ///
  /// A gate whose red does not stop anything is a gate nothing enforces, and
  /// it was being credited as an invocation. The sibling key `if:` was read
  /// from the first; this one was not read at all.
  final bool cannotFail;

  /// Whether the key is on the JOB rather than on this step — which is where a
  /// reader has to go to remove it, and the only reason the two are separate.
  final bool jobCannotFail;
}

/// What a person writes on a `run:` line that is not a gate set.
///
/// The rule is blanket, so the exception is written where the exception is,
/// by the person who knows why — and only there: on the step's own `run:`
/// line, after the command, or after the `|` of a block. One placement,
/// because every further placement is a line that may belong to something
/// else.
///
/// The reason is required. A marker with nothing after it is refused, because
/// a marker with nothing after it is what this becomes when it is reached for
/// to make a red gate green.
const exemptionMarker = '# xtask: not a gate';

/// Why a step is not a job running a gate set.
///
/// A value rather than a sentence: `report.dart` is where the tool's sentences
/// live, and a reason that carries its own facts cannot be put into the wrong
/// one.
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

/// A step whose `run:` is more than one line.
///
/// A script is not read, because reading it means reading shell. What it
/// contains is the author's to say: a marker on the `run: |` line excuses the
/// whole of it, and a gate set it invokes belongs in a step of its own.
final class RunsAScript extends CiProblem {
  const RunsAScript(super.step, this.lines);

  final int lines;
}

/// A step whose `run:` contains a `${{ … }}` expression.
///
/// What the expression comes to is decided by the CI host when the job runs,
/// so nothing about this step can be checked here.
final class RunsAnExpression extends CiProblem {
  const RunsAnExpression(super.step);
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
/// the gate is covered; nothing of it happens.
final class NamesAGateWithoutRunningIt extends CiProblem {
  const NamesAGateWithoutRunningIt(super.step, this.mode, this.named);

  /// The mode flag that made it a question rather than a run.
  final String mode;

  /// The gate set or task the step named.
  final String named;
}

/// An exemption marker with nothing after it.
final class ExemptsWithoutSaying extends CiProblem {
  const ExemptsWithoutSaying(super.step);
}

/// An exemption on a step that reaches xtask after all.
///
/// The marker says the step is not a gate set. On a step that names one, or
/// asks xtask a question, it says something untrue and excuses nothing — and
/// a marker that excuses nothing is how the load-bearing ones become
/// impossible to find.
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

/// A step naming a task where a gate set belongs.
///
/// **Its own finding, because the other one's sentence is untrue about it.**
/// A step running a declared task runs something; reported as an undeclared
/// gate set it was told "the job runs nothing", which sends the reader to look
/// for a typo in a name that is spelt correctly. What is actually wrong is
/// that the CI file has named a MEMBER of a list where the list belongs, so
/// the next task added to that gate is one no job runs and nothing says so.
/// A step that runs a gate set somewhere other than the repository root.
///
/// The invocation reads the `xtask.yaml` in that directory, so it says nothing
/// about this one. Counted as this file's gate it is a silent green: the gate
/// looked run, and the task added to it next week is run by nothing.
final class RunsSomewhereElse extends CiProblem {
  const RunsSomewhereElse(super.step, this.gate, this.where);

  final String gate;

  /// The step's `working-directory:`, as written.
  final String where;
}

/// A step whose result cannot fail its job.
///
/// `continue-on-error: true`, on the step or on the job. The gate runs and its
/// red stops nothing, so nothing is enforced — and it was being counted as the
/// invocation that enforces it.
final class RunsAGateThatCannotFail extends CiProblem {
  const RunsAGateThatCannotFail(super.step, this.gate, this.onTheJob);

  final String gate;

  /// Whether the key is on the job rather than on the step, which is where a
  /// reader has to go to remove it.
  final bool onTheJob;
}

final class RunsATaskNotAGate extends CiProblem {
  const RunsATaskNotAGate(super.step, this.task, this.declared);

  /// The task the step names.
  final String task;

  /// The gate sets the file declares, for the message to point at.
  final Set<String> declared;
}

/// What `--check-ci` found.
final class CiReport {
  const CiReport({
    required this.invocations,
    required this.problems,
    required this.unrun,
    required this.questions,
    required this.exempted,
  });

  /// Every step that is a well-formed invocation, by gate set.
  final List<({CiStep step, String gate})> invocations;

  /// Steps that reach xtask without running a gate — `--validate`, `--list`,
  /// `--check-ci`.
  ///
  /// Reported and not judged: such a step names no command that could drift
  /// from the task file, and `--check-ci` itself is one.
  final List<({CiStep step, String mode})> questions;

  /// Steps a person exempted, with the reason each gave.
  ///
  /// Counted rather than passed over: an exemption nobody can see is one
  /// nobody revisits.
  final List<CiStep> exempted;

  /// Steps that are not one invocation of one declared gate set.
  final List<CiProblem> problems;

  /// Gate sets no job runs.
  ///
  /// Not a problem. A gate set is named after who runs it, and that is the
  /// jobs *plus the people*; nothing in the file distinguishes those, and a
  /// key that claimed to would be a second place saying what the workflow
  /// already says.
  final List<String> unrun;

  bool get ok => problems.isEmpty;
}

/// What one step turns out to be: the findings it carries, and the one thing
/// it counts as.
typedef StepVerdict = ({
  List<CiProblem> problems,
  String? gate,
  String? question,
  bool exempted,
});

/// Reads one step and says what it is.
///
/// Pure, and the whole of the rule: no directory, no file, no other step.
///
/// A step may carry more than one finding. The marker is one fact and what it
/// stands over is another — a misspelled gate set under an exemption is both
/// a job that runs nothing and a marker that excuses nothing — and reporting
/// one instead of the other is how a silent green gets in.
StepVerdict judge(CiStep step, Set<String> declared, Set<String> tasks) {
  final problems = <CiProblem>[];
  final written = step.exemption;
  if (written != null && written.isEmpty) {
    problems.add(ExemptsWithoutSaying(step));
  }
  // An exemption IS its reason; without one there is nothing to weigh, and
  // the step is read as though the marker were not there.
  final reason = written == null || written.isEmpty ? null : written;

  StepVerdict verdict({
    String? gate,
    String? question,
    bool exempted = false,
  }) => (
    problems: List.unmodifiable(problems),
    gate: gate,
    question: question,
    exempted: exempted,
  );

  // The marker is weighed last, and only against a step that would otherwise
  // be reported as a command. What it says is "this step is not a gate set",
  // which is a sentence about exactly one of the readings below.
  switch (_readStep(step.command)) {
    case _Refused(:final refusal):
      problems.add(RunsSomethingRefused(step, refusal));
      if (reason != null) {
        problems.add(ExemptsNothing(step, 'a step the command line refuses'));
      }
      return verdict();
    case _Gate(:final gate):
      // **Two questions about one step: is the name right, and does this
      // invocation ENFORCE the gate here?** The second is what
      // `working-directory:` and `continue-on-error:` answer, and neither is
      // about how the command line is spelt.
      final elsewhere = step.readsAnotherFile;
      final enforces = elsewhere == null && !step.cannotFail;

      // The marker excuses a step that was never this file's gate to begin
      // with — a nested package running its own, or one deliberately allowed
      // to be soft — which is exactly what an exemption is for. A step that
      // DOES enforce the gate is not excused by it: it runs, and saying it is
      // not a gate set would be untrue.
      if (reason != null && !enforces) {
        return verdict(exempted: true);
      }

      final undeclared = !declared.contains(gate);
      if (undeclared) {
        // Which of the two it is decides the sentence, and one of them would
        // be false about the other.
        problems.add(
          tasks.contains(gate)
              ? RunsATaskNotAGate(step, gate, declared)
              : RunsAnUndeclaredGate(step, gate, declared),
        );
      }
      if (elsewhere != null) {
        problems.add(RunsSomewhereElse(step, gate, elsewhere));
      }
      if (step.cannotFail) {
        problems.add(RunsAGateThatCannotFail(step, gate, step.jobCannotFail));
      }
      if (reason != null) {
        problems.add(ExemptsNothing(step, gate));
      }
      if (!enforces) {
        return verdict();
      }
      // The job runs it whatever the marker says, so it is not left unrun.
      return verdict(gate: undeclared ? null : gate);
    case _GateWithArguments(:final name):
      // A gate set has no body, so the arguments reach nothing and the step
      // exits 2. A task with one takes them, and the step is then naming a
      // task where a gate set belongs — which has its own sentence.
      if (tasks.contains(name) && !declared.contains(name)) {
        problems.add(RunsATaskNotAGate(step, name, declared));
      } else {
        problems.add(
          RunsSomethingRefused(
            step,
            'a gate set gathers tasks and runs nothing of its own, so there '
            'is nothing for the arguments after `--` to be arguments to',
          ),
        );
      }
      if (reason != null) {
        problems.add(ExemptsNothing(step, 'a step the command line refuses'));
      }
      return verdict();
    case _Names(:final mode, :final named):
      problems.add(NamesAGateWithoutRunningIt(step, mode, named));
      if (reason != null) {
        problems.add(ExemptsNothing(step, named));
      }
      return verdict();
    case _Question(:final mode):
      if (reason != null) {
        problems.add(ExemptsNothing(step, mode));
        return verdict();
      }
      return verdict(question: mode);
    case _Command():
      if (reason != null) {
        return verdict(exempted: true);
      }
      problems.add(RunsACommand(step));
      return verdict();
    case _Script(:final lines):
      if (reason != null) {
        return verdict(exempted: true);
      }
      problems.add(RunsAScript(step, lines));
      return verdict();
    case _Expression():
      if (reason != null) {
        return verdict(exempted: true);
      }
      problems.add(RunsAnExpression(step));
      return verdict();
  }
}

/// Every `run:` step of every workflow under [root], in a stable order.
///
/// Sorted, because `listSync` answers in the filesystem's order and two
/// workflows would then print their findings one way on one machine and the
/// other way on the next.
List<CiStep> workflowSteps(String root) {
  final directory = Directory(underRoot(root, workflowDirectory));
  if (!directory.existsSync()) {
    throw XtaskFormatException(
      'there is no `$workflowDirectory` under `$root`, so there is nothing to '
      'check this file against',
    );
  }

  final List<FileSystemEntity> present;
  try {
    present = directory.listSync();
  } on FileSystemException catch (problem) {
    // `existsSync` above is a window: it can be true and this still fail.
    throw XtaskFormatException(
      'cannot read `$workflowDirectory` under `$root`: '
      '${problem.osError?.message ?? problem.message}',
    );
  }

  final files = present.whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final workflow in files)
      if (_isAWorkflow(p.basename(workflow.path)))
        ..._steps(
          workflow,
          p.posix.join(workflowDirectory, p.basename(workflow.path)),
          root,
        ),
  ];
}

bool _isAWorkflow(String name) =>
    name.endsWith('.yml') || name.endsWith('.yaml');

/// What the workflows under [root] run, checked against [file]'s gate sets.
///
/// Throws [XtaskFormatException] when there is nothing to check. A repository
/// with no workflow, or one whose workflow never invokes `xtask`, is not a
/// repository this question has an answer for — and answering 0 would let a
/// gate that asks it pass after somebody deleted the CI file.
CiReport checkCi(XtaskFile file, {required String root}) {
  final declared = file.gates.keys.toSet();

  final invocations = <({CiStep step, String gate})>[];
  final questions = <({CiStep step, String mode})>[];
  final exempted = <CiStep>[];
  final problems = <CiProblem>[];

  for (final step in workflowSteps(root)) {
    final verdict = judge(step, declared, file.tasks.keys.toSet());
    problems.addAll(verdict.problems);
    if (verdict.gate case final gate?) {
      invocations.add((step: step, gate: gate));
    }
    if (verdict.question case final mode?) {
      questions.add((step: step, mode: mode));
    }
    if (verdict.exempted) {
      exempted.add(step);
    }
  }

  // Only a run or a finding counts as something to check against. A step
  // somebody exempted does not invoke xtask, and a step that asks xtask a
  // question runs no gate — so a workflow of nothing but `- run: xtask
  // --check-ci` would otherwise pass with its actual invocation deleted.
  if (invocations.isEmpty && problems.isEmpty) {
    throw XtaskFormatException(
      questions.isEmpty
          ? 'nothing under `$workflowDirectory` invokes xtask, so there is '
                'nothing to check this file against'
          : 'nothing under `$workflowDirectory` runs a gate set — the steps '
                'there ask xtask questions, and a question checks nothing '
                'against this file',
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

// ── reading one step ────────────────────────────────────────────────────────

/// What one step's `run:` turns out to be.
sealed class _Reading {
  const _Reading();
}

/// A step naming something and passing arguments after `--`.
///
/// Whether that reaches anything depends on what the name is, which only the
/// file can say — so the reading carries the fact and the judgement decides.
final class _GateWithArguments extends _Reading {
  const _GateWithArguments(this.name);

  final String name;
}

/// One invocation of the gate set (or task) [gate].
final class _Gate extends _Reading {
  const _Gate(this.gate);

  final String gate;
}

/// An invocation the command line refuses, in its own words.
final class _Refused extends _Reading {
  const _Refused(this.refusal);

  final String refusal;
}

/// A question asked of xtask — a mode that names nothing.
final class _Question extends _Reading {
  const _Question(this.mode);

  final String mode;
}

/// A mode that names a gate set without running it.
final class _Names extends _Reading {
  const _Names(this.mode, this.named);

  final String mode;
  final String named;
}

/// A command line that does not invoke xtask.
final class _Command extends _Reading {
  const _Command();
}

/// More than one line.
final class _Script extends _Reading {
  const _Script(this.lines);

  final int lines;
}

/// A `${{ … }}` in it.
final class _Expression extends _Reading {
  const _Expression();
}

/// What [command] turns out to be, read as written.
///
/// One command line, split on whitespace. The words after xtask are handed to
/// the command line's own parser, so `--check-ci` and `xtask` cannot disagree
/// about what a step would do — and nothing else about the line is read.
_Reading _readStep(String command) {
  if (command.contains('\n')) {
    return _Script(command.split('\n').length);
  }
  if (command.contains(r'${{')) {
    return const _Expression();
  }
  final words = command.split(RegExp(r'\s+'));
  final arguments = _argumentsToXtask(words);
  if (arguments == null || words.any(_endsACommand)) {
    return const _Command();
  }
  return _readWords([for (final word in arguments) _unquoted(word)]);
}

/// Whether [word] is one a shell reads as "and then another command".
///
/// The one thing known about shell here, and it is known so that the finding
/// is the right one: `xtask check && dart analyze` is a step running more
/// than one thing, which is "what runs belongs in the task file" — not the
/// parser's sentence about being handed `&&` as an operand.
bool _endsACommand(String word) =>
    const {'&&', '||', ';', '|'}.contains(word) || word.endsWith(';');

/// The words after xtask, where xtask is being **run**, or null.
///
/// In command position only: the first word, or the program `dart` is told to
/// run. A mention anywhere else — `echo run xtask check`, `cp ./xtask
/// /usr/local/bin`, `timeout 600 ./xtask check` — is a command like any other,
/// because telling the ones that run xtask from the ones that mention it
/// means knowing what every program does with its arguments, and that list is
/// never finished. A step that needs a prefix has a key for it: `timeout:` on
/// the task, `working-directory:` on the step.
List<String>? _argumentsToXtask(List<String> words) {
  if (_namesXtask(words.first)) {
    return words.skip(1).toList();
  }
  if (words.first != 'dart') {
    return null;
  }
  for (var at = 1; at < words.length; at++) {
    final word = words[at];
    if (word == 'run' || word.startsWith('-')) {
      continue;
    }
    return _namesXtask(word) ? words.skip(at + 1).toList() : null;
  }
  return null;
}

/// Whether [word] is how a project reaches xtask.
///
/// Loose about the path and the platform — `xtask`, `./xtask`, `:xtask`,
/// `xtask:xtask`, `bin/xtask.dart`, `.\xtask.exe` — because the entry point
/// is the project's, and a checker that only recognised one spelling would
/// report a working workflow as broken.
bool _namesXtask(String word) {
  final name = word.replaceAll(r'\', '/');
  final base = name.substring(name.lastIndexOf('/') + 1);
  return base == 'xtask' ||
      base == 'xtask.exe' ||
      base == 'xtask.bat' ||
      base == 'xtask.dart' ||
      base.endsWith(':xtask');
}

/// [word] without a pair of quotes around the whole of it.
///
/// `-j "2"` is an ordinary thing to write, and `2` is what the child sees.
/// This is the whole of what is known about quotes here: a word that is only
/// partly quoted is left as written, and is then whatever the parser makes of
/// it.
String _unquoted(String word) {
  if (word.length >= 2 &&
      (word.startsWith('"') || word.startsWith("'")) &&
      word.endsWith(word[0])) {
    return word.substring(1, word.length - 1);
  }
  return word;
}

/// What [arguments] make of themselves, read by the command line's own parser.
_Reading _readWords(List<String> arguments) {
  final request = parseArguments(
    arguments,
    // The number is discarded — only whether it PARSES is being asked — and a
    // check that read this machine's width would vouch differently for one
    // workflow on two runners.
    processors: () => 1,
  );
  return switch (request) {
    RunTask(:final task, arguments: []) => _Gate(task),
    // A gate set has no body, so the arguments reach nothing and the step
    // exits 2. The command line does not refuse this — only the file can say
    // whether the name has a body — so the sentence is written here.
    // Whether the arguments reach anything depends on what the name IS, and
    // this function does not have the file. Carried up to `judge`, which
    // does: a task with a body takes arguments, and calling that "a gate set
    // gathers tasks" was a refusal a correct step could not get out of.
    RunTask(:final task) => _GateWithArguments(task),
    ShowUsage(problem: final problem?) => _Refused(problem),
    // The one mode that reads as a run and is not one: `--dry-run ci-analyze`
    // in a job called `ci-analyze` is the shape a step takes when somebody was
    // debugging and left the flag in. Its siblings are inspection, and a job
    // that reports on a gate set never claimed to run it.
    DryRunTask(:final task) => _Names('--dry-run', task),
    ShowUsage() => const _Question('--help'),
    ListTasks() => const _Question('--list'),
    GateMembers() => const _Question('--gate-members'),
    WhyTask() => const _Question('--why'),
    Validate() => const _Question('--validate'),
    CheckCi() => const _Question('--check-ci'),
    ShowVersion() => const _Question('--version'),
    EmitSchema() => const _Question('--emit-schema'),
  };
}

// ── reading the workflow ────────────────────────────────────────────────────

Iterable<CiStep> _steps(File workflow, String name, String root) sync* {
  final source = _source(workflow, name);
  final document = _document(source, name);
  if (document is! YamlMap || document['jobs'] is! YamlMap) {
    return;
  }
  final lines = source.split('\n');
  for (final entry in (document['jobs'] as YamlMap).entries) {
    final job = entry.value;
    if (job is! YamlMap || job['steps'] is! YamlList) {
      continue;
    }
    for (final step in job['steps'] as YamlList) {
      if (step is! YamlMap) {
        continue;
      }
      final run = _entry(step, 'run');
      if (run == null || run.value.value is! String) {
        continue;
      }
      final condition = step.nodes['if'];
      final where = step.nodes['working-directory'];
      yield CiStep(
        name,
        '${entry.key}',
        _joined((run.value.value as String).trim()),
        exemption: _exemptionOn(lines, run.key, run.value),
        condition: condition == null ? null : '${condition.value}',
        readsAnotherFile: _anotherFile(root, where),
        // Either place says it: GitHub applies a job's to every step.
        cannotFail:
            _saysTrue(step.nodes['continue-on-error']) ||
            _saysTrue(job.nodes['continue-on-error']),
        jobCannotFail: _saysTrue(job.nodes['continue-on-error']),
      );
    }
  }
}

/// [where], when a `working-directory:` of that name holds its own task file.
///
/// `.` and `./` are the root written out and move nothing. A directory that is
/// not there, or one outside the repository, is not this checker's to refuse —
/// the workflow is GitHub's file — so it is read as moving nowhere and the
/// step is judged on its command line alone.
String? _anotherFile(String root, YamlNode? where) {
  if (where == null) {
    return null;
  }
  final written = '${where.value}'.trim();
  if (written.isEmpty || written == '.' || written == './') {
    return null;
  }
  if (leavesRoot(written)) {
    return null;
  }
  final own = p.join(underRoot(root, written), xtaskFileName);
  return File(own).existsSync() ? written : null;
}

/// Whether [node] is the literal `true`.
///
/// A `${{ … }}` expression is not read: it is not this checker's language, and
/// guessing would be the reading the rest of this file refuses to do.
bool _saysTrue(YamlNode? node) => node?.value == true;

/// The key node and the value node of [key] in [map], or null.
///
/// The key's node is wanted for its span: the line the key is written on is
/// where the exemption marker is looked for, and it is not the line a block
/// scalar's value begins on.
({YamlNode key, YamlNode value})? _entry(YamlMap map, String key) {
  for (final entry in map.nodes.entries) {
    final written = entry.key;
    if (written is YamlNode && written.value == key) {
      return (key: written, value: entry.value);
    }
  }
  return null;
}

String _source(File workflow, String name) {
  try {
    return workflow.readAsStringSync();
  } on FileSystemException catch (problem) {
    // A file that is not UTF-8 and a file this process may not open both
    // arrive here, and both are a sentence rather than a stack trace.
    throw XtaskFormatException(
      '$name: ${problem.osError?.message ?? problem.message}',
    );
  }
}

YamlNode _document(String source, String name) {
  try {
    return loadYamlNode(source);
  } on YamlException catch (e) {
    throw XtaskFormatException('$name: ${e.message}');
  }
}

/// [command] with a shell's line continuations joined.
///
/// A `\` at the end of a line means the next one is the same command, and a
/// long command line in a `run: |` block is written exactly that way. This
/// is the one thing read into a script, because without it a one-line
/// invocation wrapped for width is a two-line script.
String _joined(String command) =>
    command.replaceAll(RegExp(r'\\\r?\n[ \t]*'), ' ');

/// The reason written after [exemptionMarker] on the line [key] is written
/// on, or null when there is none.
///
/// Read out of the source, because the parse does not keep comments. The
/// marker counts only where YAML has finished reading the value: after the
/// value's span, or on the `|` line of a block scalar, where the block has not
/// begun. A marker inside a quoted string is what the step prints, not what
/// the step claims.
String? _exemptionOn(List<String> lines, YamlNode key, YamlNode value) {
  final line = key.span.start.line;
  if (line >= lines.length) {
    return null;
  }
  final text = lines[line];
  final at = text.indexOf(exemptionMarker);
  if (at == -1) {
    return null;
  }
  final offset = key.span.start.offset - key.span.start.column + at;
  final block =
      value is YamlScalar &&
      (value.style == ScalarStyle.LITERAL || value.style == ScalarStyle.FOLDED);
  final afterTheValue = offset >= value.span.end.offset;
  final onTheIndicator = block && line == value.span.start.line;
  if (!afterTheValue && !onTheIndicator) {
    return null;
  }
  return _reasonAfter(text.substring(at + exemptionMarker.length));
}

/// What somebody wrote after the marker, as the report should print it.
///
/// The dash or colon between the marker and the reason is punctuation, and the
/// report supplies its own.
String _reasonAfter(String written) =>
    written.replaceFirst(RegExp(r'^[\s—–:,-]+'), '').trim();
