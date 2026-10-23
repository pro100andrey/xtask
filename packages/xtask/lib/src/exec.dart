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
import 'sets.dart';
import 'unchanged.dart';

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

  /// What `--only` left of the set each narrowed task expanded.
  final narrowed = <String, ({int kept, int of})>{};

  // What only `--report` says. Kept apart from the maps above because the
  // summary is built from those, and a person reading it has already been
  // told each of these where it happened.

  /// The tasks that have begun, so a report written while one runs can say
  /// it was running rather than never reached.
  final started = <String>{};

  /// What each failed task printed, by task.
  final why = <String, String>{};

  /// The tasks the file was found wrong in part-way, with what was said. The
  /// run answers 2 for them, which the summary has no line for.
  final refused = <String, String>{};

  /// The tasks a member of which was stopped part-way, because the run had
  /// given up and the task was `interruptible:`.
  final interrupted = <String>{};

  /// What each member of an `each:` task came to, in the set's order.
  final members = <String, List<Ended>>{};
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
    this.reportTo,
    this.interruption,
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

  /// Where what the run has come to goes, for `--report`: once before the
  /// first task begins, again each time tasks begin or end, and last when
  /// the run does.
  ///
  /// **As it goes, not only at the end.** A run can still be ended where it
  /// stands — a `SIGKILL`, a machine going down — with nothing after it run,
  /// so the last thing written here is all a report of such a run can be.
  /// Written as each task begins and ends, it is never older than the task
  /// that was running.
  final void Function(RunSoFar run)? reportTo;

  /// Where a signal this process receives is told to the run, if anywhere.
  ///
  /// When one is: nothing more starts, every process the run started — a
  /// `run:` body, a member of an `each:` under `-j`, a program a verb started
  /// — is asked to stop with SIGTERM and made to after a grace, a verb itself
  /// is waited for, and the run answers [bySignal]. Without this the
  /// process died where it stood and left them all running, orphaned.
  final Interruption? interruption;

  /// Whether this run has decided the answer is known.
  final _givenUp = GivenUp();

  /// The named mutexes this run's tasks share.
  final _exclusive = Exclusive();

  /// The run's budget, spent by units of work rather than by tasks.
  late final _slots = Slots(concurrency);

  /// What each `unchanged:` task's set held when the run began, by task.
  final _found = <String, Holding>{};

  /// Why a task's `unchanged:` could not be read when the run began, by task.
  /// Said when the run reaches the task, as any refusal of its own is.
  final _unreadable = <String, RunFailure>{};

  /// What an `unchanged:` set is expanded with, under the resolver's rules.
  ///
  /// Its own rather than the resolver's, because `--only` narrows what the
  /// resolver hands a body and must not narrow this: a generator run for one
  /// member can still rewrite another's files, and that is a change too.
  late final _expander = SetExpander(root: bodies.root);

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

    _holdUnchanged(plan);

    // A signal ends the run as a failure does, before anything else hears of
    // it: [Interruption] completes synchronously, so a member asking whether
    // to begin sees the run over in the same turn the signal arrived in.
    unawaited(
      interruption?.reached.then((_) {
        _givenUp.now();
        log(stopping(_signal!.name));
      }),
    );

    final outcomes = _Outcomes();
    final began = now();
    void report() => _report(plan, outcomes, began);
    report();
    final int code;
    try {
      code = await _walk(plan, outcomes, report, concurrent: concurrent);
    } finally {
      report();
      // Printed on the way out, whichever way that is: a file found wrong
      // mid-run unwinds through here, and the tasks that had already
      // finished, failed or been skipped are still worth their lines.
      timing(
        outcomes.took,
        now().difference(began),
        outcomes.work,
        concurrent: concurrent,
        narrowed: outcomes.narrowed,
      ).forEach(log);
      // Last, because it is the part somebody has to act on and the terminal
      // scrolls.
      summary(outcomes.failed, outcomes.skipped).forEach(log);
    }
    // Whatever the tasks came to: the run ended because it was told to, and
    // a shell reading the code is owed the number that says so.
    if (_signal case (:final number, name: _)) {
      return bySignal(number);
    }
    return code;
  }

  /// The signal this process received, or null while there has been none.
  ({int number, String name})? get _signal => interruption?.signal;

  /// Why a task the run did not begin was not begun: an earlier failure, or a
  /// signal.
  Skipped get _notBegun => switch (_signal) {
    (:final name, number: _) => Signalled(name, began: false),
    null => const RunStopped(),
  };

  /// Why a task the run stopped part-way was stopped.
  Skipped get _partWay => switch (_signal) {
    (:final name, number: _) => Signalled(name, began: true),
    null => const Interrupted(),
  };

  /// Hands [reportTo] what the run has come to so far, where there is one.
  ///
  /// Asks the clock only then: a run nobody reports reads it exactly as it
  /// did before there was a report to write.
  void _report(Plan plan, _Outcomes outcomes, DateTime began) {
    final to = reportTo;
    if (to == null) {
      return;
    }
    to((
      tasks: [for (final step in plan.steps) _ended(step.task.name, outcomes)],
      took: now().difference(began),
    ));
  }

  /// What became of [name], from what the run has recorded about it.
  ///
  /// A failure first, because a task that failed may also be one the run
  /// gave up on part-way. What it has nothing recorded for has not ended:
  /// a report written now and left behind by a run cut off says so.
  Ended _ended(String name, _Outcomes outcomes) {
    final took = outcomes.took[name];
    final members = outcomes.members[name] ?? const <Ended>[];
    if (outcomes.refused[name] case final why?) {
      return Ended(
        name,
        Result.failed,
        took: took,
        code: ExitCode.invalidFile,
        why: why,
        members: members,
      );
    }
    if (outcomes.failed[name] case final code?) {
      return Ended(
        name,
        Result.failed,
        took: took,
        code: code,
        why: outcomes.why[name],
        members: members,
      );
    }
    final skipped =
        outcomes.skipped[name] ??
        (outcomes.interrupted.contains(name) ? _partWay : null) ??
        (took == null ? CutOff(began: outcomes.started.contains(name)) : null);
    if (skipped == null) {
      return Ended(name, Result.passed, took: took, members: members);
    }
    return Ended(
      name,
      resultOf(skipped),
      took: took,
      why: skipped.sentence,
      members: members,
    );
  }

  /// Reads every `unchanged:` set in [plan], before anything has run.
  ///
  /// **When the run begins, not when the task is reached, and not when its
  /// `needs:` begin.** A generation is often several steps — `gen-l10n`, then
  /// `build_runner` — and the task that holds the set is the composite over
  /// them, so the set has to be read before its `needs:`. And a `needs:` runs
  /// once per invocation, for whichever branch of the graph reaches it first:
  /// in a gate where `test` needs `build` and is listed ahead of `codegen`,
  /// `build` has regenerated everything before `codegen`'s own steps would
  /// begin, and a set read then compares the regenerated files with
  /// themselves — stale committed code, passed. Before the walk is the one
  /// moment that is before every step of every branch.
  ///
  /// The price is said in the README: anything in the run that writes the
  /// set before the task ends counts against it. That is the question asked —
  /// whether the committed files are what this run leaves — and a task that
  /// is to write them is not one to hold them unchanged.
  void _holdUnchanged(Plan plan) {
    // Per set, so two tasks holding one set read it once: both are read at
    // the same moment, so they would read the same thing.
    final read = <String, Holding>{};
    for (final step in plan.steps) {
      final task = step.task;
      final name = task.unchanged;
      if (name == null) {
        continue;
      }
      if (unchangedRefusal(task, bodies.sets) case final refusal?) {
        _unreadable[task.name] = RunFailure(ExitCode.invalidFile, refusal);
        continue;
      }
      try {
        _found[task.name] = read[name] ??= holding(
          _expander,
          task,
          name,
          bodies.sets[name]!,
        );
      } on RunFailure catch (failure) {
        _unreadable[task.name] = failure;
      }
    }
  }

  /// Refuses [task] if its set changed since the run began.
  ///
  /// Only for a task whose body finished: a body that failed has already
  /// answered, and a run that has given up stopped generators part-way, whose
  /// half-written output is not the question.
  void _refuseChanged(Task task, _Outcomes outcomes) {
    final before = _found[task.name];
    if (before == null ||
        _givenUp.already ||
        outcomes.skipped.containsKey(task.name)) {
      return;
    }
    final failure = _changedSince(task, before);
    if (failure == null) {
      return;
    }
    // Said here, as a failed member says it: a task that fails after its body
    // has finished is a failure like any other, and without `--keep-going`
    // nothing more may start.
    if (!keepGoing) {
      _givenUp.now();
    }
    throw failure;
  }

  /// Why [task] fails, measured against what its set held [before], or null.
  RunFailure? _changedSince(Task task, Holding before) {
    final name = task.unchanged!;
    final Holding after;
    try {
      after = holding(_expander, task, name, bodies.sets[name]!);
    } on RunFailure catch (failure) {
      return failure;
    }
    if ((before.empty, after.empty) case (_?, final empty?)) {
      // Empty then and empty now: nothing was compared, and a check that
      // compared nothing is the green result nobody checked. A set the run
      // filled, or emptied, is a change and is said as one below.
      return RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` has nothing to compare:\n$empty',
      );
    }
    final changed = changes(before, after);
    return changed.isEmpty ? null : changedASet(task, name, changed);
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
      !task.alone &&
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
    _Outcomes outcomes,
    void Function() report, {
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

    // The `alone:` task running now, if one is. While it runs nothing is
    // admitted, whatever is ready and whatever places are free.
    String? alone;

    // Whether a task that runs alone has been found ready while others ran,
    // and is waiting for them. From then on it is the next thing to start,
    // wherever it sits in the plan: a task ahead of it that becomes ready
    // later is still behind it.
    var aloneWaits = false;

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
          outcomes.skipped[name] = why is RunStopped ? _notBegun : why;
          stopped.add(name);
          waiting.removeAt(at--);
          began = true;
          continue;
        }
        if (verdict is NotYet) {
          continue;
        }
        // **Waited for, and nothing overtakes it.** A task that runs alone
        // and is ready while others run holds the walk until they have
        // ended; letting another ready task start in the meantime — behind
        // it in the plan or ahead of it — would let a steady stream of them
        // keep it waiting for ever, which is the guarantee kept by never
        // running at all.
        if (alone != null) {
          break;
        }
        if (step.task.alone && running.isNotEmpty) {
          aloneWaits = true;
          break;
        }
        if (aloneWaits && !step.task.alone) {
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
              // keeps its live output, and its members collect on their own
              // — and so does a task that runs alone, since nothing can.
              collected:
                  concurrent && plan.steps.length > 1 && !step.task.alone,
            ).then((code) {
              unawaited(running.remove(name));
              if (alone == name) {
                alone = null;
              }
              finished.add(name);
              if (code != null) {
                stopped.add(name);
                failures[order[name]!] = code;
              }
              report();
            });
        if (step.task.alone) {
          alone = name;
          aloneWaits = false;
          break;
        }
      }

      // What began, or was skipped, this pass: a run cut off while they run
      // leaves a report that says they were running, not that they were
      // never reached.
      if (began) {
        report();
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
            outcomes.skipped[step.task.name] = _notBegun;
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
    outcomes.started.add(task.name);
    try {
      await _runTask(task, place, outcomes, lines);
      return null;
    } on Object catch (thrown, stack) {
      if (thrown is XtaskFormatException) {
        // Not this method's to answer: code 2 belongs to the file being
        // wrong, and `cli.dart` is where that sentence is written. The
        // section is closed on the way past.
        markers.close().forEach(lines.call);
        outcomes.refused[task.name] = '$thrown';
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
      outcomes.why[task.name] = failure.message;

      if (step.isContinuation) {
        // Always 4, whatever went wrong inside it: the body already
        // succeeded, so the publish happened.
        lines(
          continuationNotice(
            body: step.continuationOf!,
            continuation: task.name,
          ),
        );
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
      // Before the body, with the task's other refusals: a gate that cannot
      // compare must not run the generator and then say nothing about it.
      if (_unreadable[task.name] case final failure?) {
        throw failure;
      }
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
    if (bodies.narrowing(task.each ?? task.all ?? '') case final part?) {
      outcomes.narrowed[task.name] = part;
    }
    if (resolved.isEmpty) {
      // A pure composite. Its `needs:` have already run; there is nothing of
      // its own to do, and saying so is more useful than silence.
      place.release();
      lines(nothingToRun(task.name));
    } else {
      await _runMembers(task, resolved, place, outcomes, lines);
    }
    // A composite too: over a generation of several steps, it is the task
    // that holds the set, and its `needs:` are what wrote it.
    _refuseChanged(task, outcomes);
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
    // What each member came to, for the report; null for one never begun.
    final ended = List<Ended?>.filled(resolved.length, null);

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
      var result = Result.passed;
      int? code;
      String? why;
      try {
        if (await _perform(resolved[at], own) == _Ending.stopped) {
          stop = true;
          result = Result.notRun;
          why = _partWay.sentence;
          outcomes.interrupted.add(task.name);
        }
      } on XtaskFormatException catch (thrown) {
        // The file being wrong is not a thing more members can fix, and it
        // ends the run whatever the flags say. Kept rather than raised from
        // inside the wait, so the tally below still counts the siblings.
        stop = true;
        malformed ??= thrown;
        _givenUp.now();
        (result, code, why) = (Result.failed, ExitCode.invalidFile, '$thrown');
      } on Object catch (thrown) {
        if (_signal != null) {
          // A verb that threw once the run was told to stop most likely threw
          // because what it started was stopped under it — the same ending as
          // a process stopped, and not a failure beside the signal.
          own('task `${task.name}`${_at(resolved[at])} was stopped: $thrown');
          stop = true;
          (result, why) = (Result.notRun, _partWay.sentence);
          outcomes.interrupted.add(task.name);
          return;
        }
        // Anything, not only a `RunFailure`: a verb can throw whatever it
        // likes, and the tally must still say what its siblings did.
        final failure = failures[at] = thrown is RunFailure
            ? thrown
            : bodyThrew(task, thrown, member: resolved[at].member);
        (result, code, why) = (Result.failed, failure.code, failure.message);
        if (!keepGoing) {
          stop = true;
          // Said before the place is given back, so that whoever is waiting
          // for it finds the run already over.
          _givenUp.now();
        }
      } finally {
        place.release();
        final took = began == null ? null : now().difference(began);
        if (took != null) {
          work = (
            spent: (work?.spent ?? Duration.zero) + took,
            members: (work?.members ?? 0) + 1,
          );
        }
        ended[at] = Ended(
          resolved[at].member ?? task.name,
          result,
          took: took,
          code: code,
          why: why,
        );
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
    // Every member, the ones never begun too: a report that listed only what
    // ran would read, for a run stopped after two of eight, as a set of two.
    if (task.each != null) {
      outcomes.members[task.name] = [
        for (final (at, member) in ended.indexed)
          member ??
              Ended(
                resolved[at].member ?? task.name,
                Result.notRun,
                why: _notBegun.sentence,
              ),
      ];
    }
    // A task the run gave up on part-way is named, like a task it never
    // reached: two of eight members having run reads exactly like eight.
    if (attempted < resolved.length && failures.isEmpty && malformed == null) {
      outcomes.skipped[task.name] = _signal == null
          ? PartlyRun(attempted: attempted, members: resolved.length)
          : _partWay;
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
    final where = _at(body);

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

    // **Any code, once the run has been told to stop.** The process was
    // asked to, and may have heard it first: a Ctrl-C reaches the terminal's
    // whole foreground group, so a body can end on its own `SIGINT` — at
    // `-2`, `130` or whatever its own handler answers — before the engine's
    // `SIGTERM` is sent. Read as a failure, every Ctrl-C would print one red
    // line per body for a run that broke nothing.
    if (_signal case (:final name, number: _)) {
      lines('task `${task.name}`$where was stopped: the run received $name');
      return _Ending.stopped;
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
        return _runVerb(body, implementation, lines);

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
          // A failure stops only what said it may be stopped; a signal stops
          // everything, and gives the run up too, so an `interruptible:` task
          // hears of it through the first.
          until: body.task.interruptible
              ? _givenUp.reached
              : interruption?.reached,
          // A child writes to the terminal itself only where nothing between
          // it and the terminal is collecting.
          output: lines.live ? null : lines.call,
        );
    }
  }

  /// A verb, handed the context the engine owes it, with its [VerbContext.out]
  /// flushed however it ends — and before anything else reaches the log.
  ///
  /// **Before, as well as after.** A partial line held in `out` belongs ahead
  /// of whatever is written next: a `log` line, or the output of a program
  /// the verb starts. Flushed only at the end, `out.write('building… ')`
  /// followed by `run(...)` printed the program's output first and the
  /// sentence introducing it last.
  Future<int> _runVerb(ResolvedVerb body, Verb implementation, _Lines lines) {
    final out = LogSink(lines.call);
    void log(String line) {
      out.flush();
      lines(line);
    }

    // `Future.sync`, so a verb that throws before it returns a future is
    // flushed too.
    return Future.sync(
      () => implementation(
        VerbContext(
          args: body.arguments,
          env: body.environment,
          root: bodies.root,
          workingDirectory: body.workingDirectory,
          log: log,
          out: out,
          member: body.member,
          // The same resolution and the same starter a `run:` body gets, so
          // a verb that runs a program keeps the resolver's answers rather
          // than reaching for `Process.start` and losing them.
          start: (argv, {workingDirectory}) {
            final (:executable, :arguments, :directory, :runInShell) =
                _prepareForVerb(body, argv, workingDirectory);
            out.flush();
            // Not started at all once the run has been told to stop: a verb
            // that runs a program per file would otherwise start each one only
            // to have it stopped at once.
            if (_signal != null) {
              return Future.value(SystemProcessStarter.interrupted);
            }
            return starter.start(
              executable,
              arguments,
              workingDirectory: directory,
              environment: body.environment,
              runInShell: runInShell,
              until: interruption?.reached,
              output: lines.live ? null : lines.call,
            );
          },
          collect: (argv, {workingDirectory, timeout}) {
            final (:executable, :arguments, :directory, :runInShell) =
                _prepareForVerb(body, argv, workingDirectory);
            // No flush: a capture shows nothing, so there is no order to
            // keep, and flushing split `out.write('git is: ')` from the
            // version the verb was about to write after it.
            if (_signal != null) {
              return Future.value(_capturedNothing);
            }
            return starter.capture(
              executable,
              arguments,
              workingDirectory: directory,
              environment: body.environment,
              runInShell: runInShell,
              timeout: timeout,
              until: interruption?.reached,
            );
          },
          // `collect`, shown where `run` shows a program's output — after
          // whatever the verb had half-written, for `start`'s reason.
          relay: (argv, {workingDirectory, timeout}) {
            final (:executable, :arguments, :directory, :runInShell) =
                _prepareForVerb(body, argv, workingDirectory);
            out.flush();
            if (_signal != null) {
              return Future.value(_capturedNothing);
            }
            return starter.capture(
              executable,
              arguments,
              workingDirectory: directory,
              environment: body.environment,
              runInShell: runInShell,
              timeout: timeout,
              until: interruption?.reached,
              echo: lines.call,
            );
          },
          // From the directory a start given the same `workingDirectory:`
          // would use, under the same rules — or the answer is about a
          // different program than the one `run` would start.
          locate: (name, {workingDirectory}) => bodies.resolver.resolve(
            name,
            from: _verbDirectory(body, workingDirectory),
          ),
        ),
      ),
    ).whenComplete(out.flush);
  }

  /// A program a verb asked for, resolved the way a `run:` body is.
  ///
  /// Refused in the same words a `run:` body is refused with — a name nothing
  /// on `PATH` answers to is still code 3, because "the toolchain is not
  /// installed" and "the code is broken" still reach different people. One
  /// place for [VerbContext.run], [VerbContext.capture] and [VerbContext.tee],
  /// so they cannot come to disagree about what may start.
  ({
    String executable,
    List<String> arguments,
    String directory,
    bool runInShell,
  })
  _prepareForVerb(Resolved body, List<String> argv, String? written) {
    if (argv.isEmpty) {
      throw RunFailure(
        ExitCode.invalidFile,
        'verb of task `${body.task.name}` asked to run nothing',
      );
    }
    final directory = _verbDirectory(body, written);
    final executable = bodies.resolver.resolve(argv.first, from: directory);
    if (executable == null) {
      throw RunFailure(
        ExitCode.missingTool,
        'task `${body.task.name}`: '
        '${bodies.resolver.missingToolMessage(argv.first, from: directory)}',
      );
    }
    final arguments = argv.skip(1).toList();
    final runInShell = bodies.resolver.needsShell(executable);
    if (runInShell) {
      refuseShellMetacharacters(body.task.name, executable, arguments);
    }
    return (
      executable: executable,
      arguments: arguments,
      directory: directory,
      runInShell: runInShell,
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

/// What a verb's capture answers once the run has been told to stop: what a
/// capture stopped part-way answers, with nothing captured.
const Captured _capturedNothing = (
  exitCode: SystemProcessStarter.interrupted,
  stdout: '',
  stderr: '',
);

/// ` at `member``, where [body] is a member of an `each:`; nothing otherwise.
String _at(Resolved body) => switch (body.member) {
  final member? => ' at `$member`',
  null => '',
};

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
