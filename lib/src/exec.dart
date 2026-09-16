/// Running a plan: what may start, what must not, what one body comes to,
/// and how the run ends.
///
/// One module, because the pieces cannot be read apart: which unit holds a
/// place, whose output is collected, and when the run has given up are one
/// story told from the walk down to the process. What the walk shares with
/// nothing else — a place, a token, the fact of having given up — is
/// `budget.dart`; the one part that knows what a signal is, is
/// `process.dart`.
library;

import 'dart:async';
import 'dart:io' show ProcessException;

import 'bodies.dart';
import 'boundary.dart';
import 'budget.dart';
import 'context.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'graph.dart';
import 'markers.dart';
import 'model.dart';
import 'process.dart';
import 'report.dart';

// ── admission ───────────────────────────────────────────────────────────────

/// What the walk should do with one step of the plan, right now.
sealed class Admission {
  const Admission();
}

/// It may start, if the run has a place and its tokens are free.
final class Ready extends Admission {
  const Ready();
}

/// Nothing it waits on has failed, but not all of it has finished either.
final class NotYet extends Admission {
  const NotYet();
}

/// It will never run, and [why] is what the summary says about it.
final class SkipIt extends Admission {
  const SkipIt(this.why);

  final Skipped why;
}

/// Whether [step] may start, must be skipped, or is simply not ready.
///
/// The whole of the walk's ordering rule, and pure: it reads what has already
/// happened and touches neither the budget nor the tokens, so it can be
/// checked as a table rather than by running a plan.
///
/// A step may begin when everything it waits on has FINISHED, which is why the
/// plan's order decides only which of the ready ones begins first: the file's
/// cheap-before-slow is a preference here rather than a guarantee.
///
/// [givenUp] is the run having decided its answer: what has not started must
/// not start. What is running is left alone.
Admission admits(
  PlanStep step, {
  required Set<String> finished,
  required Set<String> stopped,
  required bool givenUp,
}) {
  // Named rather than dropped: a task that silently did not happen is
  // indistinguishable from one that passed.
  for (final need in step.task.needs) {
    if (stopped.contains(need)) {
      return SkipIt(NeedsStopped(need));
    }
  }
  final origin = step.continuationOf;
  // A publish that failed must not be announced anyway.
  if (origin != null && stopped.contains(origin)) {
    return SkipIt(FollowsStopped(origin));
  }
  if (givenUp) {
    return const SkipIt(RunStopped());
  }
  if (!step.task.needs.every(finished.contains) ||
      (origin != null && !finished.contains(origin))) {
    return const NotYet();
  }
  return const Ready();
}

// ── output ──────────────────────────────────────────────────────────────────

/// Where one unit's lines go: straight out, or collected and let out whole
/// when the unit ends.
///
/// Two units writing to one terminal at once produce a transcript belonging
/// to neither, and a section that folds lines from two tasks folds nothing —
/// so a unit that could be writing beside another collects its lines and
/// prints them when it ends. A task's members collect into the task, and the
/// task collects into the log; [live] says whether nothing along that way
/// collects, which is when a child may write to the terminal itself.
final class _Lines {
  _Lines._(this._out, {required bool collected, required this.live})
    : _held = collected ? [] : null;

  /// Lines going straight to [out].
  _Lines.to(void Function(String line) out)
    : this._(out, collected: false, live: true);

  final void Function(String line) _out;
  final List<String>? _held;

  /// Whether a line written here reaches the terminal as it is written.
  final bool live;

  /// Lines for one unit inside this one.
  _Lines into({required bool collected}) =>
      _Lines._(call, collected: collected, live: live && !collected);

  void call(String line) {
    final held = _held;
    if (held == null) {
      _out(line);
    } else {
      held.add(line);
    }
  }

  /// Lets out what was collected, in order.
  void end() {
    final held = _held;
    if (held == null) {
      return;
    }
    held
      ..forEach(_out)
      ..clear();
  }
}

// ── the run ─────────────────────────────────────────────────────────────────

/// What one run has recorded about its tasks, for the summary.
final class _Outcomes {
  final took = <String, Duration>{};
  final failed = <String, int>{};
  final skipped = <String, Skipped>{};

  /// How much work each fanned-out task's members added up to — the number
  /// `-j` is for, beside how long the task took.
  final work = <String, ({Duration spent, int members})>{};
}

/// How one body ended.
enum _Ending {
  /// It finished, and answered success.
  finished,

  /// It was stopped because the run had given up. Not a failure.
  stopped,
}

/// Runs a [Plan], in order, stopping at the first failure.
final class Executor {
  Executor({
    required this.bodies,
    required this.starter,
    required this.log,
    this.markers = const PlainMarkers(),
    this.now = DateTime.now,
    this.keepGoing = false,
    this.concurrency = 1,
  });

  /// What each task comes to on this machine.
  final BodyResolver bodies;

  final ProcessStarter starter;

  /// Where reports go. A task is a grouped section on a host that understands
  /// grouping, which is only possible if the engine knows where a task starts
  /// and ends — so it writes, rather than letting bodies print around it.
  final void Function(String line) log;

  /// How this host wants a section of output marked.
  ///
  /// Defaulting to [PlainMarkers] rather than detecting is deliberate:
  /// detection is `LogMarkers.forHost`, and a class that reached for the
  /// ambient environment itself could not be tested for either host.
  final LogMarkers markers;

  /// Whether a failure ends the run, or only that task.
  ///
  /// Off by default: a pipeline wants the earliest red. A person fixing
  /// things locally wants the whole list, which is the argument `--validate`
  /// is built on.
  final bool keepGoing;

  /// How many units may be in flight at once. 1 is the sequential run.
  ///
  /// Above 1, live output is given up: two units writing to one terminal
  /// produce a transcript belonging to neither, so each unit's output is
  /// collected and printed whole when it ends. Declaration order survives as
  /// a preference: it decides which of the ready tasks starts first, not
  /// which finishes.
  final int concurrency;

  /// Where the clock comes from — injected, so a summary can be asserted.
  final DateTime Function() now;

  /// Whether this run has decided the answer is known.
  final _givenUp = GivenUp();

  /// The named mutexes this run's tasks share.
  final _exclusive = Exclusive();

  /// The run's budget, spent by units of work rather than by tasks.
  late final _slots = Slots(concurrency);

  /// Runs every step, and answers with the code the exit code table gives the
  /// outcome.
  Future<int> run(Plan plan) async {
    // Whether two units could be writing at once — which is what collecting
    // output is for, and what the announcement is about.
    final concurrent =
        concurrency > 1 &&
        (plan.steps.length > 1 || plan.steps.any((s) => _canFanOut(s.task)));

    // Before the walk, so it is the first thing on the stream rather than the
    // first thing after a wait it was meant to explain.
    if (concurrent) {
      starting(plan.steps.length, concurrency).forEach(log);
    }

    final outcomes = _Outcomes();
    final began = now();
    final int code;
    try {
      code = await _walk(plan, outcomes, concurrent: concurrent);
    } finally {
      // Printed on the way out, whichever way that is: a file found wrong
      // mid-run unwinds through here, and the tasks that had already
      // finished, failed or been skipped are still worth their lines.
      timing(
        outcomes.took,
        now().difference(began),
        outcomes.work,
        concurrent: concurrent,
      ).forEach(log);
      // Last, because it is the part somebody has to act on and the terminal
      // scrolls.
      summary(outcomes.failed, outcomes.skipped).forEach(log);
    }
    return code;
  }

  /// Whether [task]'s members may run together at this width.
  ///
  /// `each:` without `serial:` is the shape that can fan out. A task holding
  /// an `exclusive:` token holds it alone, and that includes against its own
  /// members: naming a browser and then driving it from four members at once
  /// would be the guarantee said and not kept.
  bool _canFanOut(Task task) =>
      concurrency > 1 &&
      task.each != null &&
      !task.serial &&
      task.exclusive.isEmpty;

  /// Walks the plan, starting what is ready and waiting for what is running.
  ///
  /// One loop for both `-j 1` and `-j n`: at one unit in flight the
  /// sequential order and the ready-first order are the same order.
  ///
  /// What may start is [admits]. This decides only which of the ready ones
  /// goes first, takes a place and the tokens for it, and collects the
  /// outcomes. A task is admitted with a place and its tokens or with
  /// neither: admitted without a place it would hold its tokens while doing
  /// nothing, and admitted without its tokens it would hold a place while
  /// doing nothing.
  Future<int> _walk(
    Plan plan,
    _Outcomes outcomes, {
    required bool concurrent,
  }) async {
    final waiting = [...plan.steps];
    // Where each task sits in the plan, so a failure can be placed in it.
    final order = {
      for (var at = 0; at < plan.steps.length; at++)
        plan.steps[at].task.name: at,
    };
    final running = <String, Future<void>>{};
    final finished = <String>{};
    final stopped = <String>{};

    // Which failure answers for the run, keyed by plan position: the order
    // tasks finish in depends on the machine, and the plan's order does not.
    final failures = <int, int>{};

    while (waiting.isNotEmpty || running.isNotEmpty) {
      var began = false;
      for (var at = 0; at < waiting.length; at++) {
        final step = waiting[at];
        final name = step.task.name;
        final verdict = admits(
          step,
          finished: finished,
          stopped: stopped,
          givenUp: _givenUp.already,
        );
        if (verdict case SkipIt(:final why)) {
          outcomes.skipped[name] = why;
          stopped.add(name);
          waiting.removeAt(at--);
          began = true;
          continue;
        }
        if (verdict is NotYet) {
          continue;
        }
        if (!_slots.hasFree) {
          // Nothing can begin until something ends.
          break;
        }
        // Left where it is rather than admitted and blocked: a task waiting
        // for somebody else's browser waits in the queue, holding nothing.
        if (!_exclusive.tryHold(step.task.exclusive)) {
          continue;
        }
        final place = _slots.takeNow();
        waiting.removeAt(at--);
        began = true;
        running[name] =
            _runOne(
              step,
              place,
              outcomes,
              // Only where a second TASK could interleave. A one-step plan
              // keeps its live output, and its members collect on their own.
              collected: concurrent && plan.steps.length > 1,
            ).then((code) {
              unawaited(running.remove(name));
              finished.add(name);
              if (code != null) {
                stopped.add(name);
                failures[order[name]!] = code;
              }
            });
      }

      if (running.isEmpty && !began) {
        // Nothing running and nothing startable: whatever is left is waiting
        // on something that will never finish.
        for (final step in waiting) {
          outcomes.skipped[step.task.name] = const NeverStartable();
          stopped.add(step.task.name);
        }
        waiting.clear();
        break;
      }
      if (running.isNotEmpty) {
        try {
          await Future.any(running.values);
        } on Object {
          // A file found wrong mid-run is `cli.dart`'s to answer, and it
          // arrives here through `Future.any`. Nothing is reported while
          // tasks are still running: they are let finish, each records its
          // own outcome, and what never started is named too.
          await Future.wait(
            running.values,
          ).catchError((Object _) => const <void>[]);
          for (final step in waiting) {
            outcomes.skipped[step.task.name] = const RunStopped();
          }
          waiting.clear();
          rethrow;
        }
      }
    }

    if (failures.isEmpty) {
      return ExitCode.success;
    }
    // A plain failure takes the answer from a continuation, and the plan's
    // order decides among failures of the same kind: 4 says "only a `then:`
    // failed", which no run where an ordinary task also failed may claim.
    final plain = failures.entries.where(
      (failure) => failure.value != ExitCode.continuationFailed,
    );
    return (plain.isEmpty ? failures.entries : plain)
        .reduce((a, b) => a.key <= b.key ? a : b)
        .value;
  }

  /// One task, timed, and reported where the mode says to report it.
  ///
  /// [place] is the task's, taken by the walk; its first member runs on it.
  /// Answers with the code the task failed with, or null.
  Future<int?> _runOne(
    PlanStep step,
    Lease place,
    _Outcomes outcomes, {
    required bool collected,
  }) async {
    final task = step.task;
    final lines = _Lines.to(log).into(collected: collected);
    final started = now();
    try {
      await _runTask(task, place, outcomes, lines);
      return null;
    } on Object catch (thrown, stack) {
      if (thrown is XtaskFormatException) {
        // Not this method's to answer: code 2 belongs to the file being
        // wrong, and `cli.dart` is where that sentence is written. The
        // section is closed on the way past.
        markers.close().forEach(lines.call);
        rethrow;
      }
      // One clause, because there is one ending. A verb is arbitrary project
      // Dart and can throw anything; so can a fault in this engine. Neither
      // is an exit code, and both are a task that failed.
      final failure = thrown is RunFailure ? thrown : bodyThrew(task, thrown);
      if (thrown is! RunFailure) {
        // A trace is the only thing that locates a fault, and it goes inside
        // the section: GitHub reads a workflow command to the end of its
        // line, so twenty frames in the annotation become one escaped line.
        lines('$stack');
      }
      // Closes the open section and annotates, in that order: an `::error::`
      // inside a group is folded away with it.
      markers.error(failure.message).forEach(lines.call);
      outcomes.failed[task.name] = failure.code;

      if (step.isContinuation) {
        // Always 4, whatever went wrong inside it: the body already
        // succeeded, so the publish happened.
        lines(ExitCode.continuationNotice);
        return ExitCode.continuationFailed;
      }
      return failure.code;
    } finally {
      _exclusive.release(task.exclusive);
      // The task that FAILED is timed too. Where the run spent itself before
      // it broke is most of what somebody wants from a red job.
      outcomes.took[task.name] = now().difference(started);
      lines.end();
    }
  }

  /// A section per task, opened before anything that can fail inside it.
  ///
  /// It is closed here on success and by `markers.error` on failure — never
  /// twice, which is what the ordering inside [GitHubMarkers.error] is for.
  Future<void> _runTask(
    Task task,
    Lease place,
    _Outcomes outcomes,
    _Lines lines,
  ) async {
    markers.open(task.name).forEach(lines.call);

    // Every way this task could turn out to be unrunnable is answered by one
    // call, and answered the same way `--dry-run` is answered — because it is
    // the same call.
    final List<Resolved> resolved;
    try {
      resolved = bodies.resolveTask(task);
    } on Object catch (thrown) {
      // **Said before the place is given back, for the reason `_runMembers`
      // gives when a member fails:** whoever is waiting for the place must
      // find the run already over. This is `async`, so the rethrow reaches
      // `_runOne` a microtask later — and the walk, handed a free slot by the
      // line below and a run that has not failed yet, admitted the next task
      // in the same pass. A missing program then stopped nothing, and the
      // task it wrongly admitted bound `stdout` with its ordering flush while
      // the failure's own error line was still on its way out, which ended
      // the run at 255 with the diagnostic never printed.
      //
      // Every way `resolveTask` can refuse arrives here: a missing tool, an
      // unset `env-required`, an unknown verb, a set that expands to nothing,
      // an `in:` outside the root.
      if (thrown is XtaskFormatException || !keepGoing) {
        _givenUp.now();
      }
      place.release();
      rethrow;
    }
    if (resolved.isEmpty) {
      // A pure composite. Its `needs:` have already run; there is nothing of
      // its own to do, and saying so is more useful than silence.
      place.release();
      lines(nothingToRun(task.name));
      markers.close().forEach(lines.call);
      return;
    }

    await _runMembers(task, resolved, place, outcomes, lines);
    markers.close().forEach(lines.call);
  }

  /// Runs every body of [task], the first on [first] and the rest on places
  /// of their own, and throws the failure the run answers with.
  ///
  /// Which member's failure answers is decided by the set's order rather than
  /// by which finished first, so the answer does not depend on scheduling.
  Future<void> _runMembers(
    Task task,
    List<Resolved> resolved,
    Lease first,
    _Outcomes outcomes,
    _Lines lines,
  ) async {
    // Collecting is the price of two members writing at once, paid only then.
    final together = _canFanOut(task) && resolved.length > 1;
    final failures = <int, RunFailure>{};
    var attempted = 0;
    // Whether this task's own members should stop starting. Distinct from the
    // run giving up: under `--keep-going` a failed member stops nothing.
    var stop = false;
    XtaskFormatException? malformed;
    ({Duration spent, int members})? work;

    Future<void> member(int at, Lease? given) async {
      final place = given ?? await _slots.take();
      // The one check, at the moment a unit has a place: a failure anywhere
      // — a sibling's, another task's — stops what has not started.
      if (stop || _givenUp.already) {
        place.release();
        return;
      }
      final own = lines.into(collected: together);
      attempted++;
      // Measured only where it is reported: the members' work is a line of
      // its own when there is more than one of them.
      final began = resolved.length > 1 ? now() : null;
      try {
        if (await _perform(resolved[at], own) == _Ending.stopped) {
          stop = true;
        }
      } on XtaskFormatException catch (thrown) {
        // The file being wrong is not a thing more members can fix, and it
        // ends the run whatever the flags say. Kept rather than raised from
        // inside the wait, so the tally below still counts the siblings.
        stop = true;
        malformed ??= thrown;
        _givenUp.now();
      } on Object catch (thrown) {
        // Anything, not only a `RunFailure`: a verb can throw whatever it
        // likes, and the tally must still say what its siblings did.
        failures[at] = thrown is RunFailure
            ? thrown
            : bodyThrew(task, thrown, member: resolved[at].member);
        if (!keepGoing) {
          stop = true;
          // Said before the place is given back, so that whoever is waiting
          // for it finds the run already over.
          _givenUp.now();
        }
      } finally {
        place.release();
        if (began != null) {
          work = (
            spent: (work?.spent ?? Duration.zero) + now().difference(began),
            members: (work?.members ?? 0) + 1,
          );
        }
        own.end();
      }
    }

    if (together) {
      // **One request in the queue at a time, not one per member.** Written as
      // a list literal, every member called `Slots.take()` before control
      // returned to the walk — and a freed place is handed straight to
      // whoever has waited longest, so with the queue full of this task's
      // members no other plan step could begin until all of them had. `-j 4`
      // over an eight-member suite ran the suite and only then the
      // independent `format` that had been asked for first, which is the
      // opposite of what the budget says it does. Asking for the next place
      // only when there is one to ask for puts this task back in the same
      // first-come-first-served queue as everything else.
      final inFlight = <Future<void>>[];
      for (var at = 0; at < resolved.length; at++) {
        if (at > 0 && (stop || _givenUp.already)) {
          // Checked before a place is taken rather than after: a member that
          // takes one only to give it back is a place the walk could not see.
          break;
        }
        inFlight.add(member(at, at == 0 ? first : await _slots.take()));
      }
      await Future.wait(inFlight);
    } else {
      for (var at = 0; at < resolved.length; at++) {
        await member(at, at == 0 ? first : null);
      }
    }

    // Recorded before anything is raised: where the run spent itself before
    // it broke is most of what somebody wants from a red job.
    if (work case final done?) {
      outcomes.work[task.name] = done;
    }
    // A task the run gave up on part-way is named, like a task it never
    // reached: two of eight members having run reads exactly like eight.
    if (attempted < resolved.length && failures.isEmpty && malformed == null) {
      outcomes.skipped[task.name] = PartlyRun(
        attempted: attempted,
        members: resolved.length,
      );
    }
    // The file being wrong outranks a task that failed.
    final failure = malformed ?? _tally(task, resolved, failures, attempted);
    if (failure != null) {
      throw failure;
    }
  }

  /// The one failure the run answers with, carrying what happened to the rest.
  RunFailure? _tally(
    Task task,
    List<Resolved> resolved,
    Map<int, RunFailure> failures,
    int attempted,
  ) {
    if (failures.isEmpty) {
      return null;
    }
    final order = failures.keys.toList()..sort();
    final failed = [for (final at in order) resolved[at].member ?? task.name];
    // The EARLIEST failing member's code, by the set's order.
    final failure = failures[order.first]!;
    final members = resolved.length;
    if (members == 1) {
      return failure;
    }
    final named = failed.take(5).map((member) => '`$member`').join(', ');
    final more = failed.length > 5 ? ' and ${failed.length - 5} more' : '';
    final unattempted =
        '${members - attempted} of $members not attempted — '
        '`--keep-going` runs them all';
    return RunFailure(
      failure.code,
      [
        failure.message,
        if (failed.length > 1)
          '${failed.length} of $members members failed: $named$more',
        if (attempted < members) unattempted,
      ].join('\n'),
    );
  }

  // ── one body ──────────────────────────────────────────────────────────────

  /// Performs [body], and says how it ended. Throws [RunFailure] when it
  /// failed.
  Future<_Ending> _perform(Resolved body, _Lines lines) async {
    final task = body.task;
    final member = body.member;
    final where = member == null ? '' : ' at `$member`';

    final int code;
    try {
      code = await _start(body, lines);
    } on ProcessException catch (failure) {
      // Only where "could not be started" is literally true. A verb that
      // shells out to `git` on a machine without it raises this too, and
      // reported here it would print `do <verb>` and send whoever reads it
      // to inspect the wrong command entirely.
      if (body is! ResolvedProcess) {
        rethrow;
      }
      // `Process.start` throws rather than answering when the working
      // directory does not exist. Answers 1: code 3 is the resolver having
      // PROVED the tool absent, and a start that failed for some other reason
      // is not that proof.
      throw RunFailure(
        ExitCode.taskFailed,
        [
          'task `${task.name}`$where could not be started: ${failure.message}',
          ...describe(body, header: false),
        ].join('\n'),
      );
    }

    if (code == ExitCode.success) {
      return _Ending.finished;
    }

    // Not a failure: it was not allowed to finish, and calling that a failure
    // would put a second red thing beside the one that actually broke. Gated
    // on the run having given up and not on the number alone: 130 is what
    // plenty of programs exit with on their own.
    if (code == SystemProcessStarter.interrupted &&
        task.interruptible &&
        _givenUp.already) {
      lines(
        'task `${task.name}`$where was stopped: an earlier failure had already '
        'answered the run',
      );
      return _Ending.stopped;
    }

    // A killed process is reported as killed, not as "exit code 124": the
    // number is what a shell wrapping this checks for, and a number nobody
    // reads as "it hung". Recognised rather than proved.
    final killed =
        code == SystemProcessStarter.timedOut &&
        body is ResolvedProcess &&
        body.timeout != null;
    final what = killed
        ? 'did not finish inside its `timeout: ${task.timeout}`, and was killed'
        : 'failed with exit code $code';

    // A verb's code is a decision; a process's code is data. A verb is the
    // project's own Dart, written against the exit code table — `remove`
    // answering 2 is saying "the FILE is wrong". An external program has
    // never heard of the table, so its number goes in the message and the run
    // answers 1.
    final answers = body is ResolvedVerb ? code : ExitCode.taskFailed;
    throw RunFailure(
      answers,
      [
        'task `${task.name}`$where $what',
        // The line that says it broke is the line that reproduces it, and it
        // is rendered by `describe`, so what a failure reports and what
        // `--dry-run` promised cannot disagree.
        ...describe(body, header: false),
      ].join('\n'),
    );
  }

  /// Starts what [body] resolved to, and answers with its exit code.
  Future<int> _start(Resolved body, _Lines lines) {
    switch (body) {
      case ResolvedVerb(:final implementation):
        return implementation(
          VerbContext(
            args: body.arguments,
            env: body.environment,
            workingDirectory: body.workingDirectory,
            log: lines.call,
            member: body.member,
            // The same resolution and the same starter a `run:` body gets, so
            // a verb that runs a program keeps the resolver's answers rather
            // than reaching for `Process.start` and losing them.
            start: (argv, {workingDirectory}) =>
                _startForVerb(body, argv, workingDirectory, lines),
          ),
        );

      case ResolvedProcess(
        :final executable,
        :final runInShell,
        :final timeout,
      ):
        // The member is named, because six identical lines from one `each:`
        // over six packages is a log that makes somebody run all six again.
        final member = body.member;
        lines(
          '${body.task.name}${member == null ? '' : ' [$member]'}: '
          '${commandLine(executable, body.arguments)}',
        );
        return starter.start(
          executable,
          body.arguments,
          workingDirectory: body.workingDirectory,
          environment: body.environment,
          runInShell: runInShell,
          timeout: timeout,
          until: body.task.interruptible ? _givenUp.reached : null,
          // A child writes to the terminal itself only where nothing between
          // it and the terminal is collecting.
          output: lines.live ? null : lines.call,
        );
    }
  }

  /// A program started on a verb's behalf, resolved the way a `run:` body is.
  ///
  /// Refused in the same words a `run:` body is refused with — a name nothing
  /// on `PATH` answers to is still code 3, because "the toolchain is not
  /// installed" and "the code is broken" still reach different people.
  Future<int> _startForVerb(
    Resolved body,
    List<String> argv,
    String? written,
    _Lines lines,
  ) {
    if (argv.isEmpty) {
      throw RunFailure(
        ExitCode.invalidFile,
        'verb of task `${body.task.name}` asked to run nothing',
      );
    }
    final workingDirectory = _verbDirectory(body, written);
    final executable = bodies.resolver.resolve(
      argv.first,
      from: workingDirectory,
    );
    if (executable == null) {
      throw RunFailure(
        ExitCode.missingTool,
        'task `${body.task.name}`: '
        '${bodies.resolver.missingToolMessage(
          argv.first,
          from: workingDirectory,
        )}',
      );
    }
    final arguments = argv.skip(1).toList();
    final runInShell = bodies.resolver.needsShell(executable);
    if (runInShell) {
      refuseShellMetacharacters(body.task.name, executable, arguments);
    }
    return starter.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: body.environment,
      runInShell: runInShell,
      output: lines.live ? null : lines.call,
    );
  }

  /// Where a verb's own process starts, refusing what the root does not own.
  ///
  /// Relative to the repository root, as every other path in the file is, and
  /// asked the boundary: `p.join` walks straight up a `..`. Code 2 rather than
  /// 1, for the reason `remove` answers 2 on the same question — a path
  /// outside the repository is the project being wrong about what it owns.
  String _verbDirectory(Resolved body, String? written) {
    if (written == null) {
      return body.workingDirectory;
    }
    final where = verbDirectoryUnderRoot(bodies.root, written);
    if (where == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        verbDirectoryLeavesRoot(task: body.task.name, written: written),
      );
    }
    return where;
  }
}

/// What an exception that is not a [RunFailure] comes to.
///
/// Named rather than swallowed: the type and the message are the whole of the
/// bug report, and which task — and member — was running is the half that
/// says where to look. Answers 1, because a body that threw is a body that
/// did not do its job; code 3 stays reserved for the resolver having proved a
/// tool absent.
RunFailure bodyThrew(Task task, Object thrown, {String? member}) => RunFailure(
  ExitCode.taskFailed,
  'task `${task.name}`${member == null ? '' : ' at `$member`'} threw '
  '${thrown.runtimeType}: $thrown. A body that raises rather than answering '
  "is either the project's own verb or a fault in this engine; either way it "
  'is this task that stopped',
);
