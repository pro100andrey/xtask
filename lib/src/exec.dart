/// Running the bodies a plan resolved to.
library;

import 'dart:convert';
import 'dart:io';

import 'bodies.dart';
import 'context.dart';
import 'errors.dart';
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
    // for `--parallel` on a single task would otherwise cost §5.2's live
    // output and buy nothing at all. It is also what the announcement is
    // about, so computing it twice would be two answers to one question.
    final concurrent = concurrency > 1 && plan.steps.length > 1;

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
    timing(took, now().difference(began), concurrent: concurrent).forEach(log);
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
        waiting.removeAt(at--);
        began = true;
        final name = step.task.name;
        running[name] = _runOne(step, took, failed, buffered: concurrent).then((
          code,
        ) {
          // `removeWhere`, not `remove`: the map's values are futures, so
          // `remove` hands one back and dropping it is a discarded future.
          running.removeWhere((running, _) => running == name);
          finished.add(name);
          if (code != null) {
            answer ??= code;
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
    final started = now();
    try {
      await _runTask(step.task, lines?.add);
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

  Future<void> _runTask(Task task, [void Function(String line)? sink]) async {
    // **A section per task, opened before anything that can fail inside it.**
    // §7.1 rests on this: a CI job is one invocation, and what keeps that no
    // worse than a step per task is that each task folds and the failing one
    // is annotated. It is closed here on success and by `markers.error` on
    // failure — never twice, which is what the ordering inside
    // [GitHubMarkers.error] is for.
    //
    final say = sink ?? log;
    markers.open(task.name).forEach(say);
    await _runTaskBody(task, sink);
    markers.close().forEach(say);
  }

  Future<void> _runTaskBody(Task task, void Function(String line)? sink) async {
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

    for (final body in bodies) {
      await _runBody(body, sink);
    }
  }

  Future<void> _runBody(
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
          output: sink,
        );
    }
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

    if (timeout == null) {
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
    final finished = await process.exitCode
        .then<int?>((code) => code)
        .timeout(timeout, onTimeout: () => null);
    if (finished != null) {
      await collecting;
      return finished;
    }

    process.kill();
    final stopped = await process.exitCode
        .then<int?>((code) => code)
        .timeout(grace, onTimeout: () => null);
    if (stopped == null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await collecting;
    return timedOut;
  }

  /// What a killed process answers with.
  ///
  /// 124 is what `timeout(1)` uses and what every script that wraps a command
  /// in one already checks for. Borrowing it costs nothing and means a shell
  /// around `xtask` does not have to learn a new number — while §5.3's own
  /// codes are untouched, because the ENGINE still answers 1: a task that hung
  /// is a task that failed, and the same person goes to look.
  static const timedOut = 124;
}
