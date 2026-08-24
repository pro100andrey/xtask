/// Running the bodies a plan resolved to — §5.2 of `xtask.md`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'errors.dart';
import 'exit_codes.dart';
import 'graph.dart';
import 'model.dart';
import 'reporting.dart';
import 'resolve.dart';
import 'sets.dart';

/// Why a run stopped, when it stopped.
final class RunFailure implements Exception {
  const RunFailure(this.code, this.message);

  /// One of [ExitCode]'s.
  final int code;

  /// What to print. Names the task, and under `each:` the member.
  final String message;

  @override
  String toString() => message;
}

/// A body with everything about it decided — §7's *resolved* plan.
///
/// **What `--dry-run` prints and what a run performs, worked out once.**
/// Turning a task into a command is most of the engine: the set expanded, the
/// member `$each` stands for, the directory it lands in, the environment it
/// sees, and the executable §5.4 finds on this machine. A dry run that worked
/// that out a second time would be a second answer to "what will happen" — the
/// two would agree until the day one of them was changed, which is §1's first
/// defect written by the tool that exists to remove it.
///
/// So there is one walk, in [Executor], with two endings.
sealed class Resolved {
  const Resolved({
    required this.task,
    required this.member,
    required this.workingDirectory,
    required this.environment,
    required this.arguments,
  });

  /// The task this body belongs to.
  final Task task;

  /// The member of `each:` this body is for, or null when there is no `each:`.
  ///
  /// A task with `each:` resolves to one of these per member, which is why the
  /// member is here and not only in the failure message.
  final String? member;

  /// Where the body runs — absolute, already resolved against the repository
  /// root, with `$each` substituted.
  final String workingDirectory;

  /// The ambient environment with the task's `env:` applied: what the body
  /// actually sees, rather than what the file adds.
  final Map<String, String> environment;

  /// Everything after the program name: for a `run:` body the rest of its
  /// `argv`, then `args:`, then the expanded `argv-from` set.
  final List<String> arguments;
}

/// A `run:` body, with the program found and Windows' shell question answered.
final class ResolvedProcess extends Resolved {
  const ResolvedProcess({
    required super.task,
    required super.member,
    required super.workingDirectory,
    required super.environment,
    required super.arguments,
    required this.executable,
    required this.runInShell,
    this.timeout,
  });

  /// The absolute path §5.4 resolved the written name to, on this machine.
  final String executable;

  /// Whether starting it means going through `cmd.exe` — true only for a
  /// Windows shim that `CreateProcess` cannot start (§5.4, rule 3).
  final bool runInShell;

  /// How long it may take, or null for no limit — §4.3's `timeout:`.
  ///
  /// Under `each:` this is a limit **per member**: six packages with a limit
  /// of five minutes is thirty minutes of patience, not five, because the
  /// question the key answers is whether one of them has hung.
  final Duration? timeout;
}

/// A `do:` body, with the verb the project registered found.
final class ResolvedVerb extends Resolved {
  const ResolvedVerb({
    required super.task,
    required super.member,
    required super.workingDirectory,
    required super.environment,
    required super.arguments,
    required this.verb,
    required this.implementation,
  });

  /// The name written in the file.
  final String verb;

  /// The function it names — looked up while resolving, and **not called**
  /// there, which is what lets a dry run report a `do:` task without running
  /// arbitrary Dart.
  final Verb implementation;
}

/// Runs a [Plan], in order, stopping at the first failure.
final class Executor {
  Executor({
    required this.file,
    required this.root,
    required this.resolver,
    required this.starter,
    required this.log,
    this.verbs = const {},
    this.environment = const {},
    this.dryRun,
    this.markers = const PlainMarkers(),
    this.now = DateTime.now,
    this.passedThrough,
    this.keepGoing = false,
    this.concurrency = 1,
  }) : _sets = SetExpander(root: root);

  final XtaskFile file;

  /// The repository root. Every working directory is resolved against it.
  final String root;

  final ExecutableResolver resolver;
  final ProcessStarter starter;

  /// Where reports go. §7.1 wants a task to be a grouped section on a host
  /// that understands grouping, which is only possible if the engine knows
  /// where a task starts and ends — so it writes, rather than letting bodies
  /// print around it.
  final void Function(String line) log;

  /// What the project registered (§9). The engine ships none of its own except
  /// the primitives of §6.
  final Map<String, Verb> verbs;

  /// The ambient environment a task's `env:` is added to, and the one
  /// `env-required` is checked against.
  final Map<String, String> environment;

  /// When set, every body is resolved exactly as a run resolves it and then
  /// handed here **instead of being performed** — `--dry-run` of §7.
  ///
  /// A callback rather than a flag because deciding what a body comes to is
  /// this class's business and printing it is not. What it must not be is a
  /// second walk over the file: see [Resolved].
  final void Function(Resolved body)? dryRun;

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

  /// What followed `--` on the command line, and the one task it is for.
  ///
  /// **One task, not the plan.** `xtask check -- --name x` names the composite;
  /// handing `--name x` to every member would give it to the formatter and the
  /// analyser as well, which is not what anybody typed. So the entry point is
  /// carried with the arguments and compared by name — a task pulled in
  /// through `needs:` gets what the file says it gets and nothing else.
  ///
  /// They land **after** `args:` and the expanded `argv-from`, where a command
  /// line belongs: last, and therefore able to add to what the file already
  /// said rather than being buried in front of it.
  final ({String task, List<String> arguments})? passedThrough;

  /// Where the clock comes from.
  ///
  /// Injected for the ordinary reason: a summary whose numbers are whatever
  /// the machine happened to take is a summary no test can assert. Nothing
  /// here needs a real clock to be right.
  final DateTime Function() now;

  final SetExpander _sets;

  /// Runs every step, and answers with the code §5.3 gives the outcome.
  Future<int> run(Plan plan) async {
    final took = <String, Duration>{};
    final failed = <String, int>{};
    final skipped = <String, String>{};

    final began = now();
    final code = await _walk(plan, took, failed, skipped);
    if (dryRun == null) {
      _reportTiming(took, now().difference(began));
      // Last, because it is the part somebody has to act on and the terminal
      // scrolls. The timing above is background; this is the work.
      _reportStopped(failed, skipped);
    }
    return code;
  }

  Future<int> _walk(
    Plan plan,
    Map<String, Duration> took,
    Map<String, int> failed,
    Map<String, String> skipped,
  ) async {
    if (concurrency > 1 && dryRun == null) {
      return _walkTogether(plan, took, failed, skipped);
    }

    int? answer;

    for (final step in plan.steps) {
      final blocker = _blockedBy(step, {...failed.keys, ...skipped.keys});
      if (blocker != null) {
        // Named, not dropped. A task that silently did not happen is
        // indistinguishable from one that passed, which is the whole failure
        // this tool is about.
        skipped[step.task.name] = blocker;
        continue;
      }

      final started = now();
      try {
        await _runTask(step.task);
      } on RunFailure catch (failure) {
        // Closes the open section and annotates, in that order and for that
        // reason: an `::error::` inside a group is folded away with it, so
        // the one line somebody needs would be the one they have to expand a
        // section to reach.
        markers.error(failure.message).forEach(log);
        failed[step.task.name] = failure.code;

        if (step.isContinuation) {
          // **Always 4, whatever went wrong inside it.** The distinction the
          // code carries is not what failed but WHERE: the body already
          // succeeded, so the publish happened. Letting a missing tool inside
          // a continuation answer 3 would lose that, and 3 is not a
          // recoverable-in-the-wrong-direction problem.
          log(ExitCode.continuationNotice);
        }

        // **The first failure's code, however many follow.** A code is §5.3's
        // shortest possible bug report about ONE failure, and a run with three
        // cannot honestly claim to be about all of them — combining them into
        // a worst-of would invent a severity order the section does not have.
        // The summary below is where the others are.
        answer ??= step.isContinuation
            ? ExitCode.continuationFailed
            : failure.code;

        if (!keepGoing) {
          return answer;
        }
      } finally {
        // In a `finally`, so the task that FAILED is timed too. Where the run
        // spent itself before it broke is most of what somebody wants from a
        // red job.
        took[step.task.name] = now().difference(started);
      }
    }

    return answer ?? ExitCode.success;
  }

  /// The same walk with more than one task in flight — `--parallel`.
  ///
  /// A step may begin when everything it waits on has **finished**, which is
  /// what `_blockedBy` already decides; the plan's order decides only which of
  /// the ready ones is begun first, so §4.3's cheap-before-slow survives as a
  /// preference. Each task collects its own output and prints it whole, under
  /// its own section, when it ends — the price §5.2 is charged for this, and
  /// the reason it is not the default.
  ///
  /// A failure stops new tasks from being started, exactly as it does
  /// sequentially, but does not reach into the ones already running: killing
  /// them would leave whatever they were half-way through in whatever state
  /// that half is. Under `--keep-going`, nothing is stopped at all.
  Future<int> _walkTogether(
    Plan plan,
    Map<String, Duration> took,
    Map<String, int> failed,
    Map<String, String> skipped,
  ) async {
    final waiting = [...plan.steps];
    final running = <String, Future<void>>{};
    final finished = <String>{};
    int? answer;

    while (waiting.isNotEmpty || running.isNotEmpty) {
      var began = false;
      for (var at = 0; at < waiting.length; at++) {
        if (running.length >= concurrency) {
          break;
        }
        final step = waiting[at];
        final stopped = {...failed.keys, ...skipped.keys};
        final blocker = _blockedBy(step, stopped);
        if (blocker != null) {
          skipped[step.task.name] = blocker;
          waiting.removeAt(at--);
          began = true;
          continue;
        }
        if (answer != null && !keepGoing) {
          // Something has failed and this run is not keeping going: what has
          // not started must not start. What IS running is left alone.
          skipped[step.task.name] = 'a failure elsewhere';
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
        running[name] = _runOne(step, took, failed).then((code) {
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
        // on something that will never finish. `_blockedBy` names it on the
        // next turn of the loop, so this cannot spin.
        for (final step in waiting) {
          skipped[step.task.name] = 'something it needs never ran';
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

  /// One task, with its own buffer, reported whole when it ends.
  Future<int?> _runOne(
    PlanStep step,
    Map<String, Duration> took,
    Map<String, int> failed,
  ) async {
    final lines = <String>[];
    final started = now();
    try {
      await _runTask(step.task, lines.add);
      return null;
    } on RunFailure catch (failure) {
      failed[step.task.name] = failure.code;
      markers.error(failure.message).forEach(lines.add);
      if (step.isContinuation) {
        lines.add(ExitCode.continuationNotice);
        return ExitCode.continuationFailed;
      }
      return failure.code;
    } finally {
      took[step.task.name] = now().difference(started);
      // **Printed here, all at once, and this is the whole cost of the mode.**
      // §5.2 wanted these lines as they arrived; two tasks arriving at once
      // would have made a transcript belonging to neither.
      lines.forEach(log);
    }
  }

  /// What stopped [step] from running, or null if nothing did.
  ///
  /// A task whose requirement failed must not run: its own failure would be a
  /// consequence of the first one, and a `--keep-going` that reported both
  /// would bury the cause in its own noise. Checking the DIRECT `needs:` is
  /// enough because the plan is already in order — anything further back
  /// stopped whatever is between them first.
  String? _blockedBy(PlanStep step, Set<String> stopped) {
    for (final need in step.task.needs) {
      if (stopped.contains(need)) {
        return need;
      }
    }
    final origin = step.continuationOf;
    // A publish that failed must not be announced anyway.
    return origin != null && stopped.contains(origin) ? origin : null;
  }

  /// Everything that failed and everything that therefore did not run.
  ///
  /// Printed only when there is more than one thing to say. One failure has
  /// already been reported where it happened, and repeating it under a heading
  /// is a summary that summarises nothing.
  void _reportStopped(Map<String, int> failed, Map<String, String> skipped) {
    if (failed.length + skipped.length < 2) {
      return;
    }
    log('');
    failed.forEach((name, code) => log('failed   $name (exit $code)'));
    skipped.forEach(
      (name, blocker) => log('skipped  $name (needs $blocker)'),
    );
  }

  /// What each task took, after the last one, outside every section.
  ///
  /// **Outside, and that is the whole design of it.** §7.1 has a CI job run
  /// one invocation, so the job's own duration is the duration of everything —
  /// and "which task took four minutes" has no answer anywhere. The obvious
  /// place to print it, beside the task, is the wrong one: a line inside a
  /// `::group::` is folded away with it, and the moment somebody wants a
  /// duration is exactly the moment they have not expanded anything.
  void _reportTiming(Map<String, Duration> took, Duration wall) {
    if (took.isEmpty) {
      return;
    }
    const total = 'total';
    // A total under one number is that number written twice, so a single task
    // gets none — and then the column must not be widened for a word that is
    // not going to be printed.
    final sums = took.length > 1;
    final width = took.keys.fold(
      sums ? total.length : 0,
      (w, n) => n.length > w ? n.length : w,
    );
    final numbers = [
      ...took.values.map(_asTime),
      if (sums) _asTime(took.values.reduce((a, b) => a + b)),
    ];
    final column = numbers.fold(0, (w, n) => n.length > w ? n.length : w);

    log('');
    var index = 0;
    took.forEach((name, _) {
      log('${name.padRight(width)}  ${numbers[index++].padLeft(column)}');
    });
    if (!sums) {
      return;
    }
    // **Two numbers, and only where they differ.** Sequentially the sum of the
    // tasks IS how long the run took. Run together they are different
    // questions — how much work there was, and how long you waited — and
    // printing only the first would report three minutes for a run that took
    // one.
    final spent = '${total.padRight(width)}  ${numbers.last.padLeft(column)}';
    log(concurrency > 1 ? '$spent spent, ${_asTime(wall)} taken' : spent);
  }

  /// A duration a person reads, not one a machine parses.
  static String _asTime(Duration took) {
    if (took.inMinutes < 1) {
      return '${(took.inMilliseconds / 1000).toStringAsFixed(1)}s';
    }
    final seconds = (took.inSeconds % 60).toString().padLeft(2, '0');
    return '${took.inMinutes}m ${seconds}s';
  }

  Future<void> _runTask(Task task, [void Function(String line)? sink]) async {
    // **A section per task, opened before anything that can fail inside it.**
    // §7.1 rests on this: a CI job is one invocation, and what keeps that no
    // worse than a step per task is that each task folds and the failing one
    // is annotated. It is closed here on success and by `markers.error` on
    // failure — never twice, which is what the ordering inside
    // [GitHubMarkers.error] is for.
    //
    // A dry run has no sections. It performs nothing, so there is no output
    // to fold, and its own report is already the plan.
    final sections = dryRun == null;
    final say = sink ?? log;
    if (sections) {
      markers.open(task.name).forEach(say);
    }
    await _runTaskBody(task, sink);
    if (sections) {
      markers.close().forEach(say);
    }
  }

  Future<void> _runTaskBody(Task task, void Function(String line)? sink) async {
    // Before the body, and that is the whole value of the key: it turns "a
    // browser test failed somewhere inside" into "task `web-e2e` requires
    // CHROMEDRIVER, which is not set" (§7.1). The engine installs nothing.
    for (final name in task.envRequired) {
      final value = environment[name];
      if (value == null || value.isEmpty) {
        throw RunFailure(
          ExitCode.taskFailed,
          'task `${task.name}` requires the environment variable `$name`, '
          'which is not set. xtask does not install anything: whatever '
          'provides it — a CI step, a shell profile — has to run first',
        );
      }
    }

    final body = task.body;
    if (body == null) {
      // A pure composite. Its `needs:` have already run; there is nothing of
      // its own to do, and saying so is more useful than silence.
      (sink ?? log)('${task.name}: nothing of its own to run');
      return;
    }

    final members = task.each == null
        ? const <String?>[null]
        : _expand(task, task.each!);

    for (final member in members) {
      await _runBody(task, body, member, sink);
    }
  }

  Future<void> _runBody(
    Task task,
    Body body,
    String? member,
    void Function(String line)? sink,
  ) async {
    final resolved = _resolve(task, body, member);

    final report = dryRun;
    if (report != null) {
      // Everything above has happened: the set was expanded, the directory
      // worked out, the program found. Everything below has not.
      report(resolved);
      return;
    }

    final code = await _perform(resolved, sink);
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

      throw RunFailure(
        ExitCode.taskFailed,
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
          ...describe(resolved).skip(1),
        ].join('\n'),
      );
    }
  }

  /// What [body] comes to on this machine, for this member.
  ///
  /// Every way a task can turn out to be unrunnable is found here rather than
  /// on the way in or half-way through: an unknown verb, a set that does not
  /// exist, `in: $each` without an `each:`, a program nothing on `PATH`
  /// answers to. That is what makes `--dry-run` worth reading — it fails
  /// exactly where the run would, with the same message and the same exit
  /// code.
  Resolved _resolve(Task task, Body body, String? member) {
    final where = _workingDirectory(task, member);
    final passed = passedThrough;
    final args = List<String>.unmodifiable([
      ...task.args,
      if (task.argvFrom != null) ..._expand(task, task.argvFrom!),
      if (passed != null && passed.task == task.name) ...passed.arguments,
    ]);
    final env = Map<String, String>.unmodifiable({
      ...environment,
      ...task.env,
    });

    switch (body) {
      case DoBody(:final verb):
        final implementation = verbs[verb];
        if (implementation == null) {
          throw RunFailure(
            ExitCode.invalidFile,
            'task `${task.name}` names the verb `$verb`, which this project '
            'has not registered. The engine ships no project verbs (§9): a '
            'verb is a Dart function the project hands to `runXtask`',
          );
        }
        return ResolvedVerb(
          task: task,
          member: member,
          workingDirectory: where,
          environment: env,
          arguments: args,
          verb: verb,
          implementation: implementation,
        );

      case RunBody(:final argv):
        final executable = resolver.resolve(argv.first);
        if (executable == null) {
          throw RunFailure(
            ExitCode.missingTool,
            'task `${task.name}`: ${resolver.missingToolMessage(argv.first)}',
          );
        }
        final arguments = List<String>.unmodifiable([...argv.skip(1), ...args]);
        final runInShell = resolver.needsShell(executable);
        if (runInShell) {
          _refuseShellMetacharacters(task, executable, arguments);
        }
        return ResolvedProcess(
          task: task,
          member: member,
          workingDirectory: where,
          environment: env,
          arguments: arguments,
          executable: executable,
          runInShell: runInShell,
          timeout: task.timeout == null
              ? null
              : Duration(seconds: task.timeout!),
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

  /// Characters `cmd.exe` acts on rather than passes along.
  static const _cmdMetacharacters = {'&', '|', '<', '>', '^', '(', ')', '"'};

  /// Refuses an argument the shell would reinterpret, when the shell is
  /// unavoidable — §5.4, rule 3.
  ///
  /// A batch shim cannot be started by `CreateProcess`, so its arguments are
  /// parsed by `cmd.exe` whatever the caller intended, and Dart's own
  /// documentation says so. That leaves two ways to be wrong and one to be
  /// honest:
  ///
  /// - quote for `cmd.exe` here **and** let `Process.start` quote for
  ///   `CreateProcess` as well, which is two layers of quoting nobody can
  ///   verify from a machine that is not Windows;
  /// - pass them through and let `&` end the command and start another one,
  ///   silently, which is the worst outcome available;
  /// - refuse, name the character, and say what it would have done.
  ///
  /// This takes the third. It costs a task that genuinely wants `&` in an
  /// argument to a `.bat` — which it can have by pointing at a `.exe`, or by
  /// making the job a verb, where R1 says logic belongs anyway. It is a
  /// **stated** limit rather than an untested claim of correctness, and it
  /// stops being needed the day this runs on a Windows CI machine that can
  /// prove an escaping pass right.
  void _refuseShellMetacharacters(
    Task task,
    String executable,
    List<String> arguments,
  ) {
    for (final argument in arguments) {
      for (final character in _cmdMetacharacters) {
        if (!argument.contains(character)) {
          continue;
        }
        throw RunFailure(
          ExitCode.invalidFile,
          'task `${task.name}` passes `$argument` to `$executable`, which is '
          'a batch file. Windows starts one through the shell whatever the '
          'caller asks for, so `$character` in that argument would be read as '
          'a shell operator rather than as text. Point the task at a real '
          'executable, or make it a verb (§9) — R1 puts logic there anyway',
        );
      }
    }
  }

  /// Where a body runs. `$each` is the member; anything else is relative to
  /// the repository root (§4.3).
  String _workingDirectory(Task task, String? member) {
    final written = task.workingDirectory;
    if (written == null) {
      return root;
    }
    if (written == r'$each') {
      if (member == null) {
        throw RunFailure(
          ExitCode.invalidFile,
          'task `${task.name}` uses `in: \$each` without an `each:` set, so '
          'there is no member for it to stand for',
        );
      }
      return p.join(root, member);
    }
    return p.join(root, written);
  }

  /// The members of set [name], as a failure of [task] when there are none.
  ///
  /// **Rewrapped rather than let through.** A set that expands to nothing is
  /// an [XtaskFormatException] — the right type for `--validate`, which is
  /// where §4.2 expects it to be caught. Reaching a RUN, it used to escape
  /// `run` altogether: past the exit code, and past the section markers, so a
  /// group opened for the task was never closed and everything after it on
  /// GitHub was folded into a task that had already stopped.
  List<String> _expand(Task task, String name) {
    try {
      return _sets.expand(name, _set(task, name));
    } on XtaskFormatException catch (problem) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` cannot run:\n$problem',
      );
    }
  }

  NamedSet _set(Task task, String name) {
    final set = file.sets[name];
    if (set == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` names the set `$name`, which does not exist',
      );
    }
    return set;
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
    // **Flushed before the child starts, not for tidiness.** Dart's `stdout`
    // is asynchronous when it is a pipe, which is what it is on CI — and the
    // child writes to the same descriptor directly. Without this the
    // `::group::` line for a task can arrive after the output it is supposed
    // to be folding, which turns §7.1's readable failure into a jumble
    // exactly where nobody can reproduce it.
    await stdout.flush();

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
      mode: output == null
          ? ProcessStartMode.inheritStdio
          : ProcessStartMode.normal,
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

/// How a [Resolved] body is written down: what runs, where, and with what.
///
/// **Here rather than beside `--dry-run`, because two callers need it.** It
/// is what `--dry-run` prints, and it is what a failure prints so that the
/// line saying a task failed is also the line that reproduces it. Two
/// renderings of one value would drift, and the drift would show up as a
/// dry run promising a command a failure then reports differently.
///
/// §13 keeps output *formats* out of this milestone — there is no `--json` and
/// no key to choose one. This is the one human-readable form, and the thing it
/// has to get right is that a person can check it against what they meant.
List<String> describe(Resolved body) {
  final member = body.member;
  return [
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
    for (final variable in body.task.env.entries)
      '  env  ${variable.key}=${_quoted(variable.value)}',
    if (body case ResolvedProcess(timeout: final limit?))
      '  for  at most ${limit.inSeconds}s, then it is killed',
    if (body case ResolvedProcess(runInShell: true))
      '  via  cmd.exe, which is the only way to start a batch file (§5.4)',
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
