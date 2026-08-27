/// Turning a task into the thing that will actually happen.
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

import 'boundary.dart';
import 'context.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'model.dart';
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
    required this.declaredEnvironment,
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

  /// Only what the task's own `env:` adds, with markers already standing for
  /// what they name.
  ///
  /// **Computed once, because two things print it.** A report shows what the
  /// file declared rather than the hundred variables that are part of the
  /// terminal — and it was rendering the WRITTEN text, so `--dry-run` promised
  /// `FLAVOR=$each` while the run exported `FLAVOR=dev`. Every other line of
  /// that block was substituted.
  final Map<String, String> declaredEnvironment;

  /// Everything after the program name: for a `run:` body the rest of its
  /// `argv`, then `args:`, each with its markers already standing for what
  /// they name — a set is expanded where it is written, not appended.
  final List<String> arguments;
}

/// A `run:` body, with the program found and Windows' shell question answered.
final class ResolvedProcess extends Resolved {
  const ResolvedProcess({
    required super.task,
    required super.member,
    required super.workingDirectory,
    required super.environment,
    required super.declaredEnvironment,
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
    required super.declaredEnvironment,
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
  /// They land **after** `args:` and anything a marker expanded to, where a
  /// command line belongs: last, and therefore able to add to what the file
  /// already said rather than being buried in front of it.
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
    // **Expanded once, wherever the marker stands.** `$all` is replaced by
    // every member of the set, in place, so the argument list a task writes is
    // the argument list it gets — `cp $all dest/` was unwritable while a set
    // could only be appended at the end.
    final members = task.all == null
        ? const <String>[]
        : _expand(task, task.all!);
    List<String> substituted(Iterable<String> written) => [
      for (final argument in written)
        if (argument == allMarker)
          ...members
        else
          _withMember(argument, member),
    ];
    final args = List<String>.unmodifiable([
      ...substituted(task.args),
      if (passed != null && passed.task == task.name) ...passed.arguments,
    ]);
    // A value goes where a value goes, and an environment value is one. Left
    // out, `env: {FLAVOR: $each}` reached the child as the literal text
    // `$each` — accepted by every check and wrong in the one place nobody
    // looks.
    final declared = Map<String, String>.unmodifiable({
      for (final entry in task.env.entries)
        entry.key: _withMember(entry.value, member),
    });
    final env = Map<String, String>.unmodifiable({
      ...environment,
      ...declared,
    });

    switch (body) {
      case DoBody(:final verb):
        final implementation = verbs[verb];
        if (implementation == null) {
          throw RunFailure(
            ExitCode.invalidFile,
            'task `${task.name}` names the verb `$verb`, which this project '
            'has not registered. The engine ships no project verbs: a '
            'verb is a Dart function the project hands to `runXtask`',
          );
        }
        return ResolvedVerb(
          task: task,
          member: member,
          workingDirectory: where,
          environment: env,
          declaredEnvironment: declared,
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
        _refuseFoundMemberReadAsOption(
          task,
          argv.first,
          [...argv.skip(1), ...task.args],
          [...members, ?member],
        );
        final arguments = List<String>.unmodifiable([
          ...substituted(argv.skip(1)),
          ...args,
        ]);
        final runInShell = resolver.needsShell(executable);
        if (runInShell) {
          _refuseShellMetacharacters(task, executable, arguments);
        }
        return ResolvedProcess(
          task: task,
          member: member,
          workingDirectory: where,
          environment: env,
          declaredEnvironment: declared,
          arguments: arguments,
          executable: executable,
          runInShell: runInShell,
          timeout: task.timeout == null
              ? null
              : Duration(seconds: task.timeout!),
        );
    }
  }

  /// Refuses a member the engine FOUND that the program would read as an
  /// option.
  ///
  /// **Found, not written, and that is the whole distinction.** A repository
  /// may hold a file called `-n.dart`; a glob will find it, and handed over
  /// bare it is not a path to the program, it is `-n`. The author never typed
  /// that name and cannot be expected to have thought about it.
  ///
  /// A `values:` or list set is the opposite case: `--enable-asserts` is there
  /// because somebody wrote it, and refusing it would refuse the use `values:`
  /// exists for. So this asks where the member came from, not what it looks
  /// like.
  ///
  /// And it asks about the ARGUMENT, not the member: `--flavor=$each` is one
  /// word the author composed, and what a `-` inside it means is their
  /// business. Only a marker standing alone becomes a word this engine chose.
  ///
  /// Refused rather than fixed. Inserting `--` would change the argv a task
  /// wrote, which is the one thing `run:` promises it does not do, and there
  /// are programs for which `--` means something else.
  void _refuseFoundMemberReadAsOption(
    Task task,
    String program,
    List<String> written,
    List<String> members,
  ) {
    final from = sets[task.all ?? task.each];
    if (from is! GlobSet) {
      return;
    }
    // **`args:` is argv too**, which the schema says in as many words. Looking
    // only at `run:` skipped this check for the very shape it was written for:
    // `run: [dart, format]` with `args: [\$all]` handed a repository file
    // called `-n.dart` to the child as an option, silently.
    final bare = written.indexWhere(
      (word) => word == allMarker || word == eachMarker,
    );
    if (bare == -1) {
      // The member reaches `in:` or `env:` and never argv. Saying it would be
      // read as an option would be false, and the advice — a `--` before a
      // marker that is not there — impossible to follow.
      return;
    }
    if (written.take(bare).contains('--')) {
      return;
    }
    final found = members.where((member) => member.startsWith('-'));
    if (found.isEmpty) {
      return;
    }
    throw RunFailure(
      ExitCode.invalidFile,
      'task `${task.name}` would hand `${found.first}` to `$program` as '
      'an argument, and a word beginning with `-` is an option to almost every '
      'program. This one was matched by a glob rather than written, so write '
      '`--` before the marker, which is where a command line says its operands '
      'begin',
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
          'executable, or make it a verb — a Dart function is where logic '
          'belongs anyway',
        );
      }
    }
  }

  /// [written] with a trailing `$each` replaced by [member].
  ///
  /// Only at the end, which `parse` has already refused anything else for.
  /// The prefix survives, and that is the whole of what it buys: a set may
  /// hold the bare name a path cannot be derived from — `lake_cli` — and the
  /// path is composed where it is used, `in: packages/$each`. Both halves are
  /// then available to one task, which nothing else in this design offers.
  static String _withMember(String written, String? member) {
    if (!written.endsWith(eachMarker)) {
      return written;
    }
    if (member == null) {
      // `parse` refuses this shape, so reaching it means the file said one
      // thing and this read another.
      throw StateError('`$eachMarker` with no member');
    }
    return written.substring(0, written.length - eachMarker.length) + member;
  }

  /// Where a body runs. `$each` is the member; anything else is relative to
  /// the repository root (§4.3).
  String _workingDirectory(Task task, String? member) {
    final written = task.workingDirectory;
    if (written == null) {
      return root;
    }
    // **The written string AND what it becomes.** A value set is deliberately
    // not asked whether its members leave the repository — they are not paths
    // — and `in: sub/$each` composes one out of them, after the only gate.
    // `../../../etc` as a flavour then ran a body in `/etc` and answered 0,
    // through the shape the README recommends.
    if (leavesRoot(written) ||
        (member != null && leavesRoot(_withMember(written, member)))) {
      // The one path in the file that reached the filesystem without ever
      // being asked whether it stayed inside: `in: ../..` ran a body two
      // levels above the root, and answered 0.
      throw RunFailure(
        ExitCode.invalidFile,
        workingDirectoryLeavesRoot(
          task: task.name,
          written: member == null ? written : _withMember(written, member),
        ),
      );
    }
    if (written.endsWith(eachMarker)) {
      if (member == null) {
        throw RunFailure(
          ExitCode.invalidFile,
          'task `${task.name}` uses `in: $written` without an `each:` set, so '
          'there is no member for it to stand for',
        );
      }
      return p.join(root, _withMember(written, member));
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
    final set = _set(task, name);
    try {
      return _expander.expand(name, set);
    } on EmptySetException catch (problem) {
      // Distinguished by type, so `--dry-run` can tell "not yet" from "wrong"
      // instead of guessing from the exit code — which called a boundary
      // violation and an unknown verb premature, and answered 0.
      final message = 'task `${task.name}` cannot run:\n$problem';
      throw set is GlobSet && set.produced
          ? NotYetFailure(ExitCode.invalidFile, message)
          : RunFailure(ExitCode.invalidFile, message);
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
