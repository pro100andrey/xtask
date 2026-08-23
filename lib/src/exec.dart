/// Running the bodies a plan resolved to — §5.2 of `xtask.md`.
library;

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
  });

  /// The absolute path §5.4 resolved the written name to, on this machine.
  final String executable;

  /// Whether starting it means going through `cmd.exe` — true only for a
  /// Windows shim that `CreateProcess` cannot start (§5.4, rule 3).
  final bool runInShell;
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

  final SetExpander _sets;

  /// Runs every step, and answers with the code §5.3 gives the outcome.
  Future<int> run(Plan plan) async {
    for (final step in plan.steps) {
      try {
        await _runTask(step.task);
      } on RunFailure catch (failure) {
        // Closes the open section and annotates, in that order and for that
        // reason: an `::error::` inside a group is folded away with it, so
        // the one line somebody needs would be the one they have to expand a
        // section to reach.
        markers.error(failure.message).forEach(log);
        if (step.isContinuation) {
          // **Always 4, whatever went wrong inside it.** The distinction the
          // code carries is not what failed but WHERE: the body already
          // succeeded, so the publish happened. Letting a missing tool inside
          // a continuation answer 3 would lose that, and 3 is not a
          // recoverable-in-the-wrong-direction problem.
          log(ExitCode.continuationNotice);
          return ExitCode.continuationFailed;
        }
        return failure.code;
      }
    }
    return ExitCode.success;
  }

  Future<void> _runTask(Task task) async {
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
    if (sections) {
      markers.open(task.name).forEach(log);
    }
    await _runTaskBody(task);
    if (sections) {
      markers.close().forEach(log);
    }
  }

  Future<void> _runTaskBody(Task task) async {
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
      log('${task.name}: nothing of its own to run');
      return;
    }

    final members = task.each == null
        ? const <String?>[null]
        : _expand(task, task.each!);

    for (final member in members) {
      await _runBody(task, body, member);
    }
  }

  Future<void> _runBody(Task task, Body body, String? member) async {
    final resolved = _resolve(task, body, member);

    final report = dryRun;
    if (report != null) {
      // Everything above has happened: the set was expanded, the directory
      // worked out, the program found. Everything below has not.
      report(resolved);
      return;
    }

    final code = await _perform(resolved);
    if (code != ExitCode.success) {
      throw RunFailure(
        ExitCode.taskFailed,
        member == null
            ? 'task `${task.name}` failed with exit code $code'
            // Named, because §5.2 says a failure under `each:` stops at that
            // member — and "the tests failed" over six packages is a report
            // that makes somebody run all six again by hand.
            : 'task `${task.name}` failed at `$member` with exit code $code',
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
    final args = List<String>.unmodifiable([
      ...task.args,
      if (task.argvFrom != null) ..._expand(task, task.argvFrom!),
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
        );
    }
  }

  /// Does what [body] resolved to, and answers with its exit code.
  Future<int> _perform(Resolved body) {
    switch (body) {
      case ResolvedVerb(:final implementation):
        return implementation(
          VerbContext(
            args: body.arguments,
            env: body.environment,
            workingDirectory: body.workingDirectory,
            log: log,
          ),
        );

      case ResolvedProcess(:final executable, :final runInShell):
        // The member is named here for the same reason §5.2 names it in a
        // failure: six identical lines from one `each:` over six packages is
        // a log that makes somebody run all six again to find out which.
        final member = body.member;
        log(
          '${body.task.name}${member == null ? '' : ' [$member]'}: '
          '${[executable, ...body.arguments].join(' ')}',
        );
        return starter.start(
          executable,
          body.arguments,
          workingDirectory: body.workingDirectory,
          environment: body.environment,
          runInShell: runInShell,
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
  const SystemProcessStarter();

  @override
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) async {
    // **Flushed before the child starts, not for tidiness.** Dart's `stdout`
    // is asynchronous when it is a pipe, which is what it is on CI — and the
    // child writes to the same descriptor directly. Without this the
    // `::group::` line for a task can arrive after the output it is supposed
    // to be folding, which turns §7.1's readable failure into a jumble
    // exactly where nobody can reproduce it.
    await stdout.flush();

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
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}
