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

  // **Sorted, because `listSync` answers in the filesystem's order.** Two
  // workflows with findings printed in one order on one machine and the other
  // on the next, so any diff or golden of `--check-ci` was unstable for a
  // reason nothing in the repository explains. `sets.dart` sorts its own walk
  // and says why: a walk that descends in that order is a walk whose failure
  // messages arrive in it too.
  final files = present.whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final steps = <CiStep>[];
  for (final workflow in files) {
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
    final read = _readStep(step.command, declared);
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
      // Said as well, not instead. The refusal is the finding; that a marker
      // was written over it and excused nothing is a second fact, and the
      // reader who wrote the marker is the one who needs to hear it.
      if (exemption != null) {
        problems.add(ExemptsNothing(step, 'a step the command line refuses'));
      }
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

  // **Only a run or a finding counts as something to check against.** Neither
  // an exemption nor a question is: a step somebody marked as not a gate does
  // not invoke xtask, and a step that asks xtask a question runs no gate — so
  // a workflow of nothing but `- run: xtask --check-ci`, which is the step
  // §7.1 asks every project to add, would pass with its actual invocation
  // deleted. That is precisely what this throw exists to prevent.
  if (invocations.isEmpty && problems.isEmpty) {
    throw XtaskFormatException(
      questions.isEmpty
          ? 'nothing under `$workflowDirectory` invokes xtask, so there is '
                'nothing to check this file against'
          // False as the sentence above, about a file whose `--check-ci` step
          // is on the reader's screen: it sent them looking for an invocation
          // they can see. What is missing is a job that RUNS a gate set.
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
/// **Naming it is not running it.** Any word matching was taken as the
/// invocation, so `chmod +x ./xtask`, `cp ./xtask /usr/local/bin` and `dart
/// compile exe bin/xtask.dart -o xtask` were each read as an xtask command
/// line and reported for whatever `parseArguments` made of the words after —
/// `cp` was told it ran a gate set called `/usr/local/bin`. Those steps are
/// ordinary commands that happen to mention the binary, which a repository
/// building its own copy of it does in the same workflow.
///
/// **But position alone was the wrong depth.** Requiring word zero or one of a
/// handful of runner names turned down `cd sub && ./xtask ci-web`, `timeout
/// 600 ./xtask ci-web`, `xvfb-run ./xtask ci-web` and even `dart
/// bin/xtask.dart ci-web` — a spelling [_namesXtask]'s own doc promises to
/// accept — and told each of them to move a gate set that is already in the
/// task file. Naming every prefix a workflow might use is a list that is never
/// finished.
///
/// So position is one of two answers, and what the words say is the other: a
/// step whose remaining words parse into a gate set THIS FILE DECLARES, or
/// into a mode, is running xtask wherever the word sits. Nothing else can make
/// those words by accident, and a mention as an operand — `/usr/local/bin`,
/// `first"` — names no gate this file has, so it falls back to position and is
/// the ordinary command it looks like.
int? _runsXtask(List<String> words, Set<String> declared) {
  int? mentioned;
  for (var at = 0; at < words.length; at++) {
    if (!_namesXtask(words[at])) {
      continue;
    }
    if (at == 0 || _runsWhatFollows(words[at - 1])) {
      return at;
    }
    mentioned ??= at;
  }
  if (mentioned == null) {
    return null;
  }
  final read = _readWords(words.skip(mentioned + 1));
  final names = read.gate ?? read.named;
  return (names != null && declared.contains(names)) || read.mode != null
      ? mentioned
      : null;
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

/// [word] without the quotes a shell would take off it.
String _unquoted(String word) => word.replaceAll('"', '').replaceAll("'", '');

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
/// **Decided by parsing it, not by reading it a second way.** This used to walk
/// the words itself — attached values against separate ones, `--jobs=` against
/// `-j4`, a lone `-`, a second operand — which is the command line's grammar
/// written twice, in a checker whose whole job is that one thing is not written
/// twice. Both copies had already been wrong: `-j4` swallowed the gate set
/// after it, and a lone `-` raised a `RangeError` out of `--check-ci`.
///
/// So the words go to the parser the command line uses, and the answer's TYPE
/// is what says which of the four outcomes this is. Reading the mode back off
/// the words instead missed every `--mode=value` spelling the parser accepts —
/// `--why=check` reported a gate set named under an empty flag — and had
/// nothing to say about `--help`, which is not in `modes`.
StepReading _readStep(String command, Set<String> declared) {
  final words = command.split(RegExp(r'\s+'));
  final at = _runsXtask(words, declared);
  if (at == null) {
    return _notAnInvocation;
  }
  return _readWords(words.skip(at + 1));
}

/// What [arguments] make of themselves, read by the command line's own parser.
StepReading _readWords(Iterable<String> arguments) {
  final request = parseArguments(
    // Quotes come off, because they are the shell's and not the parser's:
    // `-j "2"` is an ordinary thing to write and `2` is what the child sees.
    arguments.map(_unquoted).toList(),
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
    // Where the previous step's `run:` block ended. A `#` line inside one is
    // shell, not a YAML comment, and belongs to the script it is written in.
    var previousEnded = -1;
    for (final step in steps) {
      if (step is! YamlMap) {
        continue;
      }
      if (step['run'] case final String command) {
        final span = step.nodes['run']?.span;
        // **One step per line of the block.** GitHub writes the whole `run:`
        // to a file and runs it as a script, and taking it as one opaque
        // string made the answer depend on the order inside it: `echo start`
        // then the gate was refused, the gate then `dart analyze` passed —
        // the same duplicated command, hidden by being second. A line is
        // where a command begins, which is the only thing this needs to know
        // about a script, and a line it misreads is a line somebody exempts.
        final written = _commandLines(command);
        for (var at = 0; at < written.length; at++) {
          final line = written[at].trim();
          if (line.isEmpty || line.startsWith('#')) {
            continue;
          }
          yield CiStep(
            name,
            '${entry.key}',
            _withoutTrailingComment(line),
            exemption:
                _exemptionIn(line) ??
                // The line above counts only when it is nothing but a
                // comment — the same rule the YAML comment above the block
                // gets. Without it, a marker trailing one command exempted
                // the command under it, which is the leak this rule was
                // written for arriving one level in.
                (at > 0
                    ? (written[at - 1].trimLeft().startsWith('#')
                          ? _exemptionIn(written[at - 1])
                          : null)
                    : _exemptionNear(lines, span, after: previousEnded)),
          );
        }
        previousEnded = span?.end.line ?? previousEnded;
      }
    }
  }
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
  if (_commentOpensAt(line) case final opens?) {
    final comment = line.substring(opens);
    final marker = comment.indexOf(exemptionMarker);
    if (marker != -1) {
      return _reasonAfter(comment.substring(marker + exemptionMarker.length));
    }
  }
  return null;
}

/// Where a `#` comment opens on [line], or null if none does.
///
/// **One reading of one `#`, because two of them disagreed.** The exemption
/// was looked for with `indexOf` over the whole line while the argv beside it
/// was cut by a scan that tracked quotes, so the same `#` on the same line was
/// a comment to one and text to the other — and the disagreement resolved in
/// the direction that turns a finding into a pass: `run: echo '# xtask: not a
/// gate - pretend'` exempted the step that was printing it. [ExemptsNothing]
/// and [ExemptsWithoutSaying] are both about a marker that does not mean what
/// it looks like; this was the third way, and it looked like a green job.
///
/// **Not the first `#`, and not one inside quotes.** Cut blindly, `echo "a #
/// b"` was reported as `echo "a` — a fragment nobody wrote — and `xtask
/// check -- --tag "#fast"` became `xtask check -- --tag "`, which parses as
/// a gate set handed arguments and was refused for it. A comment opens where
/// the line does or after whitespace, which is the rule a shell and YAML both
/// use: `red#1` is one word to either of them.
int? _commentOpensAt(String line) {
  var single = false;
  var double = false;
  for (var i = 0; i < line.length; i++) {
    switch (line[i]) {
      case "'":
        if (!double) {
          single = !single;
        }
      case '"':
        if (!single) {
          double = !double;
        }
      case '#':
        final opens = i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t';
        if (!single && !double && opens) {
          return i;
        }
    }
  }
  return null;
}

/// [line] without a trailing `#` comment, so a marker is not read as argv.
String _withoutTrailingComment(String line) => switch (_commentOpensAt(line)) {
  final opens? => line.substring(0, opens).trimRight(),
  null => line,
};

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
