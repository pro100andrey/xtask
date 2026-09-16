/// Turning a task into the thing that will actually happen.
///
/// **The engine's largest job, and it is not execution.** What a task comes to
/// — the set expanded, the member `$each` stands for, the directory it lands
/// in, the environment it sees, the program the resolver finds on this
/// machine — is decided here and nowhere else, so that `--dry-run` prints the
/// very answer a run performs rather than a second reading of the file.
///
/// One method in the interface, and every way a task can turn out to be
/// unrunnable behind it — an unset `env-required`, an unknown verb, a set that
/// does not exist or expands to nothing, `in: $each` with no `each:`, a program
/// nothing on `PATH` answers to, an argument `cmd.exe` would reinterpret.
library;

import 'boundary.dart';
import 'context.dart';
import 'errors.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'model.dart';
import 'sets.dart';

/// A body with everything about it decided — `--dry-run`'s *resolved* plan.
///
/// **What `--dry-run` prints and what a run performs, worked out once.**
/// Turning a task into a command is most of the engine: the set expanded, the
/// member `$each` stands for, the directory it lands in, the environment it
/// sees, and the executable the resolver finds on this machine. A dry run that
/// worked that out a second time would be a second answer to "what will happen"
/// — the two would agree until the day one of them was changed, which is the
/// first defect this tool is against, written by the tool that exists to remove
/// it.
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
  /// terminal, and shows it substituted — `FLAVOR=dev`, as the child sees it,
  /// not `FLAVOR=$each` as the file wrote it.
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

  /// The absolute path the resolver resolved the written name to, on this
  /// machine.
  final String executable;

  /// Whether starting it means going through `cmd.exe` — true only for a
  /// Windows shim that `CreateProcess` cannot start (the batch-shim rule).
  final bool runInShell;

  /// How long it may take, or null for no limit — the task's `timeout:`.
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

/// What both kinds of body are resolved against.
typedef _Shared = ({
  String? member,
  String where,
  List<String> members,
  List<String> Function(Iterable<String>) substituted,
  List<String> args,
  Map<String, String> declared,
  Map<String, String> environment,
});

/// What a task comes to on this machine.
final class BodyResolver {
  BodyResolver({
    required this.root,
    required this.resolver,
    this.sets = const {},
    this.verbs = const {},
    this.environment = const {},
    this.passedThrough,
    this.cacheSets = false,
  }) : _expander = SetExpander(root: root);

  /// The repository root. Every working directory is resolved against it.
  final String root;

  /// How a written program name becomes a path on this machine (the resolver).
  final ExecutableResolver resolver;

  /// The file's `sets:` — only the sets.
  ///
  /// A resolver has no business with the task graph: what runs in what order
  /// is the planner's, and by now the planner has decided.
  final Map<String, NamedSet> sets;

  /// What the project registered, plus the built-in verbs.
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

  /// Whether a set read once may be answered from memory.
  ///
  /// **False for a run, and that is the whole of it.** A set is read when the
  /// task naming it is about to run, because a task between two others may
  /// have made or removed the files — which is why there is no cache here by
  /// default. `--dry-run` runs nothing at all, so the second walk of a set two
  /// tasks share can only find what the first one found: twenty tasks sharing
  /// one glob set cost twenty identical walks and 553ms, against 36ms for one.
  final bool cacheSets;

  final SetExpander _expander;

  final _expanded = <String, List<String>>{};

  /// Everything [task] comes to, in order. Empty for a composite.
  ///
  /// Throws [RunFailure], carrying the reason and the code the exit code table
  /// gives it — which is what makes `--dry-run` worth reading: it stops exactly
  /// where a run would stop, with the same message and the same code, because
  /// it is the same call.
  List<Resolved> resolveTask(Task task) {
    // Before the body, and that is the whole value of the key: it turns "a
    // browser test failed somewhere inside" into "task `web-e2e` requires
    // CHROMEDRIVER, which is not set" (one invocation per job). The engine
    // installs nothing.
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
    final common = _shared(task, member);
    return switch (body) {
      DoBody(:final verb) => _resolveVerb(task, verb, common),
      RunBody(:final argv) => _resolveProcess(task, argv, common),
    };
  }

  /// Everything a body of either kind is resolved against: where it runs, what
  /// it was given, and what its environment is.
  _Shared _shared(Task task, String? member) {
    final where = _workingDirectory(task, member);
    // `$all` is replaced by every member of the set, in place, so the argument
    // list a task writes is the argument list it gets.
    final members = task.all == null
        ? const <String>[]
        : _expand(task, task.all!);
    // The one substitution rule, asked with the one member this body is for.
    List<String> substitute(Iterable<String> written) =>
        substituted(written, all: members, each: [?member]);
    final passed = passedThrough;
    // A value goes where a value goes, and an environment value is one:
    // `env: {FLAVOR: $each}` would otherwise reach the child as literal text.
    final declared = Map<String, String>.unmodifiable({
      for (final entry in task.env.entries)
        entry.key: member == null
            ? entry.value
            : withMember(entry.value, member),
    });
    return (
      member: member,
      where: where,
      members: members,
      substituted: substitute,
      args: List<String>.unmodifiable([
        ...substitute(task.args),
        if (passed != null && passed.task == task.name) ...passed.arguments,
      ]),
      declared: declared,
      environment: Map<String, String>.unmodifiable({
        ...environment,
        ...declared,
      }),
    );
  }

  ResolvedVerb _resolveVerb(Task task, String verb, _Shared common) {
    final implementation = verbs[verb];
    if (implementation == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        unknownVerb(task: task.name, verb: verb, known: verbs.keys.toSet()),
      );
    }
    return ResolvedVerb(
      task: task,
      member: common.member,
      workingDirectory: common.where,
      environment: common.environment,
      declaredEnvironment: common.declared,
      arguments: common.args,
      verb: verb,
      implementation: implementation,
    );
  }

  ResolvedProcess _resolveProcess(
    Task task,
    List<String> argv,
    _Shared common,
  ) {
    final executable = resolver.resolve(argv.first, from: common.where);
    if (executable == null) {
      throw RunFailure(
        ExitCode.missingTool,
        'task `${task.name}`: '
        '${resolver.missingToolMessage(argv.first, from: common.where)}',
      );
    }
    _refuseFoundMemberReadAsOption(
      task,
      argv.first,
      [...argv.skip(1), ...task.args],
      [...common.members, ?common.member],
    );
    final arguments = List<String>.unmodifiable([
      ...common.substituted(argv.skip(1)),
      ...common.args,
    ]);
    final runInShell = resolver.needsShell(executable);
    if (runInShell) {
      refuseShellMetacharacters(task.name, executable, arguments);
    }
    return ResolvedProcess(
      task: task,
      member: common.member,
      workingDirectory: common.where,
      environment: common.environment,
      declaredEnvironment: common.declared,
      arguments: arguments,
      executable: executable,
      runInShell: runInShell,
      timeout: task.timeout == null ? null : Duration(seconds: task.timeout!),
    );
  }

  /// Refuses a member the engine FOUND that the program would read as an
  /// option.
  ///
  /// The rule itself is `model.dart`'s, so that `--validate` — which expands
  /// every set already — asks the same question and gets the same sentence.
  void _refuseFoundMemberReadAsOption(
    Task task,
    String program,
    List<String> written,
    List<String> members,
  ) {
    final refusal = foundMemberReadAsOption(
      task: task,
      program: program,
      written: written,
      members: members,
      from: sets[task.all ?? task.each],
    );
    if (refusal != null) {
      throw RunFailure(ExitCode.invalidFile, refusal);
    }
  }

  /// Where a body runs. `$each` is the member; anything else is relative to
  /// the repository root.
  ///
  /// Asked the boundary twice: of what the file wrote, composed around the
  /// member, and of what this machine has there — a directory inside the
  /// root that is a link to one outside it passes the first and not the
  /// second.
  String _workingDirectory(Task task, String? member) {
    final written = task.workingDirectory;
    if (written == null) {
      return root;
    }
    if (member == null && written.endsWith(eachMarker)) {
      // The parser refuses this shape; the resolver is a public seam and must
      // not read a member that is not there.
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` uses `in: $written` without an `each:` set, so '
        'there is no member for it to stand for',
      );
    }
    final composed = member == null ? written : withMember(written, member);
    if (leavesRoot(composed)) {
      throw RunFailure(
        ExitCode.invalidFile,
        workingDirectoryLeavesRoot(task: task.name, written: composed),
      );
    }
    final where = underRoot(root, composed);
    if (!staysUnder(root, where)) {
      throw RunFailure(
        ExitCode.invalidFile,
        workingDirectoryLeavesRoot(
          task: task.name,
          written: composed,
          throughALink: true,
        ),
      );
    }
    return where;
  }

  /// The members of set [name], as a failure of [task] when there are none.
  ///
  /// **Rewrapped rather than let through.** A set that expands to nothing is
  /// an [XtaskFormatException] — the right type for `--validate`. Reaching a
  /// RUN it has to be a [RunFailure], so that it ends with a code the table
  /// has and with the task's section closed rather than folding everything
  /// after it into a task that had already stopped.
  List<String> _expand(Task task, String name) {
    final remembered = cacheSets ? _expanded[name] : null;
    if (remembered != null) {
      return remembered;
    }
    final set = _set(task, name);
    try {
      final members = _expander.expand(name, set);
      if (cacheSets) {
        _expanded[name] = members;
      }
      return members;
    } on EmptySetException catch (problem) {
      // Distinguished by type, so `--dry-run` can tell "not yet" from "wrong"
      // instead of guessing from the exit code — which called a boundary
      // violation and an unknown verb premature, and answered 0.
      //
      // Whether it is only-yet is the refusal's to say, not this module's:
      // asking the set again here was the same rule written a second time, in
      // a file that has no business knowing what `produced:` means.
      final message = [
        'task `${task.name}` cannot run:',
        '$problem',
        ?_shapeOfASetFedToRemove(task),
      ].join('\n');
      throw problem.onlyYet
          ? NotYetFailure(ExitCode.invalidFile, message)
          : RunFailure(ExitCode.invalidFile, message);
    } on XtaskFormatException catch (problem) {
      throw RunFailure(
        ExitCode.invalidFile,
        'task `${task.name}` cannot run:\n$problem',
      );
    }
  }

  /// The advice a `do: remove` task needs when its set came back empty.
  ///
  /// **The one shape that is green once and red afterwards.** A glob set
  /// matches the build output on the first run and nothing on the second, so a
  /// `clean` written that way refuses on a tree it has itself just cleaned —
  /// and the refusal, which is about sets in general, says nothing about the
  /// one thing that would fix it. A list of literal patterns is never empty,
  /// because it is written out, and the globs inside it are this verb's to
  /// expand under the rule that a missing path is not an error.
  static String? _shapeOfASetFedToRemove(Task task) {
    final body = task.body;
    if (body is! DoBody || body.verb != removeVerbName) {
      return null;
    }
    return 'A set fed to `remove` is written as a list of literal patterns — '
        "`[build, coverage, '**/*.tmp']` — so that it is never empty. Written "
        'as a glob it matches the output on the first run and nothing on the '
        'second, which is why this is green once and red afterwards.';
  }

  NamedSet _set(Task task, String name) {
    final set = sets[name];
    if (set == null) {
      throw RunFailure(
        ExitCode.invalidFile,
        noSuchSet(
          task: task.name,
          key: task.each == name ? 'each' : 'all',
          name: name,
        ),
      );
    }
    return set;
  }
}
