/// Running the bodies a plan resolved to.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bodies.dart';
import 'context.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
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

  /// Completed once the run has decided the answer is known.
  ///
  /// Only tasks the file called `interruptible:` are given it, and only when
  /// the run is not keeping going: with `--keep-going` nothing is stopped at
  /// all, which is the whole of what that flag says.
  final _givenUp = Completer<void>();

  /// The named mutexes this run's tasks share.
  final _exclusive = _Exclusive();

  /// How much work each task's members added up to, where there was more than
  /// one of them.
  ///
  /// **The number `-j` is for.** A task's own row is how long you waited; over
  /// forty packages at four at a time, how much work there WAS is the other
  /// number, and it was nowhere. A field rather than a parameter because it is
  /// state of this run, like the mutexes above, and threading it through four
  /// levels to reach the one place that fills it in would say otherwise.
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
    // **A fanned-out task is two things in flight too.** This asked only
    // whether the PLAN had two steps, so `xtask fmt -j 4` over one `each:`
    // task buffered every member and printed nothing at all until the first
    // ended — with no announcement, because the announcement asked the same
    // question. `each:` is a key, so this needs no filesystem to see it.
    final concurrent =
        concurrency > 1 &&
        (plan.steps.length > 1 ||
            plan.steps.any(
              (step) => step.task.each != null && !step.task.serial,
            ));

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
    final slots = _Slots(concurrency);

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
              slots,
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
                if (!keepGoing && !_givenUp.isCompleted) {
                  // **Reaching into what is running, but only where the file
                  // said it may.** A build killed half-way leaves whatever it
                  // was doing in whatever state that half is; a read-only
                  // check leaves nothing. Sequentially a format failure at
                  // 0.4s meant analyze and test never ran at all; in parallel
                  // they ran to the end anyway, and the machine spent the
                  // whole budget to learn what it knew in a tenth of a second.
                  _givenUp.complete();
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
    Map<String, int> failed,
    _Slots slots, {
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
    // Taken and HANDED ON: the first member runs on this slot and gives it
    // back when it ends. Giving it back here instead left the body to queue
    // again behind whoever was already waiting, so the wait this was meant to
    // stop billing was billed anyway — a one-second task reported four. And
    // holding it for the task's whole life, rather than for its first member,
    // is a deadlock two two-member tasks at `-j 2` duly found.
    await slots.take();
    final inherited = _Inherited();

    // The tokens are already held: the walk took them before admitting this,
    // so waiting for somebody else's browser happens in the queue rather than
    // here, where it would occupy a place and be billed as this task's work.
    final started = now();
    try {
      await _runTask(step.task, slots, inherited, lines?.add);
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
      if (inherited.held) {
        // Nothing reached a member — a body that could not resolve, or a task
        // with none.
        inherited.held = false;
        slots.give();
      }
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
    _Slots slots,
    _Inherited inherited, [
    void Function(String line)? sink,
  ]) async {
    // **A section per task, opened before anything that can fail inside it.**
    // §7.1 rests on this: a CI job is one invocation, and what keeps that no
    // worse than a step per task is that each task folds and the failing one
    // is annotated. It is closed here on success and by `markers.error` on
    // failure — never twice, which is what the ordering inside
    // [GitHubMarkers.error] is for.
    //
    final say = sink ?? log;
    markers.open(task.name).forEach(say);
    await _runTaskBody(task, slots, inherited, sink);
    markers.close().forEach(say);
  }

  Future<void> _runTaskBody(
    Task task,
    _Slots slots,
    _Inherited inherited,
    void Function(String line)? sink,
  ) async {
    // Every way this task could turn out to be unrunnable is answered by one
    // call, and answered the same way `--dry-run` is answered — because it is
    // the same call.
    final bodies = this.bodies.resolveTask(task);
    if (bodies.isEmpty) {
      // A pure composite. Its `needs:` have already run; there is nothing of
      // its own to do, and saying so is more useful than silence.
      (sink ?? log)('${task.name}: nothing of its own to run');
      return;
    }

    // **`--keep-going` reaches members, and members that did not run are
    // said out loud.** Neither was true: the first bad file abandoned the rest
    // silently, so `format` over forty packages reported one unformatted file
    // per run and a person fixed, reran, fixed, reran — the exact loop
    // `--keep-going` exists to end. And a member that never ran read exactly
    // like one that passed, which is the failure this whole tool is about.
    //
    // **A member holds a slot, which is what makes `-j` mean anything here.**
    // The budget used to gate which TASKS were admitted, so `-j 4` over one
    // fanned-out task admitted the task and then ran its forty members in
    // turn — the flag doing nothing on the shape it exists for.
    // Keyed by index, so which failure the run answers with does not depend
    // on which member happened to finish first. `first` used to mean
    // first-by-completion the moment members ran together, and a `do:` verb's
    // code is a deliberate decision — two members answering 2 and 1 made the
    // same command line answer differently run to run.
    final failures = <int, RunFailure>{};
    var attempted = 0;
    var stop = false;
    XtaskFormatException? malformed;

    // Buffering is the price of two things writing at once, and it is paid
    // only then: one member in flight keeps §5.2's live output exactly.
    final together = slots.total > 1 && bodies.length > 1 && !task.serial;

    Future<void> member(int at) async {
      if (stop) {
        return;
      }
      // The slot `_runOne` took for the clock goes to whichever member starts
      // first, and comes back when that member ends — so the task never holds
      // one for longer than a member takes, which is what made two two-member
      // tasks at `-j 2` deadlock when it held one for its whole life.
      final ownsInherited = inherited.held;
      inherited.held = false;
      if (!ownsInherited) {
        await slots.take();
      }
      if (stop) {
        slots.give();
        return;
      }
      final lines = together ? <String>[] : null;
      attempted++;
      // Read only where it is used. `now()` is injected so a summary can be
      // asserted, and a fake clock that advances on every read makes an
      // unused one a number somewhere else.
      final began = bodies.length > 1 ? now() : null;
      try {
        if (await _runBody(bodies[at], lines == null ? sink : lines.add)) {
          // **Stopped, so stop.** Returning normally left the loop with no
          // failure to act on, so every remaining member was started and
          // immediately killed — the opposite of what `interruptible:` is for,
          // which is the first answer at the first answer's price.
          stop = true;
        }
      } on Object catch (thrown) {
        if (thrown is XtaskFormatException) {
          // **Kept, not raised from inside the wait.** `Future.wait`
          // propagates the moment one member throws, so raising here abandoned
          // the tally its siblings had already filled in — the "N of M failed"
          // line `--keep-going` exists to produce. Stopped as well, since the
          // file being wrong is not a thing more members can fix.
          stop = true;
          malformed ??= thrown;
          return;
        }
        // **Anything, not only a `RunFailure`.** A verb is arbitrary project
        // Dart and can throw whatever it likes; catching one type meant a
        // `StateError` from member 2 left through the loop and discarded what
        // member 1 had already told us and the fact that member 3 never ran —
        // the silence this whole change was written to end.
        failures[at] = thrown is RunFailure ? thrown : _threw(task, thrown);
        if (!keepGoing) {
          stop = true;
        }
      } finally {
        slots.give();
        if (began != null) {
          final so = _work[task.name];
          _work[task.name] = (
            spent: (so?.spent ?? Duration.zero) + now().difference(began),
            members: (so?.members ?? 0) + 1,
          );
        }
        lines?.forEach(sink ?? log);
      }
    }

    if (together) {
      await Future.wait([
        for (var at = 0; at < bodies.length; at++) member(at),
      ]);
    } else {
      for (var at = 0; at < bodies.length; at++) {
        await member(at);
      }
    }

    // Raised after the others have reported: §8's code 2 is the file being
    // wrong, which outranks a task that failed, and `cli.dart` is where that
    // sentence is written.
    final wrong = malformed;
    if (wrong != null) {
      throw wrong;
    }

    if (failures.isNotEmpty) {
      final order = failures.keys.toList()..sort();
      final failedMembers = [
        for (final at in order) bodies[at].member ?? task.name,
      ];
      final failure = failures[order.first]!;
      throw RunFailure(
        // **The EARLIEST failing member's code**, by the set's order rather
        // than by which finished first: a run with three failures cannot
        // honestly claim to be about all of them, and an answer that depends
        // on scheduling is not an answer.
        failure.code,
        _tally(failure, bodies.length, failedMembers, attempted),
      );
    }
  }

  /// [failure]'s message, with what happened to the other members after it.
  ///
  /// Says nothing at all when there is one member: "1 of 1 members failed" is
  /// noise around a sentence that was already complete.
  String _tally(
    RunFailure failure,
    int members,
    List<String> failed,
    int attempted,
  ) {
    if (members == 1) {
      return failure.message;
    }
    final named = failed.take(5).map((member) => '`$member`').join(', ');
    final more = failed.length > 5 ? ' and ${failed.length - 5} more' : '';
    final unattempted =
        '${members - attempted} of $members not attempted — '
        '`--keep-going` runs them all';
    return [
      failure.message,
      if (failed.length > 1)
        '${failed.length} of $members members failed: $named$more',
      if (attempted < members) unattempted,
    ].join('\n');
  }

  /// Runs [resolved], and answers whether it was stopped rather than finished.
  Future<bool> _runBody(
    Resolved resolved,
    void Function(String line)? sink,
  ) async {
    final task = resolved.task;
    final member = resolved.member;

    final int code;
    try {
      code = await _perform(resolved, sink);
    } on ProcessException catch (failure) {
      // **Only where "could not be started" is literally true.** A verb is
      // arbitrary project Dart (§9), and one that shells out to `git` on a
      // machine without it raises this too — reported here it would say the
      // task could not be started and then print `do <verb>`, sending
      // whoever reads it to inspect the wrong command entirely. A verb that
      // throws is a verb that threw, and the general handler says so.
      if (resolved is! ResolvedProcess) {
        rethrow;
      }

      // **The one ending that used to escape §5.3 entirely.** `Process.start`
      // throws rather than answering when the working directory does not
      // exist, or when the executable stopped being startable between §5.4
      // resolving it and this line. Nothing anywhere caught it: the run ended
      // on an unhandled exception with exit 255 — a number the table does not
      // have — and because only a `RunFailure` reaches the annotation, the
      // `::group::` opened for this task was never closed. On GitHub the rest
      // of the job then folded into a section belonging to a task that had
      // already died, which is §7.1's readable failure turned inside out.
      //
      // Answers 1, which is where `executables.dart` already places a
      // `ProcessException`: code 3 is §5.4 having PROVED the tool is absent,
      // and a start that failed for some other reason is not that proof.
      final where = member == null ? '' : ' at `$member`';
      throw RunFailure(
        ExitCode.taskFailed,
        [
          'task `${task.name}`$where could not be started: ${failure.message}',
          // The same two lines an ordinary failure carries, and for the same
          // reason: "which directory did it look in" is the whole answer here,
          // and it is the line `describe` prints.
          ...describe(resolved, header: false),
        ].join('\n'),
      );
    }

    if (code != ExitCode.success) {
      // **A killed process is reported as killed, not as "exit code 124".**
      // The number is what a killed process answers with and what a shell
      // wrapping this already checks for, but it is a number nobody reads as
      // "it hung". Recognised rather than proved: a program that genuinely
      // exits 124 while carrying a `timeout:` would be described wrongly, and
      // it would still be the right task on the right line.
      if (code == SystemProcessStarter.interrupted &&
          task.interruptible &&
          _givenUp.isCompleted) {
        // **Not a failure.** It was not allowed to finish, and calling that a
        // failure would put a second red thing beside the one that actually
        // broke — which is the noise `--keep-going` exists to avoid, arriving
        // by the opposite route.
        //
        // Gated on the run having actually given up, and not on the number
        // alone. 130 is what a shell reports for SIGINT and what plenty of
        // programs exit with on their own; reading it as "stopped" wherever
        // the key appeared turned a real failure into a green result nobody
        // checked, which is the thing this tool is against.
        final at = member == null ? '' : ' at `$member`';
        (sink ?? log)(
          'task `${task.name}`$at was stopped: an earlier failure had already '
          'answered the run',
        );
        return true;
      }

      final killed =
          code == SystemProcessStarter.timedOut &&
          resolved is ResolvedProcess &&
          resolved.timeout != null;
      final what = killed
          ? 'did not finish inside its `timeout: ${task.timeout}`, '
                'and was killed'
          : 'failed with exit code $code';

      // **A verb's code is a decision; a process's code is data.** They were
      // the same line and should not have been. A verb is the project's own
      // Dart, written against §5.3 — `remove` answering 2 for a path outside
      // the repository is saying "the FILE is wrong", and flattening that to 1
      // sends whoever reads the exit code looking for a task that ran and
      // failed. An external program has never heard of §5.3: its 2 means
      // whatever its author meant, so the number belongs in the message and
      // the run answers 1.
      //
      // Before this, both were true at once — the message said "exit code 2"
      // and the process answered 1, in the same run, out loud.
      final answers = resolved is ResolvedVerb ? code : ExitCode.taskFailed;

      throw RunFailure(
        answers,
        [
          // The member is named, because §5.2 says a failure under `each:`
          // stops at that member — and "the tests failed" over six packages is
          // a report that makes somebody run all six again by hand.
          if (member == null)
            'task `${task.name}` $what'
          else
            'task `${task.name}` at `$member` $what',
          // **The line that says it broke is the line that reproduces it.**
          // On a host that folds, the failing task's output is collapsed and
          // the annotation is all somebody sees; without the command and the
          // directory, "how do I run this myself" means expanding the fold and
          // hunting upwards for it. Rendered by `describe`, so what a failure
          // reports and what `--dry-run` promised cannot disagree.
          ...describe(resolved, header: false),
        ].join('\n'),
      );
    }
    return false;
  }

  /// A program started on a verb's behalf, resolved the way §5.4 resolves one.
  ///
  /// Refuses in the same words a `run:` body is refused with — a name nothing
  /// on `PATH` answers to is still code 3, because "the toolchain is not
  /// installed" and "the code is broken" still reach different people.
  Future<int> _startForVerb(
    Resolved body,
    List<String> argv,
    String workingDirectory,
    void Function(String line)? sink,
  ) {
    if (argv.isEmpty) {
      throw RunFailure(
        ExitCode.invalidFile,
        'verb of task `${body.task.name}` asked to run nothing',
      );
    }
    final executable = bodies.resolver.resolve(argv.first);
    if (executable == null) {
      throw RunFailure(
        ExitCode.missingTool,
        'task `${body.task.name}`: '
        '${bodies.resolver.missingToolMessage(argv.first)}',
      );
    }
    final arguments = argv.skip(1).toList();
    final runInShell = bodies.resolver.needsShell(executable);
    if (runInShell) {
      // **The same refusal a `run:` body gets.** Computing `runInShell` and
      // not asking this left a verb able to hand `cmd.exe` a metacharacter
      // through a batch shim — the one injection §5.4 rule 3 exists to stop,
      // and the one this very method promises it prevents.
      refuseShellMetacharacters(body.task.name, executable, arguments);
    }
    return starter.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: body.environment,
      runInShell: runInShell,
      output: sink,
    );
  }

  /// Does what [body] resolved to, and answers with its exit code.
  Future<int> _perform(Resolved body, void Function(String line)? sink) {
    final say = sink ?? log;
    switch (body) {
      case ResolvedVerb(:final implementation):
        return implementation(
          VerbContext(
            args: body.arguments,
            env: body.environment,
            workingDirectory: body.workingDirectory,
            log: say,
            member: body.member,
            // The same resolution and the same starter a `run:` body gets, so
            // a verb that runs a program keeps §5.4's answers rather than
            // reaching for `Process.start` and losing them.
            start: (argv, {workingDirectory}) => _startForVerb(
              body,
              argv,
              // Relative to the repository root, as every other path in the
              // file is — `in: packages/a` and this must mean one thing.
              // Against the process's own directory it worked from the root
              // and quietly targeted somewhere else from a subdirectory,
              // which is a supported way to run xtask.
              workingDirectory == null
                  ? body.workingDirectory
                  : p.join(bodies.root, workingDirectory),
              sink,
            ),
          ),
        );

      case ResolvedProcess(
        :final executable,
        :final runInShell,
        :final timeout,
      ):
        // The member is named here for the same reason §5.2 names it in a
        // failure: six identical lines from one `each:` over six packages is
        // a log that makes somebody run all six again to find out which.
        final member = body.member;
        say(
          '${body.task.name}${member == null ? '' : ' [$member]'}: '
          '${[executable, ...body.arguments].join(' ')}',
        );
        return starter.start(
          executable,
          body.arguments,
          workingDirectory: body.workingDirectory,
          environment: body.environment,
          runInShell: runInShell,
          timeout: timeout,
          until: body.task.interruptible ? _givenUp.future : null,
          output: sink,
        );
    }
  }
}

/// Named mutexes, one holder each, for as long as a task runs.
///
/// **What the graph cannot say.** Two tasks with no `needs:` between them are
/// independent as far as the plan is concerned, and may still both bind
/// `:8080` or drive the one browser on the machine. The file names the thing
/// they share; this makes the name mean something.
final class _Exclusive {
  final _held = <String>{};

  /// Takes every name in [tokens], or none of them, and says which.
  ///
  /// **Synchronous, and that is the whole of it.** This was an `await`-ing
  /// acquire called from inside the task's own future, so the walk's admission
  /// pass — which is synchronous — always saw an empty set: three tasks
  /// sharing a browser were all admitted, two of them blocked, and every
  /// independent task stayed out of the run behind them. Deciding at admission
  /// means a task that cannot have its tokens is simply not admitted, and its
  /// place goes to something that can run.
  ///
  /// All or nothing, which also settles the ordering question: two tasks each
  /// holding half of the same pair is how a pair deadlocks, and neither can
  /// hold half of one.
  bool tryHold(List<String> tokens) {
    if (tokens.any(_held.contains)) {
      return false;
    }
    _held.addAll(tokens);
    return true;
  }

  /// Lets go of everything [tryHold] took.
  void release(List<String> tokens) => _held.removeAll(tokens);
}

/// One slot, and whether it is still held.
///
/// **Ownership written down rather than assumed.** `_runOne` takes a slot to
/// start the clock and hands it to the first member; a body that fails to
/// resolve never reaches a member, and the slot leaked — a few of those and
/// the run stops for want of a budget nobody is spending.
final class _Inherited {
  var held = true;
}

/// The concurrency budget, held by whatever is actually running.
///
/// **A unit, not a task, is what occupies a slot.** The limit used to gate
/// which TASKS were admitted, so `-j 4` over one fanned-out task admitted the
/// one task and ran its forty members one after another: the flag did nothing
/// on the shape it exists for. Counting units instead lets a task's members
/// share the budget with other tasks, without the members becoming plan steps
/// — which they must not, because a plan step is what `needs:`, `then:` and a
/// `::group::` are about, and a member is none of those.
///
/// First come, first served, so the plan's cheap-before-slow order survives as
/// the order things are ASKED for.
final class _Slots {
  _Slots(this.total);

  final int total;
  var _taken = 0;
  final _waiting = <Completer<void>>[];

  Future<void> take() {
    if (_taken < total) {
      _taken++;
      return Future.value();
    }
    final wait = Completer<void>();
    _waiting.add(wait);
    return wait.future;
  }

  void give() {
    if (_waiting.isEmpty) {
      _taken--;
      return;
    }
    // Handed straight on rather than released and re-taken: releasing first
    // would let a newcomer overtake whoever has been waiting longest.
    _waiting.removeAt(0).complete();
  }
}

/// The starter that runs real processes.
final class SystemProcessStarter implements ProcessStarter {
  const SystemProcessStarter({this.grace = const Duration(seconds: 5)});

  /// How long a process that has been asked to stop is given to do it.
  ///
  /// A parameter so a test can prove the escalation without waiting out a
  /// realistic one. The default is what a test runner needs to write its
  /// partial output and a compiler to remove a half-written file.
  final Duration grace;

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    Duration? timeout,
    Future<void>? until,
    void Function(String line)? output,
  }) async {
    // One question, asked once: it decides the flush above and the mode below,
    // and two spellings of it are two things that can disagree.
    final inherits = output == null;

    // **Flushed before the child starts, and only when the child inherits.**
    // Dart's `stdout` is asynchronous when it is a pipe, which is what it is
    // on CI, and an inheriting child writes to that same descriptor directly:
    // without this the `::group::` line for a task can arrive after the output
    // it is supposed to be folding, which turns §7.1's readable failure into a
    // jumble exactly where nobody can reproduce it.
    //
    // A piped child never touches this process's stdout, so there is nothing
    // to order against — and flushing anyway is not merely wasted. `flush()`
    // marks the sink bound for as long as it is in flight, so a task ending
    // and writing its buffered block while another task is starting throws
    // `Bad state: StreamSink is bound to a stream` and takes the run with it.
    // Concurrency is the only way to have both at once, and concurrency is
    // exactly when nobody inherits.
    if (inherits) {
      await stdout.flush();
    }

    Future<void>? collecting;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
      // **Streaming, by not being in the way.** §5.2 requires a task's output
      // to pass through as it arrives and never be buffered to the end,
      // because a long test run has to be watchable. Inheriting the streams
      // gives that for nothing: the child writes to this process's own stdout,
      // with no copy, no line buffer and nothing to get the ordering of two
      // streams wrong.
      // **Streaming by not being in the way, unless somebody asked for
      // parallelism.** Inheriting gives §5.2's promise for nothing: the child
      // writes to this process's own stdout, with no copy, no line buffer and
      // nothing to get the ordering of two streams wrong. A parallel run
      // cannot have that — two children writing to one terminal produce a
      // transcript belonging to neither — so it pipes instead, and pays for it
      // by not seeing anything until the task ends.
      mode: inherits ? ProcessStartMode.inheritStdio : ProcessStartMode.normal,
    );

    if (output != null) {
      // Both streams into one buffer, in arrival order, because that is what
      // a terminal would have shown. Kept as futures so the collecting is not
      // waited on before the process is.
      collecting = Future.wait([
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(output),
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(output),
      ]);
    }

    if (timeout == null && until == null) {
      final code = await process.exitCode;
      await collecting;
      return code;
    }

    // **Asked to stop, then made to.** SIGTERM lets a test runner write its
    // partial output and a compiler remove a half-written file; SIGKILL is
    // what happens to a process that ignores being asked. A short grace
    // period between them is the whole difference between a killed run that
    // leaves a corrupt artifact behind and one that does not.
    //
    // What this does NOT do is kill the process's own children. There is no
    // portable way to reach them from here — Windows has job objects, POSIX
    // has process groups, and neither is what `Process` exposes — so a task
    // that spawns a server and hangs may leave the server behind. Stated
    // rather than quietly hoped away.
    // Whichever comes first: the process ending, its deadline, or the run
    // deciding it no longer needs this. The last two end the same way, because
    // a process being stopped does not care why.
    // **Which branch won is read when it wins, not after the kill.** Setting a
    // flag from inside the losing callback let a task that genuinely ran past
    // its `timeout:` be relabelled a stop, if the run happened to give up
    // during the grace period — and a relabelled stop is not reported at all.
    int? alreadyFinished;
    final ending = process.exitCode.then<int?>((code) {
      alreadyFinished = code;
      return code;
    });
    final outcome = await Future.any([
      if (timeout == null)
        ending.then((code) => (code: code, stopped: false))
      else
        ending
            .timeout(timeout, onTimeout: () => null)
            .then((code) => (code: code, stopped: false)),
      if (until != null) until.then((_) => (code: null as int?, stopped: true)),
    ]);
    if (outcome.code != null) {
      await collecting;
      return outcome.code!;
    }
    // **A process that has already finished was not stopped.** The two futures
    // can complete in the same turn, and `Future.any` picking the other one
    // threw away a real exit code and called a dead process killed.
    final finishedAnyway = alreadyFinished;
    if (finishedAnyway != null) {
      await collecting;
      return finishedAnyway;
    }
    final stoppedEarly = outcome.stopped;

    process.kill();
    final stopped = await process.exitCode
        .then<int?>((code) => code)
        .timeout(grace, onTimeout: () => null);
    if (stopped == null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    // **Bounded, because the pipes may outlive the process.** Collecting ends
    // when stdout and stderr close, and a grandchild that inherited them keeps
    // them open — `sh -c 'sleep 12'` killed at 0.0s still took twelve seconds
    // to report, which is `interruptible:` giving back exactly nothing and
    // billing the wait as the task's own work. The same grace as the kill: a
    // moment for what was already written, and no longer.
    await collecting?.timeout(grace, onTimeout: () => const <void>[]);
    return stoppedEarly ? interrupted : timedOut;
  }

  /// What a killed process answers with.
  ///
  /// 124 is what `timeout(1)` uses and what every script that wraps a command
  /// in one already checks for. Borrowing it costs nothing and means a shell
  /// around `xtask` does not have to learn a new number — while §5.3's own
  /// codes are untouched, because the ENGINE still answers 1: a task that hung
  /// is a task that failed, and the same person goes to look.
  static const timedOut = 124;

  /// What a process stopped because the run gave up answers with.
  ///
  /// 130 is what a shell reports for SIGINT, and this is the same event by a
  /// different route: somebody — here, an earlier failure — decided the answer
  /// was already known. Distinct from [timedOut] so a report can say which
  /// happened, and never surfaced as a task failure: a task that was stopped
  /// did not fail, it was not allowed to finish.
  static const interrupted = 130;
}
