/// Everything the tool says to a person, in one place.
///
/// **Values in, lines out, and nothing else.** The rendering used to live
/// wherever the value was produced: the timing and the failed/skipped summary
/// inside the executor, and three of `runCli`'s `case` arms were output
/// modules living inside a label — `--check-ci` and `--why` between them held
/// forty-odd lines of prose that no named function owned. Two of those places
/// worked out a column width, separately, and were tested separately.
///
/// Nothing here does any work but arranging: no filesystem, no processes, no
/// decisions about what runs. That is what makes it testable by calling it,
/// and what makes the whitespace in a summary stop being load-bearing test
/// surface somewhere else.
library;

import 'bodies.dart';
import 'ci.dart';
import 'graph.dart';
import 'model.dart';

/// Why a task in the plan did not run.
///
/// **A value, not a string.** These four reasons used to be written into one
/// map as free text and printed through one template — `skipped $name (needs
/// $blocker)` — which is a true sentence for the first of them and a false one
/// for the rest. A task stopped because something *else* failed does not need
/// anything, and what came out was `skipped third (needs a failure
/// elsewhere)`. A reason that carries its own sentence cannot be put into the
/// wrong one.
sealed class Skipped {
  const Skipped();

  /// What the summary says after the task's name.
  String get sentence;
}

/// Something it needs failed, or was itself skipped.
final class NeedsStopped extends Skipped {
  const NeedsStopped(this.name);

  final String name;

  @override
  String get sentence => 'needs `$name`, which did not pass';
}

/// It is the continuation of a task that did not succeed.
///
/// Separate from [NeedsStopped] because `then:` is not `needs:`: a publish that
/// failed is not something the announcement *required*, it is something the
/// announcement was to follow, and saying the first would misdescribe the file.
final class FollowsStopped extends Skipped {
  const FollowsStopped(this.name);

  final String name;

  @override
  String get sentence => 'follows `$name`, which did not pass';
}

/// Something else failed and this run is not keeping going.
final class RunStopped extends Skipped {
  const RunStopped();

  @override
  String get sentence => 'the run stopped at an earlier failure';
}

/// Nothing that could have started it ever finished.
///
/// **A guard against a plan that is not in order, not a case that happens.**
/// `planRun` emits every requirement before the task that needs it, so by the
/// time the walk reaches a step its needs have all been taken off the queue —
/// this cannot fire. It exists because the alternative to noticing is
/// spinning: a walk with nothing running and nothing startable would loop
/// forever, and a hang is the one failure with nothing to read afterwards.
final class NeverStartable extends Skipped {
  const NeverStartable();

  @override
  String get sentence => 'nothing that would let it start ever finished';
}

/// Everything that failed and everything that therefore did not run.
///
/// **A skip is always reported; a lone failure is not.** They are not the same
/// case, and counting them together got it wrong: a failure has already
/// printed itself where it happened, so a heading over one of them summarises
/// nothing — but a skipped task prints nothing of its own, and this is the
/// only place it is ever mentioned. Suppressing it left a run that answered 0
/// having silently not done something, which is the failure this tool is
/// about.
List<String> summary(Map<String, int> failed, Map<String, Skipped> skipped) {
  if (skipped.isEmpty && failed.length < 2) {
    return const [];
  }
  return [
    '',
    for (final MapEntry(key: name, value: code) in failed.entries)
      'failed   $name (exit $code)',
    for (final MapEntry(key: name, value: why) in skipped.entries)
      'skipped  $name — ${why.sentence}',
  ];
}

/// What a parallel run is about to do, before it goes quiet.
///
/// **This exists because `--parallel` breaks the promise §5.2 makes.** A
/// sequential run narrates itself: the section opens, the body streams, and a
/// person watching knows both what is happening and that something is. A
/// parallel run collects each task's output and prints it whole when that task
/// ends, so the first thing a long one does is nothing at all — for as long as
/// the slowest member takes.
///
/// One line, no spinner and no carriage returns: this is read as often from a
/// CI log as from a terminal, and a log is a file. What it has to answer is
/// "is it stuck", and the answer is the count, the width, and the reason the
/// silence is expected.
List<String> starting(int tasks, int concurrency) {
  final noun = tasks == 1 ? 'task' : 'tasks';
  // Built here rather than inside the list: two string parts side by side in
  // a list literal read as a missing comma, and the lint that says so is
  // right about every other case.
  final line =
      'running $tasks $noun, up to $concurrency at once — '
      "each task's output arrives when that task ends";
  return [line, ''];
}

/// What each task took, and what the run took.
///
/// Printed after the last task and outside every section, which is the whole
/// design of it: §7.1 has a CI job run one invocation, so the job's own
/// duration is the duration of everything and "which task took four minutes"
/// has no answer anywhere else. The obvious place — beside the task — is the
/// wrong one, because a line inside a `::group::` is folded away with it, and
/// the moment somebody wants a duration is exactly the moment they have
/// expanded nothing.
List<String> timing(
  Map<String, Duration> took,
  Duration wall, {
  required bool concurrent,
}) {
  if (took.isEmpty) {
    return const [];
  }
  const total = 'total';
  // A total under one number is that number written twice, so a single task
  // gets none — and then the column must not be widened for a word that is
  // not going to be printed.
  final sums = took.length > 1;
  final numbers = [
    ...took.values.map(asTime),
    if (sums) asTime(took.values.reduce((a, b) => a + b)),
  ];
  final width = _widest([...took.keys, if (sums) total]);
  final column = _widest(numbers);
  final spent = '${total.padRight(width)}  ${numbers.last.padLeft(column)}';
  final sum = concurrent ? '$spent spent, ${asTime(wall)} taken' : spent;

  return [
    '',
    for (final (index, name) in took.keys.indexed)
      '${name.padRight(width)}  ${numbers[index].padLeft(column)}',
    // **Two numbers, and only where they differ.** Sequentially the sum of the
    // tasks IS how long the run took. Run together they are different
    // questions — how much work there was, and how long you waited — and
    // printing only the first would report three minutes for a run that took
    // one.
    if (sums) sum,
  ];
}

/// A duration a person reads, not one a machine parses.
String asTime(Duration took) {
  if (took.inMinutes < 1) {
    return '${(took.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final seconds = (took.inSeconds % 60).toString().padLeft(2, '0');
  return '${took.inMinutes}m ${seconds}s';
}

/// `--list`: every task with what it is for, in one column.
List<String> listing(Iterable<Task> tasks) {
  final width = _widest(tasks.map((task) => task.name));
  return [
    for (final task in tasks) '${task.name.padRight(width)}  ${task.desc}',
  ];
}

/// `--list` over a whole file: the tasks grouped under the gate sets that run
/// them, in the order the file declares.
///
/// **The reason gate sets are declared rather than inferred.** A gate that
/// existed by being mentioned had no order of its own and no complete list, so
/// this could only ever print one flat column — and "which of these does CI
/// run" was a question a reader answered by scanning every task's `gate:` key
/// and assembling the answer themselves.
///
/// A task in two sets appears under both, which is what it is. The last group
/// is the one that could not be named before: `ungated` is complete only
/// because the declaration says what all the gates are, so a task under it is
/// one nothing runs rather than one this report did not think of.
List<String> grouping(XtaskFile file) {
  if (file.gates.isEmpty) {
    // Nothing to group by. A single heading over the whole file would be a
    // grouping the file does not have.
    return listing(file.tasks.values);
  }

  final width = _widest(file.tasks.keys);
  String row(Task task) => '  ${task.name.padRight(width)}  ${task.desc}';

  final groups = <List<String>>[
    for (final gate in file.gates.keys)
      [
        'gate $gate',
        for (final task in file.tasks.values)
          if (task.gate.contains(gate)) row(task),
      ],
    [
      'ungated',
      // **Every task no DECLARED gate set runs**, not only the ones that
      // claim no gate. A task whose `gate:` is misspelled belongs to no
      // declared set, and matching neither bucket made it vanish from the
      // listing entirely — one transposed letter turning this report into a
      // lie by omission, which is the failure grouping was added to prevent.
      // `--validate` is what names the misspelling; this only has to be
      // complete.
      for (final task in file.tasks.values)
        if (!task.gate.any(file.gates.containsKey)) row(task),
    ],
  ]..removeWhere((group) => group.length == 1);

  return [
    for (final (at, group) in groups.indexed) ...[
      if (at > 0) '',
      ...group,
    ],
  ];
}

/// `--why`: every entry point that reaches [task], and the route to it.
///
/// A route that is empty means the entry point IS the task. A [routes] with no
/// entries means nothing reaches it — not an error, and the answer worth
/// having: a task no run includes looks from the outside exactly like one that
/// is checked.
List<String> why(String task, Map<String, List<PlanEdge>> routes) {
  if (routes.isEmpty) {
    return ['nothing reaches `$task` — no run includes it'];
  }
  return [
    for (final MapEntry(key: entry, value: route) in routes.entries) ...[
      entry,
      if (route.isEmpty)
        '  nothing else names it: `$task` is where a run starts',
      for (final edge in route) '  $edge',
    ],
  ];
}

/// `--check-ci`: what each job runs, and which gate sets nothing runs.
///
/// The unrun list is reported and **not judged**: a gate set is named after
/// who runs it, and §7.1 says that is the jobs plus the human entry points.
/// Nothing in the file tells those apart, and a key that claimed to would be a
/// second place saying what the workflow already says.
List<String> workflow(CiReport report) {
  final unrun = report.unrun.map((gate) => '`$gate`').join(', ');
  final nobody =
      'no job runs: $unrun — right if somebody runs them by hand, wrong if a '
      'job was forgotten, and xtask cannot tell those apart';
  return [
    for (final invocation in report.invocations)
      _ran(invocation.step.workflow, invocation.step.job, invocation.gate),
    if (report.ok && report.unrun.isNotEmpty) ...['', nobody],
  ];
}

String _ran(String workflow, String job, String gate) =>
    '$workflow: job `$job` runs the gate set `$gate`';

/// `--validate`, when there is nothing to say.
///
/// Not silence. Silence is what a gate that never ran also prints, and naming
/// the file proves it read the one somebody meant.
String read(String path, int tasks, int gates, int sets) => [
  '$path: ${_count(tasks, 'task')}',
  // Named only when there are any: a file with no gate sets is a legitimate
  // file, and "0 gate sets" reads as something missing.
  if (gates > 0) _count(gates, 'gate set'),
  _count(sets, 'set'),
  'nothing wrong',
].join(', ');

int _widest(Iterable<String> of) =>
    of.fold(0, (widest, s) => s.length > widest ? s.length : widest);

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// How a [Resolved] body is written down: what runs, where, and with what.
///
/// Two callers need it: `--dry-run` prints it, and a failure prints it so that
/// the line saying a task failed is also the line that reproduces it. Two
/// renderings of one value would drift, and the drift would show up as a dry
/// run promising a command a failure then reports differently.
///
/// [header] is the task's name over the block. A failure has already said which
/// task this is, so it asks for the block without one — which the failing side
/// used to do by dropping the first line of the answer, with the reason
/// recorded in a test comment rather than here.
///
/// §13 keeps output *formats* out of this milestone — there is no `--json` and
/// no key to choose one. This is the one human-readable form, and the thing it
/// has to get right is that a person can check it against what they meant.
List<String> describe(Resolved body, {bool header = true}) {
  final member = body.member;
  return [
    if (header)
      if (member == null) body.task.name else '${body.task.name}  [$member]',
    switch (body) {
      ResolvedProcess(:final executable, :final arguments) =>
        '  run  ${_command(executable, arguments)}',
      // The name written in the file, not the Dart function it found: a verb
      // is the project's, and `Closure: (VerbContext) => Future<int>` tells
      // the reader nothing they can check.
      ResolvedVerb(:final verb, :final arguments) =>
        '  do   ${_command(verb, arguments)}',
    },
    '  in   ${body.workingDirectory}',
    // **The task's own `env:`, not the environment the body will see.** The
    // second is this machine's environment with two entries changed, and
    // printing it would bury the two lines that are part of the plan under a
    // hundred that are part of the terminal. What `env-required` asked for is
    // not printed either: by the time a body resolves, it is set.
    for (final variable in body.declaredEnvironment.entries)
      '  env  ${variable.key}=${_quoted(variable.value)}',
    if (body case ResolvedProcess(timeout: final limit?))
      '  for  at most ${limit.inSeconds}s, then it is killed',
    if (body case ResolvedProcess(runInShell: true))
      '  via  cmd.exe, which is the only way to start a batch file',
  ];
}

String _command(String head, List<String> arguments) =>
    [head, ...arguments].map(_quoted).join(' ');

/// [word] written so that its edges are visible.
///
/// A plan that cannot tell one argument from two is not one anybody can check
/// against what they meant: `dart test a b` and `dart test 'a b'` are
/// different commands, and an argument that is the empty string disappears
/// entirely. This is for **reading** — xtask starts no shell (§5.4), so there
/// is no shell for it to be correct for, and it does not claim to be.
String _quoted(String word) => word.isEmpty || _needsQuotes.hasMatch(word)
    ? "'${word.replaceAll("'", r"\'")}'"
    : word;

final _needsQuotes = RegExp(r'''[\s'"]''');
