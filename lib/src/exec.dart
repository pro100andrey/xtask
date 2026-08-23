/// Running the bodies a plan resolved to — §5.2 of `xtask.md`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'exit_codes.dart';
import 'graph.dart';
import 'model.dart';
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

  final SetExpander _sets;

  /// Runs every step, and answers with the code §5.3 gives the outcome.
  Future<int> run(Plan plan) async {
    for (final step in plan.steps) {
      try {
        await _runTask(step.task);
      } on RunFailure catch (failure) {
        log(failure.message);
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
        : _sets.expand(task.each!, _set(task, task.each!));

    for (final member in members) {
      await _runBody(task, body, member);
    }
  }

  Future<void> _runBody(Task task, Body body, String? member) async {
    final where = _workingDirectory(task, member);
    final args = [
      ...task.args,
      if (task.argvFrom != null)
        ..._sets.expand(task.argvFrom!, _set(task, task.argvFrom!)),
    ];
    final env = {...environment, ...task.env};

    final code = switch (body) {
      DoBody(:final verb) => await _runVerb(task, verb, args, env, where),
      RunBody(:final argv) => await _runProcess(task, argv, args, env, where),
    };

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

  Future<int> _runVerb(
    Task task,
    String verb,
    List<String> args,
    Map<String, String> env,
    String where,
  ) {
    final implementation = verbs[verb];
    if (implementation == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` names the verb `$verb`, which this project has '
        'not registered. The engine ships no project verbs (§9): a verb is a '
        'Dart function the project hands to `runXtask`',
      );
    }
    return implementation(
      VerbContext(
        args: List.unmodifiable(args),
        env: Map.unmodifiable(env),
        workingDirectory: where,
        log: log,
      ),
    );
  }

  Future<int> _runProcess(
    Task task,
    List<String> argv,
    List<String> args,
    Map<String, String> env,
    String where,
  ) {
    final resolved = resolver.resolve(argv.first);
    if (resolved == null) {
      throw RunFailure(
        ExitCode.missingTool,
        'task `${task.name}`: ${resolver.missingToolMessage(argv.first)}',
      );
    }

    final arguments = [...argv.skip(1), ...args];
    final runInShell = resolver.needsShell(resolved);
    if (runInShell) {
      _refuseShellMetacharacters(task, resolved, arguments);
    }

    log('${task.name}: ${[resolved, ...arguments].join(' ')}');
    return starter.start(
      resolved,
      arguments,
      workingDirectory: where,
      environment: env,
      runInShell: runInShell,
    );
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
