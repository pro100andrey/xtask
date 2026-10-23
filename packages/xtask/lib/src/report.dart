/// Everything the tool says to a person, in one place.
///
/// Values in, lines out, and nothing else: no filesystem, no processes, no
/// decisions about what runs. Everything the tool prints is arranged here, so
/// it is testable by calling it and the whitespace in a summary is not
/// load-bearing test surface somewhere else.
library;

import 'bodies.dart';
import 'ci.dart';
import 'gates.dart';
import 'graph.dart';
import 'model.dart';
import 'request.dart';

/// Why a task in the plan did not run.
///
/// **A value, not a string.** One template — `skipped $name (needs $blocker)`
/// — is a true sentence for one of these reasons and a false one for the
/// rest: a task stopped because something *else* failed does not need
/// anything. A reason that carries its own sentence cannot be put into the
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

/// It began, and the run gave up before all of its members had.
///
/// A member that has not started is what has not started, so a failure
/// elsewhere stops it — and the task then reads, from its own section, as
/// though every member ran. This is the line that says otherwise.
final class PartlyRun extends Skipped {
  const PartlyRun({required this.attempted, required this.members});

  final int attempted;
  final int members;

  @override
  String get sentence =>
      'stopped after $attempted of $members members, at an earlier failure';
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

/// It was running when an earlier failure answered the run, and it was
/// `interruptible:`, so it was stopped part-way.
///
/// The task's own section already says it was stopped; its row in the
/// summary says it again, because the row is also the task's time, and a
/// tree missing one task reads as a run that did not have it. A program
/// reading the report has only this.
final class Interrupted extends Skipped {
  const Interrupted();

  @override
  String get sentence =>
      'stopped part-way: an earlier failure had already answered the run';
}

/// The process received a signal, and the run stopped there: before this task
/// began, or part-way through it.
///
/// Apart from [RunStopped], [PartlyRun] and [Interrupted], whose sentences
/// all say "an earlier failure": a run stopped by a Ctrl-C may have had no
/// failure at all, and a reader told to look for one looks for something that
/// is not there.
final class Signalled extends Skipped {
  const Signalled(this.signal, {required this.began});

  /// The signal's name — `SIGINT`.
  final String signal;

  /// Whether the task had begun.
  final bool began;

  @override
  String get sentence => began
      ? 'stopped part-way: the run received $signal'
      : 'the run received $signal before it began';
}

/// The run has not got to its end — what a report written during the run
/// says of a task, and what it still says when the run is cut off there.
///
/// Never in the summary, which is written once the run has ended and so
/// never meets a task that has not.
final class CutOff extends Skipped {
  const CutOff({required this.began});

  /// Whether the task was running, rather than not yet begun.
  final bool began;

  @override
  String get sentence => began
      ? 'the run ended while it was running'
      : 'the run ended before it began';
}

/// It is for other operating systems than this one — its `platforms:`.
///
/// **The one reason that is not about something going wrong.** Every other
/// [Skipped] says the run did not get to the task; this one says the file
/// decided it has no business here, which is why what needs it, or follows it
/// by `then:`, goes on as though it had passed (see `admits`). Reported all
/// the same, in the summary and the report: a task that did not run on this
/// machine and said nothing would read as one that did.
final class OffPlatform extends Skipped {
  const OffPlatform(this.platforms);

  /// The task's `platforms:`, as written.
  final List<OperatingSystem> platforms;

  /// `linux only`, `linux and macos only`: what the task is for, which is the
  /// part a reader acts on — the machine they are on, they know.
  @override
  String get sentence => '${platforms.map((os) => os.name).join(' and ')} only';
}

/// Which [Result] a task that did not run to its end is reported as.
///
/// Written out case by case, so that the next reason a task does not run is
/// a decision about which of the two it is rather than a default.
Result resultOf(Skipped why) => switch (why) {
  NeedsStopped() || FollowsStopped() || OffPlatform() => Result.skipped,
  RunStopped() ||
  PartlyRun() ||
  NeverStartable() ||
  Interrupted() ||
  Signalled() ||
  CutOff() => Result.notRun,
};

/// What the run came to: one row per task in plan order — its status, how
/// long it took, and why where it did not pass — with the members of an
/// `each:` under it and the total last.
///
/// **Printed after the last task and outside every section**, which is the
/// whole design of it: a CI job runs one invocation, so the job's own
/// duration is the duration of everything and "which task took four minutes"
/// has no answer anywhere else. Beside the task is the wrong place, because a
/// line inside a `::group::` is folded away with it, and the moment somebody
/// wants a duration is exactly the moment they have expanded nothing. Last,
/// too, because it is the part somebody has to act on and the terminal
/// scrolls.
///
/// **Rendered from [Ended], what `--report` writes, and nothing else.** The
/// status a row shows is the report's [Result]; a second reckoning of which
/// tasks failed, here, is a summary that can disagree with the report about
/// the same run.
///
/// **Every task, a lone failure too.** It used to be left out — it had
/// printed itself where it happened — but that was a rule about a heading
/// over a list of failures. A row is also the task's time, printed for it
/// anyway, and a tree with every task but the red one in it reads as a run
/// with nothing red. A skipped task is the reason the rows exist at all: it
/// prints nothing of its own, and this is the only place it is ever named.
///
/// [narrowed] is what `--only` left of each narrowed task's set, which no
/// [Ended] carries; [concurrent] is whether two units could have run at once.
List<String> summary(
  RunSoFar run, {
  required bool concurrent,
  Map<String, ({int kept, int of})> narrowed = const {},
}) {
  if (run.tasks.isEmpty) {
    return const [];
  }

  /// The members [ended] has a row for each of — none where there is one,
  /// which is the task said twice.
  List<Ended> listed(Ended ended) =>
      ended.members.length > 1 ? ended.members : const [];

  /// The members that began: each of those has a time, and only those.
  Iterable<Ended> began(Ended ended) =>
      listed(ended).where((member) => member.took != null);

  /// How much work [ended] was, which is not how long it took when its
  /// members ran together.
  ///
  /// A fanned-out task's row is how long you waited: four members of a second
  /// each at `-j 4` is a one-second row and four seconds of work. Summing the
  /// rows would report a run that gained nothing from `-j`. Where fewer than
  /// two members began, the row IS the work.
  Duration workOf(Ended ended) {
    final timed = began(ended);
    return timed.length < 2
        ? ended.took!
        : timed.map((member) => member.took!).reduce((a, b) => a + b);
  }

  /// What a fanned-out task's members added up to, and how much of its set
  /// that was.
  ///
  /// **The work only where the members could run together.** Over forty
  /// packages at four at a time, how much work there was is the half of the
  /// answer the row does not give, and without it a run that halved its wall
  /// clock looks exactly like one that had less to do. One after another the
  /// work is the row, give or take the gaps, and `0.8s  0.8s over 2 members`
  /// was one number printed twice.
  ///
  /// **How much of the set, wherever `--only` narrowed it**: two packages of
  /// seventeen is not the gate, and a summary reading as though it were is
  /// the green nobody checked.
  String note(Ended ended) {
    final part = narrowed[ended.name];
    final of = part == null ? '' : ' of ${part.of}';
    final timed = began(ended).length;
    if (concurrent && timed > 1) {
      return '${asTime(workOf(ended))} over $timed$of members';
    }
    // How many RAN, where that is known: `--only` keeping five and the first
    // failing is one of seventeen, not five. Without `each:` the kept members
    // went to one invocation, and all of them reached it.
    return part == null ? '' : '${timed > 0 ? timed : part.kept}$of members';
  }

  /// Why [ended] did not pass, as its row says it: the code it failed with,
  /// or the sentence for why it did not run.
  ///
  /// A task's code is left to the member that failed with it, where that
  /// member has a row of its own: one red member under a red task is one
  /// failure, and two `exit 1`s read as two.
  String reason(Ended ended) => switch (ended.result) {
    Result.passed => '',
    Result.failed when listed(ended).any((m) => m.result == Result.failed) =>
      '',
    Result.failed => 'exit ${ended.code}',
    Result.skipped || Result.notRun => ended.why ?? '',
  };

  final rows = <({String label, String? time, String detail})>[];
  void add(Ended ended, {required String indent, String note = ''}) {
    rows.add((
      label: '$indent${_mark(ended)} ${ended.name}',
      time: ended.took == null ? null : asTime(ended.took!),
      detail: [note, reason(ended)].where((s) => s.isNotEmpty).join('  '),
    ));
  }

  for (final ended in run.tasks) {
    add(ended, indent: '', note: note(ended));
    for (final member in listed(ended)) {
      add(member, indent: '  ');
    }
  }

  final timed = [
    for (final ended in run.tasks)
      if (ended.took != null) ended,
  ];
  // A total under one number is that number written twice, so a run with
  // one timed task gets none.
  if (timed.length > 1) {
    rows.add((
      label: '  total',
      time: asTime(timed.map(workOf).reduce((a, b) => a + b)),
      detail: '',
    ));
  }

  // One column for every name, the members' and the total's with them, so
  // each time sits under the one above it whatever depth it is at.
  final width = _widest(rows.map((row) => row.label));
  final column = _widest(rows.map((row) => row.time ?? ''));
  // **Two numbers, and only where they differ**, after the total's own.
  // Sequentially the sum of the tasks IS how long the run took. Run together
  // they are different questions — how much work there was, and how long you
  // waited — and printing only the first would report three minutes for a
  // run that took one. Only ever on the last row, which is then the total.
  final sum = timed.length > 1 && concurrent
      ? ' spent, ${asTime(run.took)} taken'
      : '';
  return [
    '',
    for (final (at, row) in rows.indexed)
      [
        row.label.padRight(width),
        // No column at all where nothing has a time — a run of tasks that
        // are all for other platforms — rather than a gap with nothing in it.
        if (column > 0) '  ${(row.time ?? '').padLeft(column)}',
        if (at == rows.length - 1) sum,
        if (row.detail.isNotEmpty) '  ${row.detail}',
      ].join().trimRight(),
  ];
}

/// The mark a row begins with: the report's [Result], and for `not-run`
/// whether it began.
///
/// **Two marks for one result, from what the result already carries.** A
/// task that began and was stopped has a time and may have left work half
/// done; one never begun has neither, and the two are read differently by
/// whoever looks for what to rerun. Whether it began is whether it has a
/// time — nothing new is reckoned to tell them apart.
String _mark(Ended ended) => switch (ended.result) {
  Result.passed => '✓',
  Result.failed => '✗',
  Result.skipped => '⊘',
  Result.notRun => ended.took == null ? '·' : '⏹',
};

// ── --report ────────────────────────────────────────────────────────────────

/// The shape `--report` writes, counted: a reader that knows version 1 knows
/// every field a version 1 report can have.
///
/// **Raised when a field changes meaning or goes away, not when one is
/// added.** A reader is told to pass over a field it does not know, so a new
/// one breaks nobody; a `result` that came to mean something else would
/// break every reader quietly, which is what the number is for.
const reportVersion = 1;

/// What became of one task, or one member of an `each:`.
///
/// **Four, because a reader acts on four.** Passed and failed are the run's
/// verdict; the other two are both "did not run" and are told apart because
/// they are fixed in different places: a task skipped is waiting on one that
/// failed, and fixing that one runs it — or is for another platform, which
/// nothing on this machine fixes, and its `why` says which — while a task not
/// run was stopped by the run ending — a failure elsewhere, or the run cut
/// off — and says nothing about anything it needs.
enum Result {
  /// It ran to its end and passed.
  passed('passed'),

  /// It ran and failed — its body, its `unchanged:` set, or a refusal at its
  /// start such as a missing tool.
  failed('failed'),

  /// It never started: what it needs, or the task whose `then:` it follows,
  /// did not pass — or its `platforms:` do not include this machine.
  skipped('skipped'),

  /// It did not run, or did not run to its end, because the run stopped first.
  notRun('not-run');

  const Result(this.written);

  /// How the report writes it. `not-run` rather than the Dart name, because
  /// the report is read by programs in other languages, and by people.
  final String written;
}

/// One task, or one member of an `each:`, as the report says it ended.
final class Ended {
  const Ended(
    this.name,
    this.result, {
    this.took,
    this.code,
    this.why,
    this.members = const [],
  });

  /// The task's name, or the member's.
  final String name;

  final Result result;

  /// How long it ran. Null where it never started — and for a member where
  /// it was the only one, whose time is its task's.
  final Duration? took;

  /// The code it failed with, from the exit code table: a `run:` body that
  /// failed is 1 whatever its program exited with, which [why] says, and a
  /// continuation is its own failure's code although the run answers 4.
  final int? code;

  /// What the run said about it, where it did not pass: the failure as it was
  /// printed, or why it did not run.
  final String? why;

  /// For an `each:` task, every member in the set's order.
  final List<Ended> members;
}

/// What a run has come to so far: each task of its plan in order, and how
/// long it has been going.
typedef RunSoFar = ({List<Ended> tasks, Duration took});

/// The report `--report` writes for a run of [task], as JSON values.
///
/// [code] is what the run answered, and null while it has not: a report
/// written during the run says it is not complete, so that one left behind
/// by a run that was cut off cannot be read as a run that ended. [refusal]
/// is what refused the run when it never began, which is when [run] is null.
///
/// Fields are left out where they have nothing to say rather than written as
/// null, the way a reader in any language finds easiest to ask about them.
Map<String, Object?> runReport(
  String task,
  RunSoFar? run, {
  int? code,
  String? refusal,
}) {
  Map<String, Object?> row(String key, Ended ended) => {
    key: ended.name,
    'result': ended.result.written,
    'seconds': ?_seconds(ended.took),
    'code': ?ended.code,
    'why': ?ended.why,
    if (ended.members.isNotEmpty)
      'members': [for (final member in ended.members) row('member', member)],
  };
  return {
    'version': reportVersion,
    'task': task,
    'complete': code != null,
    'code': ?code,
    'seconds': ?_seconds(run?.took),
    'why': ?refusal,
    'tasks': [
      for (final ended in run?.tasks ?? const <Ended>[]) row('task', ended),
    ],
  };
}

/// Seconds, to the millisecond: what a program compares, where [asTime] is
/// what a person reads.
double? _seconds(Duration? took) =>
    took == null ? null : took.inMilliseconds / 1000;

/// What a run says the moment it receives [signal]: that it is stopping,
/// and why it has not stopped yet.
///
/// **Said at once, because the run does not end at once.** Each process is
/// asked to stop and given a moment to write what it has before it is made
/// to, and a verb is Dart nothing outside it can stop — so the run can go on
/// for seconds after a Ctrl-C, and silence through them reads as a Ctrl-C
/// that did nothing.
String stopping(String signal) =>
    'xtask: received $signal — stopping what is running and starting nothing '
    'more';

/// What a parallel run is about to do, before it goes quiet.
///
/// A parallel run collects each task's output and prints it whole when that
/// task ends, so the first thing a long one does is nothing at all. This says
/// the silence is expected.
///
/// One line, no spinner and no carriage returns: it is read as often from a CI
/// log as from a terminal, and a log is a file. What it has to answer is "is
/// it stuck", and the answer is the count and the width.
List<String> starting(int tasks, int concurrency) {
  // Built here rather than inside the list: two string parts side by side in
  // a list literal read as a missing comma, and the lint that says so is
  // right about every other case.
  //
  // **One task is not one thing to wait for.** A fanned-out task is as many
  // as it has members, and "running 1 task" beside a four-way budget reads as
  // an announcement about nothing, followed by a silence with no reason given.
  final line = tasks == 1
      ? 'running up to $concurrency at once — output arrives as each ends'
      : 'running $tasks tasks, up to $concurrency at once — '
            "each task's output arrives when that task ends";
  return [line, ''];
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
/// A task in two sets appears under both, which is what it is. `ungated` is
/// complete only because the declaration says what all the gates are, so a
/// task under it is one nothing runs rather than one this report did not think
/// of — which is what a gate set existing by being mentioned could not
/// promise.
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

/// What an `each:` task fans out over, as `--graph` draws it.
///
/// **Handed in, not found here.** A glob set's members are on disk and this
/// module reads nothing; the command line expands the set the way a run
/// would and says what it came to.
sealed class Fan {
  const Fan();
}

/// The members the set has now.
final class Members extends Fan {
  const Members(this.members);

  final List<String> members;
}

/// A `produced-by:` set that is empty because its task has not run.
///
/// **Not yet is not the same as none**, which is `--dry-run`'s rule and in
/// its words: a set another task makes is empty before that task runs, and a
/// picture that said "×0" would draw a working file as a broken one.
final class MembersNotYet extends Fan {
  const MembersNotYet(this.producer);

  /// The task its `produced-by:` names.
  final String producer;
}

/// How many members of an `each:` the tree names before it counts the rest.
///
/// **Three, and never "and 1 more".** The members share one line with the
/// task, so a set of forty is a count and not a list; three is enough to
/// see what kind of thing the set holds. A fourth is named rather than
/// counted, because "and 1 more" is no shorter than the name it stands for.
const graphMembersNamed = 3;

/// `--graph`: what [name] pulls in, drawn as a tree — its `needs:`, then
/// its `then:`, each under the task that names it, all the way down.
///
/// The opposite direction from [why], which starts at a task and looks up
/// for whoever pulls it in. This starts where a person types and looks down,
/// so the two answer "why is this here" and "what does this bring".
///
/// [name] is a gate set or a task the command line has already planned, so
/// a name nothing answers to never reaches this. Null draws every gate set
/// in the order `gates:` declares, then the tasks none of them reaches,
/// grouped as `--list` groups them.
///
/// **A task is drawn once**, and every later edge to it says `(see above)`
/// — cargo tree's `(*)` — because a shared need drawn again under each
/// task that needs it is a tree that grows with the square of the file and
/// reads as two runs of one task. The run, too, reaches it once. Across the
/// trees of one answer as well, since they are printed together.
///
/// `then:` is its own word and never a `needs`: one runs before and the
/// other after, which is the distinction `--why` keeps for the same reason.
///
/// A task for another OS than [host] is marked `⊘` with its `platforms:`,
/// the summary's mark and sentence for it; its set is not expanded, since
/// the run would not expand it here. Every other `each:` task is asked
/// [fanOf] for its members.
List<String> graph(
  XtaskFile file, {
  required OperatingSystem host,
  required Fan Function(Task task) fanOf,
  String? name,
}) {
  final drawn = <String>{};

  /// [at] and everything below it, onto [rows]. [lead] begins its own line
  /// and [under] the lines of what it names.
  void draw(
    List<({String label, String detail})> rows,
    String at, {
    required String lead,
    required String under,
    String edge = '',
  }) {
    // `then  announce` lines up with `needs build`: the edge is a column of
    // its own, so the names under one task start at one place.
    final label = '$lead${edge.isEmpty ? '' : '${edge.padRight(5)} '}$at';
    final task = file.tasks[at];
    if (task == null) {
      // A dangling name is `--validate`'s to report, and a named graph has
      // been planned first, so only the picture of a whole broken file
      // meets one. Drawn, because leaving it out draws a file that is fine.
      rows.add((label: label, detail: 'there is no such task'));
      return;
    }
    if (!drawn.add(at)) {
      rows.add((label: label, detail: '(see above)'));
      return;
    }
    final (count, detail) = !task.isFor(host)
        ? ('', '⊘ ${OffPlatform(task.platforms).sentence}')
        : task.each == null
        ? ('', '')
        : switch (fanOf(task)) {
            Members(:final members) => (
              ' ×${members.length}',
              _named(members),
            ),
            MembersNotYet(:final producer) => (
              '',
              'cannot be resolved yet — task `$producer` makes its members',
            ),
          };
    rows.add((label: '$label$count', detail: detail));
    final edges = [
      for (final need in task.needs) ('needs', need),
      for (final next in task.then) ('then', next),
    ];
    for (final (index, (kind, next)) in edges.indexed) {
      final last = index == edges.length - 1;
      draw(
        rows,
        next,
        lead: '$under${last ? '└─ ' : '├─ '}',
        under: '$under${last ? '   ' : '│  '}',
        edge: kind,
      );
    }
  }

  /// A tree whose first line is [heading] rather than a task, with
  /// [roots] under it and no edge word: a gate set runs its members, and
  /// nothing about that is a `needs:` or a `then:`.
  List<({String label, String detail})> grouped(
    String heading,
    List<String> roots, {
    String empty = '',
  }) {
    final rows = [(label: heading, detail: roots.isEmpty ? empty : '')];
    for (final (index, root) in roots.indexed) {
      final last = index == roots.length - 1;
      draw(
        rows,
        root,
        lead: last ? '└─ ' : '├─ ',
        under: last ? '   ' : '│  ',
      );
    }
    return rows;
  }

  List<({String label, String detail})> gateTree(String gate) => grouped(
    'gate $gate',
    [for (final task in tasksInGate(file, gate)) task.name],
    // Only in the picture of the whole file: named, an empty gate set is
    // refused before this, as running it is.
    empty: 'no task is in it',
  );

  List<({String label, String detail})> taskTree(String at) {
    final rows = <({String label, String detail})>[];
    draw(rows, at, lead: '', under: '');
    return rows;
  }

  final List<List<({String label, String detail})>> trees;
  if (name != null) {
    trees = [
      if (file.gates.containsKey(name)) gateTree(name) else taskTree(name),
    ];
  } else {
    trees = [for (final gate in file.gates.keys) gateTree(gate)];
    // What no gate set reached: the tasks nothing names first, so a shared
    // one is drawn under them rather than as a root of its own, then
    // whatever a ring left with no way in. A root's whole reach is counted
    // before the next is chosen, so nothing it pulls in becomes a root too.
    final reached = {...drawn};
    final roots = <String>[];
    for (final at in [...entryPoints(file), ...file.tasks.keys]) {
      if (_reach(file, at, reached)) {
        roots.add(at);
      }
    }
    trees.addAll(
      // With no gate sets there is nothing to group by, and one heading
      // over the whole file would be a grouping it does not have — as
      // `--list` has none there either.
      file.gates.isEmpty
          ? [for (final root in roots) taskTree(root)]
          : [if (roots.isNotEmpty) grouped('ungated', roots)],
    );
  }

  return [
    for (final (index, rows) in trees.indexed) ...[
      if (index > 0) '',
      ..._columns(rows),
    ],
  ];
}

/// Adds [from] and every task it reaches to [reached], answering whether
/// [from] was not in it already.
///
/// A stack of its own rather than recursion: a chain as deep as the planner
/// allows is a thousand frames, and this is only bookkeeping.
bool _reach(XtaskFile file, String from, Set<String> reached) {
  if (!reached.add(from)) {
    return false;
  }
  final pending = [from];
  while (pending.isNotEmpty) {
    final task = file.tasks[pending.removeLast()];
    for (final next in [...?task?.needs, ...?task?.then]) {
      if (file.tasks.containsKey(next) && reached.add(next)) {
        pending.add(next);
      }
    }
  }
  return true;
}

/// [members], as many as [graphMembersNamed] says and then a count.
String _named(List<String> members) {
  if (members.length <= graphMembersNamed + 1) {
    return members.join(', ');
  }
  return '${members.take(graphMembersNamed).join(', ')} and '
      '${members.length - graphMembersNamed} more';
}

/// [rows], each detail in one column past the widest label of its tree.
List<String> _columns(List<({String label, String detail})> rows) {
  final width = _widest(rows.map((row) => row.label));
  return [
    for (final row in rows)
      [
        row.label.padRight(width),
        if (row.detail.isNotEmpty) '  ${row.detail}',
      ].join().trimRight(),
  ];
}

/// `--check-ci`: what each job runs, and which gate sets nothing runs.
///
/// The unrun list is reported and **not judged**: a gate set is named after
/// who runs it, and that is the jobs plus the human entry points.
/// Nothing in the file tells those apart, and a key that claimed to would be a
/// second place saying what the workflow already says.
List<String> workflow(CiReport report) {
  final unrun = report.unrun.map((gate) => '`$gate`').join(', ');
  final nobody =
      'no job runs: $unrun — right if somebody runs them by hand, wrong if a '
      'job was forgotten, and xtask cannot tell those apart';
  return [
    for (final invocation in report.invocations)
      _ran(invocation.step, invocation.gate),
    // Named rather than passed over. Such a step is not a problem and is not
    // a gate either, and a listing that showed neither would leave a reader
    // unable to tell it had been read at all.
    for (final question in report.questions)
      _asked(question.step, question.mode),
    // **Counted, not silent.** An exemption nobody sees is one nobody
    // revisits, and a workflow that has quietly exempted its way to green
    // should say so in the same breath as it passes.
    for (final step in report.exempted) _exempted(step),
    if (report.ok && report.unrun.isNotEmpty) ...['', nobody],
    if (report.ok && report.unreached.isNotEmpty) ...[
      '',
      ..._unreached(report.unreached),
    ],
  ];
}

/// `, from <where>` when a step's directory is not its own key.
String _movedBy(CiStep step) =>
    step.movedBy == null ? '' : ' (from ${step.movedBy})';

/// The tasks no job reaches, grouped by the gate sets they are in.
///
/// **Grouped, because the grouping is the signal.** A file with a people's
/// gate set beside the jobs' has whole families no job is meant to reach —
/// an editor extension's checks, say — and those come back every run. The
/// task somebody forgot to give a job's label arrives as a group of its own,
/// in the people's set alone, which is the line worth reading.
List<String> _unreached(
  List<({String task, List<String> gates})> unreached,
) {
  final bySets = <String, List<String>>{};
  for (final (:task, :gates) in unreached) {
    // Sorted: `[a, b]` and `[b, a]` are one membership, and two groups for it
    // would hide the one group worth reading among them.
    bySets
        .putIfAbsent(
          ([...gates]..sort()).map((g) => '`$g`').join(', '),
          () => [],
        )
        .add('`$task`');
  }
  const heading =
      'no job reaches these tasks, though each is in a gate set — right if '
      "somebody runs those by hand, wrong if a task was given a person's "
      "gate set and not a job's:";
  return [
    heading,
    for (final MapEntry(key: sets, value: tasks) in bySets.entries)
      '  ${tasks.join(', ')} — in $sets',
  ];
}

String _ran(CiStep step, String gate) =>
    '${step.workflow}: job `${step.job}` runs the gate set `$gate`'
    // The condition is quoted, not judged: whether it holds is the
    // workflow's business, and a reader deciding whether the gate is covered
    // needs to see it beside the gate.
    '${step.condition == null ? '' : ', when `${step.condition}`'}';

String _asked(CiStep step, String mode) =>
    '${step.workflow}: job `${step.job}` asks `$mode`, which is a question '
    'rather than a gate set';

String _exempted(CiStep step) =>
    '${step.workflow}: job `${step.job}` exempts `${step.command}` '
    '— ${step.exemption}';

/// `--check-ci`: why each step is not a job running a gate set.
///
/// The prefix — which workflow, which job, what it runs — is written once
/// here, for the three refusals and for the one line above that is not a
/// refusal at all.
List<String> refusals(CiReport report) => [
  for (final problem in report.problems) _about(problem.step, _why(problem)),
];

String _about(CiStep step, String what) =>
    '${step.workflow}: job `${step.job}` $what';

String _why(CiProblem problem) => switch (problem) {
  RunsACommand(:final step) =>
    'runs `${step.command}`. What runs belongs in the task file as '
        'a task in a gate set; a job runs the gate, so that the two cannot '
        'drift apart',
  RunsAScript(:final lines) =>
    'runs a script of $lines lines, and a script is not read here — a job '
        'runs one invocation of one gate set. Give a gate set a step of its '
        'own, and if the rest must stay a script, say why with '
        '`$exemptionMarker — …` after the `|`',
  RunsAnExpression(:final step) =>
    'runs `${step.command}`, which holds a `\${{ … }}` expression this '
        'checker cannot read. Name the gate set as written, or say why the '
        'step is not one',
  // **The command line's own sentence, not a guess at it.** Such a step may
  // name a gate set correctly and still exit before doing anything, and
  // "what runs belongs in the task file" about it sends the reader to move a
  // task that is already where it should be.
  RunsSomethingRefused(:final step, :final refusal) =>
    'runs `${step.command}`, which xtask refuses: $refusal',
  RunsAnUndeclaredGate(:final gate, :final declared) =>
    'runs the gate set `$gate`, which this file does not declare — so the job '
        'runs nothing'
        '${declared.isEmpty ? '' : '. Declared: ${_names(declared)}'}',
  RunsSomewhereElse(:final step, :final gate, :final where) =>
    isExpression(where)
        ? 'runs `$gate` under `working-directory: $where`'
              '${_movedBy(step)}, an expression — so which `$xtaskFileName` '
              'it reads cannot be said here, and a value that names a '
              "directory with a file of its own runs THAT file's `$gate`. "
              'Name the directory, or say why this step is not this '
              "file's gate"
        : 'runs `$gate` under `working-directory: $where`'
              '${_movedBy(step)}, which has an `$xtaskFileName` of its own — '
              'so the invocation reads that file and runs ITS `$gate`, and '
              "says nothing about this one. This file's gate set is left with "
              'no job running it: name it in a step at the root, or say why '
              'this one is not it',
  RunsAGateThatCannotFail(:final gate, :final onTheJob, :final written) =>
    isExpression(written)
        ? 'runs the gate set `$gate` with `continue-on-error: $written` on '
              '${onTheJob ? 'its job' : 'the step'}, an expression — so '
              'whether a red gate stops anything cannot be said here, and '
              'where it is true it stops nothing. Remove the key, or say why '
              "this step is not this file's gate"
        : 'runs the gate set `$gate` with `continue-on-error: true` on '
              '${onTheJob ? 'its job' : 'the step'}, so the gate can go red '
              'and stop nothing. A gate nothing enforces is the green nobody '
              'checked, which is the whole of what this mode is for',
  RunsATaskNotAGate(:final task, :final declared) =>
    'runs the task `$task` rather than a gate set. The job does run it — and '
        'only it: the next task added to the gate this one is in is a task no '
        'job runs, which is the drift a job naming a gate set cannot have'
        '${declared.isEmpty ? '' : '. Declared: ${_names(declared)}'}',
  RunsPartOfAGate(:final gate, :final sets) =>
    'runs `$gate` with `--only` over '
        '${sets.map((set) => '`$set`').join(', ')}, so the job runs part '
        'of it and reads as all of it — a member added later is one no job '
        'checks. Drop `--only`, or say why this step is not the gate',
  NamesAGateWithoutRunningIt(:final mode, :final named) =>
    'names the gate set `$named` under `$mode`, which asks about it rather '
        'than running it — so the job passes having run nothing of it',
  // The reason is the whole price of the exemption. Without it the marker is
  // a way of turning a red gate green and leaving nothing behind that says
  // who did it or what for.
  ExemptsWithoutSaying(:final step) =>
    'exempts `${step.command}` and gives no reason. Write it after '
        '`$exemptionMarker`: the reason is what someone reads before deleting '
        'the line, and what makes an exemption possible to weigh',
  ExemptsNothing(:final step, :final reaches) =>
    'exempts `${step.command}`, which reaches xtask as `$reaches` — '
        'so the marker excuses '
        'nothing — the step was never going to be reported as a command. A '
        'marker that excuses nothing hides the findings under it and makes '
        'the load-bearing ones impossible to find',
};

/// [of], sorted and joined.
///
/// Not shared beyond this file on purpose. Three modules render a list of gate
/// set names, and they are three different questions — a task naming an
/// undeclared one, a workflow step naming one, `--gate-members` given one —
/// so what they have in common is a one-line idiom rather than a rule. A
/// formatter reaching into the type module to save that line would be putting
/// message rendering where the shapes live.
String _names(Iterable<String> of) => (of.toList()..sort()).join(', ');

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

/// What a task with no body of its own says.
///
/// A pure composite: its `needs:` have already run and there is nothing left
/// to do, which is more useful said than left as silence. Written out in the
/// executor and in the dry run, two modules, while this one is the declared
/// home of what the tool says to a person.
String nothingToRun(String task) => '$task: nothing of its own to run';

/// What `--dry-run` says about a task's `unchanged:`.
///
/// When the set is read is the part a reader cannot guess, and the part that
/// decides whether a change made by another task counts — so it is said.
String keepsUnchanged(String task, String set) =>
    '$task: same set `$set` at its end as when the run began, byte for byte';

/// How a [Resolved] body is written down: what runs, where, and with what.
///
/// Two callers need it: `--dry-run` prints it, and a failure prints it so that
/// the line saying a task failed is also the line that reproduces it. Two
/// renderings of one value would drift, and the drift would show up as a dry
/// run promising a command a failure then reports differently.
///
/// [header] is the task's name over the block; a failure has already said
/// which task this is and asks for the block without one.
///
/// Output formats are out of scope for now, so this is the one
/// human-readable form. What it has to get right is that a person can check it
/// against what they meant.
List<String> describe(Resolved body, {bool header = true}) {
  final member = body.member;
  return [
    if (header)
      if (member == null) body.task.name else '${body.task.name}  [$member]',
    switch (body) {
      ResolvedProcess(:final executable, :final arguments) =>
        '  run  ${commandLine(executable, arguments)}',
      // The name written in the file, not the Dart function it found: a verb
      // is the project's, and `Closure: (VerbContext) => Future<int>` tells
      // the reader nothing they can check.
      ResolvedVerb(:final verb, :final arguments) =>
        '  do   ${commandLine(verb, arguments)}',
    },
    '  in   ${body.workingDirectory}',
    // **The task's own `env:`, not the environment the body will see.** The
    // second is this machine's environment with two entries changed, and
    // printing it would bury the two lines that are part of the plan under a
    // hundred that are part of the terminal. What `env-required` asked for is
    // not printed either: by the time a body resolves, it is set.
    //
    // What `env-unset:` takes away is printed beside it, as the shell would
    // write it: the body not having `CI` is as much a part of the plan as it
    // having `COVERAGE`, and it is the one change a reader cannot see by
    // looking for it.
    for (final name in body.unsetEnvironment) '  env  unset ${_quoted(name)}',
    for (final variable in body.declaredEnvironment.entries)
      '  env  ${variable.key}=${_quoted(variable.value)}',
    if (body case ResolvedProcess(timeout: final limit?))
      '  for  at most ${limit.inSeconds}s, then it is killed',
    if (body case ResolvedProcess(runInShell: true))
      '  via  cmd.exe, which is the only way to start a batch file',
  ];
}

/// [head] and [arguments], written so a person can check them.
///
/// **Public, because a run echoes the same line it later reports.** The echo
/// built its own — a bare `join(' ')` — so one run said `ls no such dir` while
/// the failure under it said `ls 'no such dir' ''`: the same three arguments,
/// rendered as four and as three, two lines apart. `--dry-run` agrees with the
/// second, so the plan and the transcript of one task contradicted each other.
String commandLine(String head, List<String> arguments) =>
    [head, ...arguments].map(_quoted).join(' ');

/// [word] written so that its edges are visible.
///
/// A plan that cannot tell one argument from two is not one anybody can check
/// against what they meant: `dart test a b` and `dart test 'a b'` are
/// different commands, and an argument that is the empty string disappears
/// entirely. This is for **reading** — xtask starts no shell, so there
/// is no shell for it to be correct for, and it does not claim to be.
String _quoted(String word) => word.isEmpty || _needsQuotes.hasMatch(word)
    ? "'${quotedInside(word)}'"
    : word;

/// What [word] becomes between the quotes [commandLine] puts around it.
///
/// Public for the reason `workflowEscaped` is: `secrets.dart` masks a value
/// in every form the engine prints it in, and `it's` is printed `it\'s`.
String quotedInside(String word) => word.replaceAll("'", r"\'");

final _needsQuotes = RegExp(r'''[\s'"]''');
