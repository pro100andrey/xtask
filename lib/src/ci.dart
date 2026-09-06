/// Checking that the CI file and the gate sets still agree — §7.1's residual.
///
/// A checker rather than a generator: producing the workflow means a template
/// inside `xtask.yaml`, and §10 rules templating out. A check closes the same
/// drift by reading the workflow somebody wrote and comparing it with the gate
/// sets, in both directions.
///
/// The rule is that a `run:` step is one invocation of one gate set, and it is
/// blanket on purpose — a browser driver and a line writing `$GITHUB_ENV` do
/// belong in the workflow, and telling infrastructure from logic means
/// classifying shell. [exemptionMarker] is what the blanket rule costs.
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
  const CiStep(
    this.workflow,
    this.job,
    this.command, {
    this.exemption,
    this.exemptionIsShared = false,
    this.exemptionIsFirst = true,
  });

  /// The file it came from, relative to the repository root.
  final String workflow;

  final String job;

  /// One command line of a `run:`, trimmed, with any trailing comment off.
  ///
  /// A `run: |` block yields one step per line — GitHub writes the whole of it
  /// to a file and runs it as a script, and a line is where a command begins.
  /// That is the only thing this reads into a script: what a line MEANS is
  /// still the shell's, and a line this misreads is a line to exempt.
  final String command;

  /// The reason written beside it, when a person said this step is not a gate.
  ///
  /// Null unless the step carries [exemptionMarker].
  final String? exemption;

  /// Whether that reason was written for more than this one command.
  ///
  /// **Because "it excuses nothing" is a sentence about a marker, not about
  /// each command under one.** A marker beside `run: |` covers the script, and
  /// one at the end of a line covers the commands chained on it — so a line
  /// like `cp ./xtask /tmp/x && ./xtask check # …` has a marker that is right
  /// about its first half and necessarily idle over its second. Reported per
  /// command, the author was told their marker excused nothing, about a marker
  /// that excused the command they wrote it for.
  final bool exemptionIsShared;

  /// Whether this is the first command that reason covers.
  ///
  /// Only for saying a thing once: a marker with no reason is one mistake
  /// however many commands it stands over.
  final bool exemptionIsFirst;
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
    // Required, like the rest. Defaulted, a construction that forgets them
    // reports no exemptions at all — which is the "exempted its way to green
    // and nobody saw" state `exempted` exists to make visible.
    required this.questions,
    required this.exempted,
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

typedef StepVerdict = ({
  List<CiProblem> problems,
  String? gate,
  String? question,
  bool exempted,
});

/// Reads one step and says what it is.
///
/// Pure, and the whole of the rule: no directory, no file, no other step. A
/// [CiStep] built by hand is enough to ask it anything, which is what keeps
/// the classification testable apart from the extraction that feeds it.
///
/// A step may carry more than one finding. The marker is one fact and what it
/// stands over is another — a misspelled gate set under an exemption is both a
/// job that runs nothing and a marker that excuses nothing — and reporting one
/// instead of the other is how a silent green gets in.
StepVerdict judge(CiStep step, Set<String> declared) {
  final problems = <CiProblem>[];
  final read = _readStep(step.command, declared);
  final written = step.exemption;

  // The reason is the whole price of the marker, said once per marker however
  // many commands it covers.
  if (written != null && written.isEmpty && step.exemptionIsFirst) {
    problems.add(ExemptsWithoutSaying(step));
  }
  // An exemption IS its reason; without one there is nothing to weigh, so
  // everything below reads as though the marker were not there.
  final exemption = written == null || written.isEmpty ? null : written;

  // Said of a marker that is this command's own. One written for several
  // commands is necessarily idle over some of them, and reporting that would
  // make it unusable on the lines that need it.
  final idle = exemption != null && !step.exemptionIsShared;

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

  // The exemption is asked LAST, and only of a step that would otherwise be a
  // command. Asked first it swallows everything: a marker over `xtask check -j
  // abc` hid the command line's own refusal, and one over `xtask chekc` hid a
  // misspelled gate set. What the marker says is "this step is not a gate
  // set", which is a sentence about exactly one of the outcomes below.
  if (read.refused case final refusal?) {
    problems.add(RunsSomethingRefused(step, refusal));
    if (idle) {
      problems.add(ExemptsNothing(step, 'a step the command line refuses'));
    }
    return verdict();
  }
  if (read.gate case final gate?) {
    final undeclared = !declared.contains(gate);
    if (undeclared) {
      problems.add(RunsAnUndeclaredGate(step, gate, declared));
    }
    if (idle) {
      problems.add(ExemptsNothing(step, gate));
    }
    return verdict(gate: undeclared || idle ? null : gate);
  }
  // Both at once, because `named` is only ever set beside the mode that named
  // it — `_names` is its one producer.
  if ((read.named, read.mode) case (final named?, final mode?)) {
    problems.add(
      idle
          ? ExemptsNothing(step, named)
          : NamesAGateWithoutRunningIt(step, mode, named),
    );
    return verdict();
  }
  if (read.mode case final mode?) {
    if (idle) {
      problems.add(ExemptsNothing(step, mode));
      return verdict();
    }
    return verdict(question: mode);
  }
  if (exemption != null) {
    return verdict(exempted: true);
  }
  problems.add(RunsACommand(step));
  return verdict();
}

/// Every shell step of every workflow under [root], in a stable order.
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
    // `existsSync` above is a window: it can be true and this still fail, and
    // unguarded it ended `--check-ci` on a stack trace and exit 255.
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
        ..._shellSteps(
          workflow,
          p.posix.join(workflowDirectory, p.basename(workflow.path)),
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
/// What one step turns out to be: the findings it carries, and the one thing
/// it counts as.
CiReport checkCi(XtaskFile file, {required String root}) {
  final declared = file.gates.keys.toSet();

  final invocations = <({CiStep step, String gate})>[];
  final questions = <({CiStep step, String mode})>[];
  final exempted = <CiStep>[];
  final problems = <CiProblem>[];

  for (final step in workflowSteps(root)) {
    final verdict = judge(step, declared);
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
  // somebody marked as not a gate does not invoke xtask, and a step that asks
  // xtask a question runs no gate — so a workflow of nothing but
  // `- run: xtask --check-ci`, the step §7.1 asks every project to add, would
  // otherwise pass with its actual invocation deleted.
  if (invocations.isEmpty && problems.isEmpty) {
    throw XtaskFormatException(
      questions.isEmpty
          ? 'nothing under `$workflowDirectory` invokes xtask, so there is '
                'nothing to check this file against'
          // A different sentence, because the one above is false about a file
          // whose `--check-ci` step is on the reader's screen. What is missing
          // is a job that RUNS a gate set.
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

/// Where in [words] xtask is being **run**, or null.
///
/// Naming it is not running it: `cp ./xtask /usr/local/bin` and `chmod +x
/// ./xtask` are ordinary commands that mention the binary, which a repository
/// building its own copy writes in the same workflow.
///
/// Two answers, because position alone is not enough — naming every prefix a
/// workflow might put in front (`timeout 600`, `xvfb-run`, `cd sub &&`) is a
/// list that is never finished. A mention is the invocation when it is in
/// command position, OR when the words after it parse into a gate set THIS
/// FILE DECLARES or into a mode. Nothing writes those by accident.
///
/// Every mention on the line is tried, not just the first: `cp ./xtask /tmp/x
/// && ./xtask check` is read from the second.
///
/// A word written in quotes is data, and so is the word before it: `echo "run
/// xtask check"` is a banner, not a job that runs `check`. The price is `sh -c
/// "dart run :xtask check"`, which really is an invocation and is answered as
/// an ordinary command — telling the two apart means knowing which programs
/// take a command as an argument, which is the list this doc has already
/// refused to keep.
StepReading? _invocationIn(List<_Word> words, Set<String> declared) {
  for (var at = 0; at < words.length; at++) {
    final word = words[at];
    if (word.quoted || !_namesXtask(word.text)) {
      continue;
    }
    final after = [for (final rest in words.skip(at + 1)) rest.text];
    final before = at == 0 ? null : words[at - 1];
    if (before == null || (!before.quoted && _runsWhatFollows(before.text))) {
      return _readWords(after);
    }
    final read = _readWords(after);
    final names = read.gate ?? read.named;
    if ((names != null && declared.contains(names)) || read.mode != null) {
      return read;
    }
  }
  return null;
}

/// Whether [word] is a thing whose next argument is a command to run.
bool _runsWhatFollows(String word) => const {
  'run',
  'exec',
  'npx',
  'bunx',
  'pnpx',
  'dlx',
}.contains(word);

/// What one shell step turns out to be.
typedef StepReading = ({
  /// The gate set it runs, if it runs one.
  String? gate,

  /// Why the command line itself would turn it away.
  String? refused,

  /// The mode it asks for, if it asks a question rather than running a gate.
  String? mode,

  /// The gate set a mode names without running it.
  String? named,
});

/// A step that is not an xtask invocation at all.
///
/// **Named once.** The record was spelled out at five sites with the fields in
/// three different orders, which is how a null ends up in the wrong slot.
const StepReading _notAnInvocation = (
  gate: null,
  refused: null,
  mode: null,
  named: null,
);

StepReading _gate(String name) => (
  gate: name,
  refused: null,
  mode: null,
  named: null,
);

StepReading _refused(String why) => (
  gate: null,
  refused: why,
  mode: null,
  named: null,
);

StepReading _question(String mode) => (
  gate: null,
  refused: null,
  mode: mode,
  named: null,
);

StepReading _names(String mode, String what) => (
  gate: null,
  refused: null,
  mode: mode,
  named: what,
);

/// What shell step [command] turns out to be.
///
/// Decided by handing the words to the parser the command line uses, and
/// reading the answer's TYPE. Walking them here instead would be the command
/// line's grammar written twice, in a checker whose whole job is that one
/// thing is not written twice — and it would miss every `--mode=value`
/// spelling the parser accepts.
StepReading _readStep(String command, Set<String> declared) =>
    _invocationIn(_lex(command).words, declared) ?? _notAnInvocation;

/// What [arguments] make of themselves, read by the command line's own parser.
StepReading _readWords(List<String> arguments) {
  final request = parseArguments(
    // Their quotes are already off: they are the shell's and not the parser's,
    // and `-j "2"` is an ordinary thing to write while `2` is what the child
    // sees.
    arguments,
    // The number is discarded — only whether it PARSES is being asked — and a
    // check that read this machine's width would vouch differently for one
    // workflow on two runners.
    processors: () => 1,
  );
  return switch (request) {
    RunTask(:final task, arguments: []) => _gate(task),
    // A gate set has no body, so the arguments reach nothing and the step
    // exits 2. The command line does not refuse this — only the file can say
    // whether the name has a body — so the sentence is written here.
    RunTask() => _refused(
      'a gate set gathers tasks and runs nothing of its own, so there is '
      'nothing for the arguments after `--` to be arguments to',
    ),
    // Everything the command line itself would turn away, in its own words.
    ShowUsage(problem: final problem?) => _refused(problem),

    // **The one mode that reads as a run and is not one.** `--dry-run
    // ci-analyze`, in a job called `ci-analyze`, is the shape a step takes
    // when somebody was debugging and left the flag in — and the green tick
    // after it is the whole problem. Its siblings are not: `--gate-members`
    // and `--list` and `--why` are inspection, and a job that reports on a
    // gate set never claimed to run it.
    DryRunTask(:final task) => _names('--dry-run', task),

    // **A step that asks xtask a question is not a broken one.** This said so
    // in a comment and answered otherwise, so `- run: xtask --validate` was
    // filed under "what runs belongs in the task file" — and so was
    // `--check-ci`, the step §7.1 asks a project to add.
    ShowUsage() => _question('--help'),
    ListTasks() => _question('--list'),
    GateMembers() => _question('--gate-members'),
    WhyTask() => _question('--why'),
    Validate() => _question('--validate'),
    CheckCi() => _question('--check-ci'),
    ShowVersion() => _question('--version'),
    EmitSchema() => _question('--emit-schema'),
  };
}

Iterable<CiStep> _shellSteps(File workflow, String name) sync* {
  final document = _document(workflow, name);
  if (document is! YamlMap || document['jobs'] is! YamlMap) {
    return;
  }
  final lines = workflow.readAsStringSync().split('\n');
  for (final entry in (document['jobs'] as YamlMap).entries) {
    final job = entry.value;
    if (job is! YamlMap || job['steps'] is! YamlList) {
      continue;
    }
    // Where the previous step's `run:` block ended. A `#` line inside one is
    // shell, not a YAML comment, and belongs to the script it is written in.
    var previousEnded = -1;
    for (final step in (job['steps'] as YamlList)) {
      if (step is! YamlMap || step['run'] is! String) {
        continue;
      }
      final span = step.nodes['run']?.span;
      yield* _stepsInBlock(
        step['run'] as String,
        workflow: name,
        job: '${entry.key}',
        beside: _exemptionNear(lines, span, after: previousEnded),
      );
      previousEnded = span?.end.line ?? previousEnded;
    }
  }
}

/// [workflow] as YAML, with either way of failing to read it said in words.
///
/// A file that is not UTF-8 and a file this process may not open both arrive
/// as a `FileSystemException`, and only `YamlException` used to be caught, so
/// either ended the run at 255.
YamlNode _document(File workflow, String name) {
  try {
    return loadYamlNode(workflow.readAsStringSync());
  } on FileSystemException catch (problem) {
    throw XtaskFormatException(
      '$name: ${problem.osError?.message ?? problem.message}',
    );
  } on YamlException catch (e) {
    throw XtaskFormatException('$name: ${e.message}');
  }
}

/// The commands one `run:` block holds, each with the exemption that covers it.
///
/// GitHub writes the whole block to a file and runs it as a script, so one
/// step per command rather than per block: read as one opaque string the
/// answer depended on the order inside it, and a duplicated command hid by
/// being second.
///
/// [beside] is the marker written on the `run:` key or above the step, which
/// covers the whole script. A marker on a line covers the commands on that
/// line. Whether either covers more than one command is a fact about the whole
/// block, so the block is read before any of it is yielded.
Iterable<CiStep> _stepsInBlock(
  String block, {
  required String workflow,
  required String job,
  required String? beside,
}) sync* {
  final written = _commandLines(block);
  final read = <({String? own, List<String> commands})>[];
  var inTheBlock = 0;
  for (var at = 0; at < written.length; at++) {
    final line = written[at].trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    // The line above counts only when it is nothing but a comment — the same
    // rule the YAML comment above the block gets. Without it a marker trailing
    // one command exempts the command under it.
    final own =
        _exemptionIn(line) ??
        (at > 0 && written[at - 1].trimLeft().startsWith('#')
            ? _exemptionIn(written[at - 1])
            : null);
    final commands = _commandsOn(_withoutTrailingComment(line));
    inTheBlock += commands.length;
    read.add((own: own, commands: commands));
  }

  final under = <String>{};
  for (final line in read) {
    final exemption = line.own ?? beside;
    for (final one in line.commands) {
      yield CiStep(
        workflow,
        job,
        one,
        exemption: exemption,
        exemptionIsShared:
            exemption != null &&
            (line.own != null ? line.commands.length : inTheBlock) > 1,
        exemptionIsFirst: exemption != null && under.add(exemption),
      );
    }
  }
}

/// One word of a shell line, with its quotes off and where they were noted.
final class _Word {
  const _Word(
    this.text, {
    required this.quoted,
    required this.at,
    required this.end,
  });

  /// The word as the child would see it — quotes removed, escapes applied.
  final String text;

  /// Whether any part of it was written inside quotes.
  ///
  /// Which makes it data rather than something the step runs: `echo "run
  /// xtask check"` is a banner, and reading it as an invocation reported a
  /// gate as covered that nothing in the job runs.
  final bool quoted;

  /// Where it begins in the line, so a command can be quoted back as written.
  final int at;

  /// Where it ends, exclusive.
  final int end;
}

/// A shell line, read at the lexical level and no further.
///
/// One reading of one line, shared by the three questions this module asks of
/// it: where the invocation is, where each command begins, and where a comment
/// starts. A quote answered differently in three places is how a step comes to
/// mean one thing to one of them and another to the next.
///
/// The lexical level and nothing above it: words, quotes, escapes, operators.
/// Nothing here asks what a command MEANS — which program takes another as an
/// argument, which builtin does no work — because that is the list this module
/// has refused to keep since it started.
///
/// Redirections are recognised so they can be dropped: `2>&1` is part of the
/// command it follows, not a separator inside it.
({List<_Word> words, List<int> breaks, String? comment}) _lex(String line) {
  final words = <_Word>[];
  // Where a control operator ended a command: an index into [words].
  final breaks = <int>[];
  String? comment;

  final text = StringBuffer();
  var began = -1;
  var quoted = false;
  // The word so far is all digits and unquoted, so a `>` or `<` next takes it
  // as the file descriptor it redirects.
  var digits = true;

  // The next word belongs to a redirection rather than to the command, so it
  // is read like any other word and then dropped. Skipped with a scan of its
  // own instead, that scan was a fifth place in this module that knew what a
  // quote is — which is the shape of every defect the lexer replaced.
  var dropNext = false;

  void endWord(int at) {
    if (began != -1 && !dropNext) {
      words.add(_Word(text.toString(), at: began, end: at, quoted: quoted));
    }
    if (began != -1) {
      dropNext = false;
    }
    text.clear();
    began = -1;
    quoted = false;
    digits = true;
  }

  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == "'" || c == '"') {
      final close = line.indexOf(c, i + 1);
      final to = close == -1 ? line.length : close;
      if (began == -1) {
        began = i;
      }
      // A double-quoted string keeps `\` before the few characters a shell
      // lets it escape; anywhere else the backslash is literal.
      for (var at = i + 1; at < to; at++) {
        if (c == '"' && line[at] == r'\' && at + 1 < to) {
          at++;
        }
        text.write(line[at]);
      }
      quoted = true;
      digits = false;
      i = to;
      continue;
    }
    if (c == r'\' && i + 1 < line.length) {
      if (began == -1) {
        began = i;
      }
      text.write(line[i + 1]);
      digits = false;
      i++;
      continue;
    }
    if (c == ' ' || c == '\t') {
      endWord(i);
      continue;
    }
    if (c == '#' && began == -1) {
      // A comment opens where a word does. `red#1` is one word to a shell as
      // it is to YAML, and cutting there reported a fragment nobody wrote.
      comment = line.substring(i);
      break;
    }
    if (c == '>' || c == '<') {
      // The file descriptor in front of it belongs to the redirect too, and
      // it is what makes `2>&1` one operator rather than a `2` the command
      // was handed and an `&` that ends it.
      if (digits && began != -1) {
        text.clear();
        began = -1;
        quoted = false;
      }
      endWord(i);
      dropNext = true;
      final next = i + 1 < line.length ? line[i + 1] : '';
      i += (next == c || next == '&' || next == '|') ? 1 : 0;
      continue;
    }
    if (c == '&' || c == '|' || c == ';') {
      endWord(i);
      dropNext = false;
      if (breaks.isEmpty || breaks.last != words.length) {
        breaks.add(words.length);
      }
      final next = i + 1 < line.length ? line[i + 1] : '';
      i += (next == c && c != ';') ? 1 : 0;
      continue;
    }
    if (began == -1) {
      began = i;
    }
    text.write(c);
    if (c.codeUnitAt(0) < 0x30 || c.codeUnitAt(0) > 0x39) {
      digits = false;
    }
  }
  endWord(line.length);
  return (words: words, breaks: breaks, comment: comment);
}

/// The commands written on one line of a script.
///
/// **The same argument the newline gets, and the same shallow rule.** A block
/// is read a line at a time because a line is where a command begins; `&&`,
/// `||`, `;` and `|` are the other places one begins, and reading past them
/// made the answer depend on the order inside the line. `dart analyze &&
/// dart run :xtask check` passed green with the duplicated `dart analyze`
/// never mentioned, while the same two the other way round were refused for
/// the operands after the gate — one line, two answers, decided by which half
/// came first.
///
/// Each command comes back as the text it was written as, so a report quotes
/// the line rather than a rebuilt version of it.
///
/// A segment that only moves the shell is dropped, and [_movesTheShell] is
/// where that list is argued for.
List<String> _commandsOn(String line) {
  final read = _lex(line);
  final commands = <String>[];
  var from = 0;
  for (final to in [...read.breaks, read.words.length]) {
    if (to > from) {
      final one = line
          .substring(read.words[from].at, read.words[to - 1].end)
          .trim();
      if (one.isNotEmpty && !_movesTheShell(one)) {
        commands.add(one);
      }
    }
    from = to;
  }
  return commands;
}

/// Whether [command] only moves the shell it runs in.
///
/// **A closed list, and that is why it may exist at all.** The doc on
/// [_invocationIn] argues against naming the prefixes a workflow might put in
/// front of xtask, because any program can run another and the list is never
/// finished. This is the opposite kind of set: a shell builtin that changes
/// the shell's own state and does no work, of which there are these. Without
/// it, cutting a line into commands turned `cd sub && ./xtask ci-web` — the
/// shape this checker's own history says it must accept — into a report about
/// `cd sub` belonging in the task file.
bool _movesTheShell(String command) {
  final word = command.split(RegExp(r'\s+')).first;
  return const {'cd', 'export', 'set', 'unset', 'source', '.', ':'}.contains(
    word,
  );
}

/// [command]'s lines, with a shell's line continuations joined.
///
/// A `\` at the end of a line means the next one is the same command, and
/// splitting on the newline anyway read `dart run :xtask \` and `ci-analyze`
/// as two — reporting an undeclared gate set named `\` and telling the reader
/// their gate was unrun, about a workflow that runs it. Continuations are
/// ubiquitous in a `run:` block, because that is what a long command line
/// looks like.
List<String> _commandLines(String command) {
  final joined = <String>[];
  for (final line in command.split('\n')) {
    if (joined.isNotEmpty && joined.last.endsWith(r'\')) {
      final held = joined.removeLast();
      joined.add(
        '${held.substring(0, held.length - 1).trimRight()} '
        '${line.trim()}',
      );
      continue;
    }
    joined.add(line.trimRight());
  }
  return joined;
}

/// The reason written on [line] itself, if it carries the marker.
///
/// The block's own lines are read here rather than through a span: a block
/// scalar's indentation is stripped by the parse, so where one of its lines
/// began in the source is not recoverable — which is why actionlint reports
/// shellcheck's findings against the `run:` key rather than the line. The
/// text is enough, because the marker is in it.
String? _exemptionIn(String line) {
  if (_lex(line).comment case final comment?) {
    final marker = comment.indexOf(exemptionMarker);
    if (marker != -1) {
      return _reasonAfter(comment.substring(marker + exemptionMarker.length));
    }
  }
  return null;
}

/// [line] without a trailing `#` comment, so a marker is not read as argv.
String _withoutTrailingComment(String line) {
  final comment = _lex(line).comment;
  return comment == null
      ? line
      : line.substring(0, line.length - comment.length).trimRight();
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
String? _exemptionNear(
  List<String> lines,
  SourceSpan? span, {
  required int after,
}) {
  if (span == null) {
    return null;
  }
  // A block scalar's span starts at the `|`, and the marker belongs to the
  // line that carries the key. Both candidates are read for that reason.
  final at = span.start.line;
  for (final line in [
    if (at < lines.length) lines[at],
    // **Only when the line above is a YAML comment of its own.** Taken as
    // written, a marker trailing one step's own line was also found by the
    // step below it: `- run: npm ci # xtask: not a gate — deps` exempted the
    // `- run: dart analyze` beneath it, which is the duplicate list growing
    // back, green, under somebody else's reason.
    //
    // Starting with `#` is not enough on its own — a `#` line inside the
    // previous step's `run: |` block is shell, and belongs to that script.
    // [after] is where that block ended.
    if (at > 0 &&
        at - 1 > after &&
        at - 1 < lines.length &&
        lines[at - 1].trimLeft().startsWith('#'))
      lines[at - 1],
  ]) {
    if (_exemptionIn(line) case final reason?) {
      return reason;
    }
  }
  return null;
}

/// What somebody wrote after the marker, as the report should print it.
///
/// The dash or colon between the marker and the reason is punctuation, and the
/// report supplies its own — kept, it renders as `exempts `x` — — the reason`.
String _reasonAfter(String written) =>
    written.replaceFirst(RegExp(r'^[\s\u2014\u2013:,-]+'), '').trim();
