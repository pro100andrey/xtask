/// Doing what one resolved body resolved to, and reading how it ended.
///
/// **The mirror of `bodies.dart`, which had no name.** That module turns a
/// task into a [Resolved] — the set expanded, the member `$each` stands for,
/// the program §5.4 found — and is a module for it, with an interface and a
/// test surface of its own. Turning that value back into an outcome was three
/// private methods on the executor, reachable only through a plan and a YAML
/// document, and it is where the hardest sentences of §5.3 live: a killed
/// process reported as killed rather than as exit 124, a 130 read as a stop
/// only where the run actually gave up, a verb's exit code kept as a decision
/// while a program's becomes data, and `ProcessException` translated only
/// where "could not be started" is literally true.
///
/// Resolve, then run. One value crosses between them, and a dry run is what
/// happens when only the first half is asked for.
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
import 'model.dart';
import 'process.dart';
import 'report.dart';

/// What an exception that is not a [RunFailure] comes to.
///
/// Named rather than swallowed: the type and the message are the whole of the
/// bug report, and which task was running is the half that says where to look.
/// Answers 1, because a body that threw is a body that did not do its job —
/// and code 3 stays reserved for §5.4 having proved a tool absent.
RunFailure bodyThrew(Task task, Object thrown) => RunFailure(
  ExitCode.taskFailed,
  'task `${task.name}` threw ${thrown.runtimeType}: $thrown. A body that '
  "raises rather than answering is either the project's own verb or a "
  'fault in this engine; either way it is this task that stopped',
);

/// Performing a [Resolved], on this machine, for this run.
///
/// One method in the interface. Everything a body can turn into — an exit
/// code, a kill, a stop, a `ProcessException`, a verb that threw — is behind
/// it, and the run above only has to know whether the body finished or was
/// stopped.
final class BodyRunner {
  const BodyRunner({
    required this.bodies,
    required this.starter,
    required this.log,
    required this.givenUp,
  });

  /// What resolved the bodies — the source of §5.4's answers for a verb that
  /// starts a program of its own.
  final BodyResolver bodies;

  final ProcessStarter starter;

  /// Where a body's own lines go when nothing is collecting them.
  final void Function(String line) log;

  /// Whether the run has given up, and a way to be told when it does.
  final GivenUp givenUp;

  Future<bool> run(
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
          givenUp.already) {
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
    String? written,
    void Function(String line)? sink,
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

  /// Where a verb's own process starts, refusing what the root does not own.
  ///
  /// Relative to the repository root, as every other path in the file is —
  /// `in: packages/a` and this must mean one thing. Against the process's own
  /// directory it worked from the root and quietly targeted somewhere else
  /// from a subdirectory, which is a supported way to run xtask.
  ///
  /// **And asked the boundary, which is the half that was missing.** Joining
  /// onto the root is not a fence: `p.join` walks straight up a `..`, so a
  /// verb could start a child anywhere on the machine and the run answered 0.
  /// Code 2 rather than 1, for the reason `remove` answers 2 on the same
  /// question — a path outside the repository is the project being wrong
  /// about what it owns, not a task that ran and failed.
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
            start: (argv, {workingDirectory}) =>
                _startForVerb(body, argv, workingDirectory, sink),
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
          '${commandLine(executable, body.arguments)}',
        );
        return starter.start(
          executable,
          body.arguments,
          workingDirectory: body.workingDirectory,
          environment: body.environment,
          runInShell: runInShell,
          timeout: timeout,
          until: body.task.interruptible ? givenUp.reached : null,
          output: sink,
        );
    }
  }
}
