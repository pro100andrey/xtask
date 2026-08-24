/// Turning a task into the thing that will actually happen — §4.3 and §5.4 of
/// `xtask.md`.
///
/// **The engine's largest job, and it is not execution.** What a task comes to
/// — the set expanded, the member `$each` stands for, the directory it lands
/// in, the environment it sees, the program §5.4 finds on this machine — used
/// to be a private method inside `Executor`. That forced `--dry-run` to be a
/// *mode of the executor*: a callback, a process starter whose only job was to
/// throw, and four branches asking whether this run was pretending. None of
/// that was about dry runs. It was about the answer living in the wrong place.
///
/// One method in the interface, and every way a task can turn out to be
/// unrunnable behind it — an unset `env-required`, an unknown verb, a set that
/// does not exist or expands to nothing, `in: $each` with no `each:`, a program
/// nothing on `PATH` answers to, an argument `cmd.exe` would reinterpret.
library;

import 'package:path/path.dart' as p;

import 'context.dart';
import 'errors.dart';
import 'exit_codes.dart';
import 'model.dart';
import 'resolve.dart';
import 'sets.dart';

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
/// So there is one place that works it out — [BodyResolver] — and a run and
/// a dry run are two different things done with what it produces.
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

/// What a task comes to on this machine.
final class BodyResolver {
  BodyResolver({
    required this.root,
    required this.resolver,
    this.sets = const {},
    this.verbs = const {},
    this.environment = const {},
    this.passedThrough,
  }) : _expander = SetExpander(root: root);

  /// The repository root. Every working directory is resolved against it.
  final String root;

  /// How a written program name becomes a path on this machine (§5.4).
  final ExecutableResolver resolver;

  /// The file's `sets:` — only the sets.
  ///
  /// This used to be the whole [XtaskFile], a required parameter read at
  /// exactly one line. Handing a resolver the task graph as well hands it
  /// something it has no business with: what runs in what order is the
  /// planner's, and by now the planner has decided.
  final Map<String, NamedSet> sets;

  /// What the project registered (§9), plus the primitives of §6.
  final Map<String, Verb> verbs;

  /// The ambient environment a task's `env:` is added to, and the one
  /// `env-required` is checked against.
  final Map<String, String> environment;

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

  final SetExpander _expander;

  /// Everything [task] comes to, in order. Empty for a composite.
  ///
  /// Throws [RunFailure], carrying the reason and the code §5.3 gives it —
  /// which is what makes `--dry-run` worth reading: it stops exactly where a
  /// run would stop, with the same message and the same code, because it is
  /// the same call.
  List<Resolved> resolveTask(Task task) {
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
      // A pure composite. Its `needs:` have already run, and an empty list
      // says "nothing of its own" without the caller needing a special case.
      return const [];
    }

    final members = task.each == null
        ? const <String?>[null]
        : _expand(task, task.each!);

    return [for (final member in members) _resolve(task, body, member)];
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
  /// where §4.2 expects it to be caught. Reaching a RUN, it used to escape the
  /// walk altogether: past the exit code, and past the section markers, so a
  /// group opened for the task was never closed and everything after it on
  /// GitHub was folded into a task that had already stopped.
  List<String> _expand(Task task, String name) {
    try {
      return _expander.expand(name, _set(task, name));
    } on XtaskFormatException catch (problem) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` cannot run:\n$problem',
      );
    }
  }

  NamedSet _set(Task task, String name) {
    final set = sets[name];
    if (set == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` names the set `$name`, which does not exist',
      );
    }
    return set;
  }
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
