/// Walking a plan: what may start, what must not, and how the run ends.
///
/// **The walk, and nothing below it.** What one body comes to is
/// `body_runner.dart`, the members of one task under the budget are
/// `fanout.dart`, and what the tasks of a run share is `budget.dart`. All
/// three were frames of this class, which is why "is more than one thing
/// writing at once" had three answers and why the place a task holds was a
/// flag passed three levels down with a guard at the bottom.
library;

import 'dart:async';

import 'bodies.dart';
import 'body_runner.dart';
import 'budget.dart';
import 'context.dart';
import 'errors.dart';
import 'exit_codes.dart';
import 'fanout.dart';
import 'graph.dart';
import 'markers.dart';
import 'model.dart';
import 'report.dart';

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

  /// What each task comes to. Seven of this constructor's parameters used to
  /// be the ones this module needs to answer that, and they are behind it now.
  final BodyResolver bodies;

  final ProcessStarter starter;

  /// Where reports go. §7.1 wants a task to be a grouped section on a host
  /// that understands grouping, which is only possible if the engine knows
  /// where a task starts and ends — so it writes, rather than letting bodies
  /// print around it.
  final void Function(String line) log;

  /// How this host wants a section of output marked (§7.1).
  ///
  /// **The engine owns the boundaries, which is why they are here.** A task is
  /// a collapsible section only if something knows where it starts and ends,
  /// and the bodies do not: they write to an inherited stdout and know nothing
  /// about each other. Defaulting to [PlainMarkers] rather than detecting is
  /// deliberate — detection is `LogMarkers.forHost`, and a class that reached
  /// for the ambient environment itself could not be tested for either host.
  final LogMarkers markers;

  /// Whether a failure ends the run, or only that task.
  ///
  /// **Off by default, and the argument for it is §8's own.** That section
  /// explains why `--validate` collects every problem rather than throwing at
  /// the first: "a gate that reports one problem per run makes somebody fix,
  /// rerun, fix, rerun", and a gate people stop running is worse than none.
  /// Word for word that is `xtask check` — formatting red, fix, analyser red,
  /// fix, tests red — three rounds where the same reasoning already asked for
  /// one.
  ///
  /// It is not the default, because §5.2 promises the run stops at the first
  /// failure and because on CI reading a broken run to the end costs more than
  /// failing at once. A person fixing things locally wants the whole list; a
  /// pipeline wants the earliest possible red.
  final bool keepGoing;

  /// Whether this run has decided the answer is known.
  final _givenUp = GivenUp();

  /// The named mutexes this run's tasks share.
  final _exclusive = Exclusive();

  /// The run's budget, spent by units of work rather than by tasks.
  late final _slots = Slots(concurrency);

  /// What one body comes to on this machine.
  late final _runner = BodyRunner(
    bodies: bodies,
    starter: starter,
    log: log,
    givenUp: _givenUp,
  );

  /// The members of one task, under the budget above.
  late final _fanout = Fanout(
    runner: _runner,
    slots: _slots,
    log: log,
    now: now,
    keepGoing: keepGoing,
  );

  /// How much work each task's members added up to, where there was more than
  /// one of them.
  ///
  /// **The number `-j` is for.** A task's own row is how long you waited; over
  /// forty packages at four at a time, how much work there WAS is the other
  /// number, and it was nowhere. Filled in from what a fan-out answers with
  /// rather than written into from inside one, which is what let the number
  /// survive a task that failed.
  final _work = <String, ({Duration spent, int members})>{};

  /// How many tasks may be in flight at once. 1 is §5.2's run.
  ///
  /// **This is the one place a documented promise is deliberately broken, and
  /// only when asked.** §5.2 says a task's output passes through as it arrives
  /// and is never buffered to the end, because a long test run has to be
  /// watchable. Two tasks writing to one terminal at once produce a transcript
  /// belonging to neither, and a §7.1 section that folds lines from two tasks
  /// folds nothing — so above 1, each task's output is collected and printed
  /// whole when it finishes. There is no arrangement that keeps both promises;
  /// the choice is sequential and watchable, or parallel and buffered, and
  /// which one is wanted is the caller's to say.
  ///
  /// §4.3's declaration order survives as a preference rather than a
  /// guarantee: it still decides which of the ready tasks starts first, so
  /// cheap gates are begun before slow ones, but nothing makes them finish in
  /// that order.
  final int concurrency;

  /// Where the clock comes from.
  ///
  /// Injected for the ordinary reason: a summary whose numbers are whatever
  /// the machine happened to take is a summary no test can assert. Nothing
  /// here needs a real clock to be right.
  final DateTime Function() now;

  /// Runs every step, and answers with the code §5.3 gives the outcome.
  Future<int> run(Plan plan) async {
    final took = <String, Duration>{};
    final failed = <String, int>{};
    final skipped = <String, Skipped>{};

    // **Asked once, here, and handed down.** Two tasks writing to one terminal
    // is what buffering is for, and a plan of one task cannot have two: asking
    // for `-j` above 1 on a single task would otherwise cost §5.2's live
    // output and buy nothing at all. It is also what the announcement is
    // about, so computing it twice would be two answers to one question.
    //
    // **A fanned-out task is two things in flight too**, and whether a task is
    // one is [Fanout.couldOverlap] — the same question the fan-out itself asks
    // one member count later. This used to spell it out again, so `xtask fmt
    // -j 4` over one `each:` task buffered every member and printed nothing at
    // all until the first ended, with no announcement, because the
    // announcement was the copy that had not been updated.
    final concurrent =
        (concurrency > 1 && plan.steps.length > 1) ||
        plan.steps.any((step) => Fanout.couldOverlap(step.task, concurrency));

    // Before the walk, so it is the first thing on the stream rather than the
    // first thing after a wait it was meant to explain.
    if (concurrent) {
      starting(plan.steps.length, concurrency).forEach(log);
    }

    final began = now();
    final code = await _walk(
      plan,
      took,
      failed,
      skipped,
      concurrent: concurrent,
    );
    timing(
      took,
      now().difference(began),
      _work,
      concurrent: concurrent,
    ).forEach(log);
    // Last, because it is the part somebody has to act on and the terminal
    // scrolls. The timing above is background; this is the work.
    summary(failed, skipped).forEach(log);
    return code;
  }

  /// Walks the plan, starting what is ready and waiting for what is running.
  ///
  /// **One walk, not two.** There used to be a sequential one and a parallel
  /// one, with the same epilogue written twice — and they had drifted: "the
  /// first failure" meant first-by-declaration in one and first-by-completion
  /// in the other, and only the first was pinned by a test. At one task in
  /// flight the two orders are the same order, so the divergence had nowhere
  /// left to live once the loop was one loop.
  ///
  /// A step may begin when everything it waits on has **finished**. The plan's
  /// order decides only which of the ready ones is begun first, so §4.3's
  /// cheap-before-slow survives as a preference rather than a guarantee.
  ///
  /// A failure stops new tasks from being started but does not reach into the
  /// ones already running: killing a task would leave whatever it was half-way
  /// through in whatever state that half is. Under `--keep-going`, nothing is
  /// stopped at all.
  Future<int> _walk(
    Plan plan,
    Map<String, Duration> took,
    Map<String, int> failed,
    Map<String, Skipped> skipped, {
    required bool concurrent,
  }) async {
    final waiting = [...plan.steps];
    final running = <String, Future<void>>{};
    final finished = <String>{};

    // **Buffering is the price of running two at once, so it is paid only
    // then.** At one task in flight §5.2 holds unchanged: the lines go
    // straight out as they arrive, because there is no second task whose
    // output they could be confused with.
    int? answer;

    while (waiting.isNotEmpty || running.isNotEmpty) {
      var began = false;
      for (var at = 0; at < waiting.length; at++) {
        // **Still a gate, and still the same number.** It is what keeps a
        // sequential run sequential: at one task in flight a failure is
        // observed before the next is admitted, which is what "a failure stops
        // what has not started" rests on. What changed is one level down —
        // the budget it names is now spent by UNITS, so `-j 4` over a single
        // fanned-out task admits the one task and lets its members have all
        // four, where before they took turns and the flag did nothing.
        if (running.length >= concurrency) {
          break;
        }
        final step = waiting[at];
        final blocker = _blockedBy(step, {...failed.keys, ...skipped.keys});
        if (blocker != null) {
          // Named, not dropped. A task that silently did not happen is
          // indistinguishable from one that passed, which is the whole failure
          // this tool is about.
          skipped[step.task.name] = blocker;
          waiting.removeAt(at--);
          began = true;
          continue;
        }
        if (answer != null && !keepGoing) {
          // Something has failed and this run is not keeping going: what has
          // not started must not start. What IS running is left alone.
          skipped[step.task.name] = const RunStopped();
          waiting.removeAt(at--);
          began = true;
          continue;
        }
        if (!step.task.needs.every(finished.contains) ||
            (step.continuationOf != null &&
                !finished.contains(step.continuationOf))) {
          continue;
        }
        if (!_exclusive.tryHold(step.task.exclusive)) {
          // Left where it is rather than admitted and blocked: an admitted
          // task holds one of `-j`'s places whether or not it is doing
          // anything, so three tasks sharing a browser at `-j 3` kept every
          // independent task out of the run.
          continue;
        }
        waiting.removeAt(at--);
        began = true;
        final name = step.task.name;
        running[name] =
            _runOne(
              step,
              took,
              failed,
              // **Only where a second TASK could interleave.** The members of
              // one task buffer themselves one level down, so buffering the
              // task as well took §5.2's live output from a one-step plan and
              // bought nothing — the announcement promising output as each
              // member ends while none of it arrived until the task did.
              buffered: concurrent && plan.steps.length > 1,
            ).then((
              code,
            ) {
              // `removeWhere`, not `remove`: the map's values are futures, so
              // `remove` hands one back and dropping it is a discarded future.
              running.removeWhere((running, _) => running == name);
              finished.add(name);
              if (code != null) {
                answer ??= code;
                if (!keepGoing) {
                  // **Reaching into what is running, but only where the file
                  // said it may.** A build killed half-way leaves whatever it
                  // was doing in whatever state that half is; a read-only
                  // check leaves nothing. Sequentially a format failure at
                  // 0.4s meant analyze and test never ran at all; in parallel
                  // they ran to the end anyway, and the machine spent the
                  // whole budget to learn what it knew in a tenth of a second.
                  _givenUp.now();
                }
              }
            });
      }

      if (running.isEmpty && !began) {
        // Nothing running and nothing startable: whatever is left is waiting
        // on something that will never finish.
        for (final step in waiting) {
          skipped[step.task.name] = const NeverStartable();
        }
        waiting.clear();
        break;
      }
      if (running.isNotEmpty) {
        await Future.any(running.values);
      }
    }

    return answer ?? ExitCode.success;
  }

  /// What an exception that is not a [RunFailure] comes to.
  ///
  /// Named rather than swallowed: the type and the message are the whole of
  /// the bug report, and which task was running is the half that says where to
  /// look. Answers 1, because a body that threw is a body that did not do its
  /// job — and code 3 stays reserved for §5.4 having proved a tool absent.
  RunFailure _threw(Task task, Object thrown) => RunFailure(
    ExitCode.taskFailed,
    'task `${task.name}` threw ${thrown.runtimeType}: $thrown. A body that '
    "raises rather than answering is either the project's own verb or a "
    'fault in this engine; either way it is this task that stopped',
  );

  /// One task, timed, and reported where the mode says to report it.
  Future<int?> _runOne(
    PlanStep step,
    Map<String, Duration> took,
    Map<String, int> failed, {
    required bool buffered,
  }) async {
    final lines = buffered ? <String>[] : null;
    final say = lines == null ? log : lines.add;

    // **Waited for, not held.** A task admitted by the walk could still be
    // queued behind another task's members, and that wait was billed to it: a
    // one-second process reported two seconds, and the total — documented as
    // how much WORK there was — double-counted idling. So the clock starts
    // when there is capacity to start.
    //
    // Taken and HANDED ON: the first member runs on this place and gives it
    // back when it ends. Giving it back here instead left the body to queue
    // again behind whoever was already waiting, so the wait this was meant to
    // stop billing was billed anyway — a one-second task reported four. And
    // holding it for the task's whole life, rather than for its first member,
    // is a deadlock two two-member tasks at `-j 2` duly found.
    final lease = await _slots.take();

    // The tokens are already held: the walk took them before admitting this,
    // so waiting for somebody else's browser happens in the queue rather than
    // here, where it would occupy a place and be billed as this task's work.
    final started = now();
    try {
      await _runTask(step.task, lease, lines?.add);
      return null;
    } on Object catch (thrown, stack) {
      // **One clause, because there is one ending.** `on RunFailure` alone
      // left every other exception to leave the process at 255 — a number
      // §5.3 does not have — with the section still open, because only the
      // annotation below emits `::endgroup::`. A verb is arbitrary project
      // Dart (§9) and can throw anything; so, being honest about it, can a
      // fault in this engine. Neither is an exit code, and both are a task
      // that failed.
      if (thrown is XtaskFormatException) {
        // Not this method's to answer. §8's code 2 belongs to the file being
        // wrong, and `cli.dart` is where that sentence is written.
        //
        // Closed on the way past, though. Only `markers.error` below emits
        // `::endgroup::`, so leaving through here left the section open —
        // reintroducing, for one exception type, exactly the failure this
        // block was written to remove.
        markers.close().forEach(say);
        rethrow;
      }
      final failure = thrown is RunFailure ? thrown : _threw(step.task, thrown);
      if (thrown is! RunFailure) {
        // **Into the section, not into the annotation.** A trace is the only
        // thing that locates a fault in this engine, and dropping it left the
        // report the line above claims to be giving with nothing to act on.
        // It does not belong in the `::error::` though: GitHub reads a
        // workflow command to the end of its line, so twenty frames become one
        // escaped line nobody can read. Said first, so it lands inside the
        // fold that `markers.error` is about to close.
        say('$stack');
      }

      // Closes the open section and annotates, in that order and for that
      // reason: an `::error::` inside a group is folded away with it, so the
      // one line somebody needs would be the one they have to expand a
      // section to reach.
      markers.error(failure.message).forEach(say);
      failed[step.task.name] = failure.code;

      if (step.isContinuation) {
        // **Always 4, whatever went wrong inside it.** The distinction the
        // code carries is not what failed but WHERE: the body already
        // succeeded, so the publish happened. Letting a missing tool inside a
        // continuation answer 3 would lose that, and 3 is not a
        // recoverable-in-the-wrong-direction problem.
        say(ExitCode.continuationNotice);
        return ExitCode.continuationFailed;
      }

      // **The first failure's code, however many follow.** A code is §5.3's
      // shortest possible bug report about ONE failure, and a run with three
      // cannot honestly claim to be about all of them — combining them into a
      // worst-of would invent a severity order the section does not have. The
      // summary is where the others are.
      return failure.code;
    } finally {
      // Unconditionally, because the place knows whether a member has already
      // given it back. Nothing may have reached one — a body that could not
      // resolve, or a task with none — and this used to be an `if` over a flag
      // the fan-out cleared four frames down, which is a leak the day somebody
      // adds a return above it.
      lease.release();
      _exclusive.release(step.task.exclusive);
      // In a `finally`, so the task that FAILED is timed too. Where the run
      // spent itself before it broke is most of what somebody wants from a red
      // job.
      took[step.task.name] = now().difference(started);
      // **Printed here, all at once, and this is the whole cost of the mode.**
      // §5.2 wanted these lines as they arrived; two tasks arriving at once
      // would have made a transcript belonging to neither.
      lines?.forEach(log);
    }
  }

  /// What stopped [step] from running, or null if nothing did.
  ///
  /// A task whose requirement failed must not run: its own failure would be a
  /// consequence of the first one, and a `--keep-going` that reported both
  /// would bury the cause in its own noise. Checking the DIRECT `needs:` is
  /// enough because the plan is already in order — anything further back
  /// stopped whatever is between them first.
  Skipped? _blockedBy(PlanStep step, Set<String> stopped) {
    for (final need in step.task.needs) {
      if (stopped.contains(need)) {
        return NeedsStopped(need);
      }
    }
    final origin = step.continuationOf;
    // A publish that failed must not be announced anyway.
    return origin != null && stopped.contains(origin)
        ? FollowsStopped(origin)
        : null;
  }

  Future<void> _runTask(
    Task task,
    Lease lease, [
    void Function(String line)? sink,
  ]) async {
    // **A section per task, opened before anything that can fail inside it.**
    // §7.1 rests on this: a CI job is one invocation, and what keeps that no
    // worse than a step per task is that each task folds and the failing one
    // is annotated. It is closed here on success and by `markers.error` on
    // failure — never twice, which is what the ordering inside
    // [GitHubMarkers.error] is for.
    final say = sink ?? log;
    markers.open(task.name).forEach(say);
    await _runTaskBody(task, lease, sink);
    markers.close().forEach(say);
  }

  /// Resolves [task] and hands its bodies to the fan-out.
  ///
  /// The two things this level still owns are the two that are about the task
  /// rather than about its members: whether there is anything to run at all,
  /// and how much work the members turned out to be.
  Future<void> _runTaskBody(
    Task task,
    Lease lease,
    void Function(String line)? sink,
  ) async {
    // Every way this task could turn out to be unrunnable is answered by one
    // call, and answered the same way `--dry-run` is answered — because it is
    // the same call.
    final resolved = bodies.resolveTask(task);
    if (resolved.isEmpty) {
      // A pure composite. Its `needs:` have already run; there is nothing of
      // its own to do, and saying so is more useful than silence.
      (sink ?? log)('${task.name}: nothing of its own to run');
      return;
    }

    final outcome = await _fanout.run(task, resolved, lease: lease, sink: sink);
    // Recorded before anything is raised: the members accounted for their work
    // whether or not one of them failed, and where the run spent itself before
    // it broke is most of what somebody wants from a red job.
    final work = outcome.work;
    if (work != null) {
      _work[task.name] = work;
    }
    final failure = outcome.failure;
    if (failure != null) {
      // Raised here rather than answered with, because `_runOne` is where a
      // failing task becomes a section, an annotation and an exit code — and
      // it is one clause for every way a body can end.
      throw failure;
    }
  }
}
