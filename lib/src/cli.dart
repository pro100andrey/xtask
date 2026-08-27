/// The command surface.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'bodies.dart';
import 'ci.dart';
import 'context.dart';
import 'dry_run.dart';
import 'errors.dart';
import 'exec.dart';
import 'executables.dart';
import 'exit_codes.dart';
import 'flags.dart';
import 'gates.dart';
import 'graph.dart';
import 'markers.dart';
import 'model.dart';
import 'parse.dart';
import 'primitives.dart';
import 'report.dart' as report;
import 'schema.dart';
import 'sets.dart';
import 'validate.dart';
import 'version.dart';

/// The file, at the repository root (§4).
const xtaskFileName = 'xtask.yaml';

/// What an invocation asked for.
///
/// Parsed into a value first and acted on second, so that every refusal §7
/// implies — two modes at once, a flag that is not one, `--gate` without the
/// `--list` it narrows — can be asserted without a filesystem, a plan or a
/// process anywhere near it.
sealed class Request {
  const Request();
}

/// `xtask <task> [-- <args>]` — run it and everything it needs.
final class RunTask extends Request {
  const RunTask(
    this.task, {
    this.arguments = const [],
    this.keepGoing = false,
    this.concurrency = 1,
  });

  final String task;

  /// What followed `--`, for [task]'s body alone.
  final List<String> arguments;

  /// `--keep-going`: report every failure rather than the first.
  final bool keepGoing;

  /// `-j`: how many tasks may be in flight. 1 is §5.2's run.
  final int concurrency;
}

/// `xtask --dry-run <task> [-- <args>]` — print what that would come to (§7).
final class DryRunTask extends Request {
  const DryRunTask(this.task, [this.arguments = const []]);

  final String task;

  /// What followed `--`, for [task]'s body alone.
  final List<String> arguments;
}

/// `xtask --list [--gate <name>]` — every task with its description.
final class ListTasks extends Request {
  const ListTasks(this.gate);

  /// The gate set to narrow to, or null for all of them.
  final String? gate;
}

/// `xtask --gate-members <name>` — the members of one gate set, one per line.
///
/// **A window on the data, not the mechanism.** No pipeline consumes this:
/// the duplicate list disappears because CI stops naming commands and runs one
/// task per job (§7.1), not because something reads this output. That is why
/// the format is one name per line — right for a person reading, and wrong for
/// feeding a build matrix, which it is not for.
final class GateMembers extends Request {
  const GateMembers(this.gate);

  final String gate;
}

/// `xtask --check-ci` — does the workflow still run the gate sets (§7.1)?
final class CheckCi extends Request {
  const CheckCi();
}

/// `xtask --validate` — parse and check, run nothing (§8).
final class Validate extends Request {
  const Validate();
}

/// `xtask --why <task>` — what puts that task in a plan.
final class WhyTask extends Request {
  const WhyTask(this.task);

  final String task;
}

/// `xtask --version` — print which engine this is.
///
/// Answered without a file, for the same reason as [EmitSchema]: it is a fact
/// about the engine. It is also the first thing a bug report needs, which is
/// no use if it only works in a directory that already works.
final class ShowVersion extends Request {
  const ShowVersion();
}

/// `xtask --emit-schema` — print the JSON Schema for the file format.
///
/// **The one request that does not want a file.** It describes what an
/// `xtask.yaml` may contain, which is a fact about the engine and not about
/// any repository — so it is answered before the file is looked for, and works
/// in a directory that has none. That is the point: it is how a repository
/// gets its first one.
final class EmitSchema extends Request {
  const EmitSchema();
}

/// The usage text, printed on request and as the error message.
final class ShowUsage extends Request {
  const ShowUsage([this.problem]);

  /// What was wrong with the invocation, or null when the usage was asked for.
  final String? problem;
}

/// The modes, exactly §7's list.
///
/// Public because the usage text has to name every one of them, and a test
/// that checked it against a list of its own would be a third copy of this —
/// drift between the parser and its own help being the sort that survives
/// review, since both halves read plausibly on their own.
const modes = {
  '--check-ci',
  '--list',
  '--why',
  '--gate-members',
  '--validate',
  '--dry-run',
  '--emit-schema',
  '--version',
};

/// What [args] asked for, or a [ShowUsage] naming what was wrong with it.
///
/// Hand-written rather than configured into a general parser: the grammar is
/// six lines and closed, and what matters about it is the refusals, which are
/// easier to state exactly than to arrange. Both spellings of the narrowing
/// flag — `--gate=name` and `--gate name` — are accepted, because both are
/// what people type.
Request parseArguments(List<String> args) {
  if (args.isEmpty) {
    return const ShowUsage('nothing to do');
  }

  final written = <String>[];
  final operands = <String>[];
  String? gate;
  var narrowed = false;
  var keepGoing = false;
  var concurrency = 1;
  var jobsWritten = false;

  final passed = <String>[];
  var separated = false;

  final rest = [...args];
  while (rest.isNotEmpty) {
    final argument = rest.removeAt(0);

    // **Everything after it is taken as written, options included.** That is
    // the whole point of the separator: `xtask test -- --name x` has to reach
    // the body with `--name` intact, and a parser that kept looking at these
    // would refuse the first one it did not recognise.
    if (argument == '--') {
      separated = true;
      passed.addAll(rest);
      rest.clear();
      continue;
    }

    if (argument == '--help' || argument == '-h') {
      return const ShowUsage();
    }

    if (argument == '--gate' || argument.startsWith('--gate=')) {
      narrowed = true;
      gate = argument.startsWith('--gate=')
          ? argument.substring('--gate='.length)
          : rest.isNotEmpty && !rest.first.startsWith('-')
          ? rest.removeAt(0)
          : null;
      if (gate == null || gate.isEmpty) {
        return const ShowUsage('`--gate` needs the name of a gate set');
      }
      continue;
    }

    if (argument == '--keep-going') {
      keepGoing = true;
      continue;
    }

    // **`-j N`, in every spelling make and cargo and xargs already taught.**
    // `--parallel` read as a boolean and behaved as a number: bare, it meant
    // "as many as this machine has processors", so `--parallel 2` was a task
    // called `2` and needed a refusal of its own to explain its own syntax. A
    // flag that has to do that has the wrong syntax.
    if (argument == '-j' ||
        argument == '--jobs' ||
        argument.startsWith('-j') ||
        argument.startsWith('--jobs=')) {
      // Named `asked` rather than `written`: the enclosing `written` is the
      // list of modes, and shadowing it here made it unreachable by its own
      // name inside this block.
      final asked = switch (argument) {
        '-j' || '--jobs' => rest.isNotEmpty ? rest.removeAt(0) : null,
        final a when a.startsWith('--jobs=') => a.substring('--jobs='.length),
        final a => a.substring(2),
      };
      if (asked == null || asked.isEmpty) {
        return const ShowUsage(
          '`-j` needs a number of jobs, or `auto`. Bare, it would have to mean '
          'something, and every number a machine could pick is wrong on some '
          'other machine',
        );
      }
      jobsWritten = true;
      if (!isAJobCount(asked)) {
        return ShowUsage(
          '`-j $asked` is not a number of jobs. Write `-j <n>` with n at '
          'least 1, or `-j auto`',
        );
      }
      if (asked == 'auto') {
        // **Capped, because a job here is a whole toolchain.** One unit is a
        // `dart test` or a `dart analyze`, each already multi-threaded and
        // each holding an analysis server. On a 32-core workstation, one per
        // core is 32 of them.
        concurrency = Platform.numberOfProcessors < 8
            ? Platform.numberOfProcessors
            : 8;
        continue;
      }
      concurrency = int.parse(asked);
      continue;
    }

    if (modes.contains(argument)) {
      written.add(argument);
      continue;
    }

    // **Both spellings, because `--gate` already took both.** A person who
    // learns `--gate=check` from the usage line writes `--why=test` next, and
    // what they used to get was "`--why=test` is not an option xtask has" — a
    // refusal that denies the flag exists rather than naming the form it
    // wants. The value joins the operands, where the mode below reads it as
    // if it had been written as its own word.
    final joined = modes.firstWhere(
      (mode) => argument.startsWith('$mode='),
      orElse: () => '',
    );
    if (joined.isNotEmpty) {
      written.add(joined);
      operands.add(argument.substring(joined.length + 1));
      continue;
    }

    if (argument.startsWith('-')) {
      return ShowUsage('`$argument` is not an option xtask has');
    }

    operands.add(argument);
  }

  if (written.length > 1) {
    return ShowUsage(
      '`${written[0]}` and `${written[1]}` ask for different things; '
      'write one',
    );
  }

  final mode = written.isEmpty ? null : written.single;

  if (narrowed && mode != '--list') {
    // `--gate` is a modifier, not a mode. It used to be one letter away from
    // `--gates`, which is why this refusal was written; the flag is now
    // `--gate-members` and cannot be reached by a slip of the finger, but a
    // `--gate` written without `--list` still has to be answered rather than
    // quietly ignored or listed past.
    return const ShowUsage(
      '`--gate` narrows `--list`. For the members of one gate set on their '
      'own, write `--gate-members <name>`',
    );
  }

  if (jobsWritten && mode != null) {
    // **Whether it was WRITTEN, not what it came to.** Testing the number let
    // `--list -j 1` through in silence, and made `--list -j auto` a refusal on
    // an eight-core machine and an acceptance on a one-core runner — the same
    // command line answering differently depending on the host.
    return ShowUsage(
      '`-j` is about a run, and `$mode` does not run anything',
    );
  }

  if (keepGoing && mode != null) {
    // It changes what a RUN does when something fails, and none of the modes
    // run anything. `--validate` in particular already collects every problem
    // it can find, which is the argument this flag borrows.
    return ShowUsage(
      '`--keep-going` is about a run, and `$mode` does not run anything',
    );
  }

  if (separated && mode != null && mode != '--dry-run') {
    // Only a body can take arguments, and only running or resolving one
    // reaches a body. `--list -- --name x` has nothing to hand them to, and
    // arguments that reach nothing are the silence this tool exists against.
    return ShowUsage(
      '`$mode` does not run anything, so there is nothing for the arguments '
      'after `--` to be arguments to',
    );
  }

  if (mode == '--list') {
    return operands.isEmpty
        ? ListTasks(gate)
        : ShowUsage(
            '`--list` takes no task name — to narrow it, write '
            '`--list --gate <name>`, and it was given `${operands.first}`',
          );
  }

  if (mode == '--version') {
    return operands.isEmpty
        ? const ShowVersion()
        : ShowUsage(
            '`--version` says which engine this is and takes nothing else, '
            'and it was given `${operands.first}`',
          );
  }

  if (mode == '--emit-schema') {
    return operands.isEmpty
        ? const EmitSchema()
        : ShowUsage(
            '`--emit-schema` describes the file format and takes nothing '
            'else, and it was given `${operands.first}`',
          );
  }

  if (mode == '--check-ci') {
    return operands.isEmpty
        ? const CheckCi()
        : ShowUsage(
            '`--check-ci` checks the whole workflow and takes no name, and it '
            'was given `${operands.first}`',
          );
  }

  if (mode == '--validate') {
    return operands.isEmpty
        ? const Validate()
        : ShowUsage(
            '`--validate` checks the whole file and takes no task name, and '
            'it was given `${operands.first}`',
          );
  }

  if (mode == '--why') {
    return operands.length == 1
        ? WhyTask(operands.single)
        : const ShowUsage('`--why` needs the name of one task');
  }

  if (mode == '--gate-members') {
    return operands.length == 1
        ? GateMembers(operands.single)
        : const ShowUsage('`--gate-members` needs the name of one gate set');
  }

  if (mode == '--dry-run') {
    return operands.length == 1
        ? DryRunTask(operands.single, passed)
        : const ShowUsage('`--dry-run` needs one task to resolve');
  }

  if (operands.isEmpty && separated) {
    return const ShowUsage(
      'the arguments after `--` belong to one task, and no task was named',
    );
  }

  return operands.length == 1
      ? RunTask(
          operands.single,
          arguments: passed,
          keepGoing: keepGoing,
          concurrency: concurrency,
        )
      : ShowUsage(
          'xtask runs one task at a time, and it was given '
          '${operands.map((o) => '`$o`').join(' and ')}',
        );
}

/// §7's list, and the message a refused invocation prints.
const usage = [
  'usage:',
  '  xtask <task>                 run a task and everything it needs',
  '  xtask <task> -- <args>       and pass those arguments to its body',
  '  xtask <task> --keep-going    report every failure, not just the first —',
  '                               across tasks and across an `each:`',
  '  xtask <task> -j <n>          run n at once — which costs seeing their',
  '                               output as it arrives. `-j auto` picks one',
  '  xtask --list                 every task, grouped under its gate set,',
  '                               in the order `gates:` declares',
  '  xtask --list --gate <name>   only the tasks in that gate set',
  '  xtask --gate-members <name>  the tasks in that gate set, one per line',
  '  xtask --why <task>           what puts that task in a plan, and by which',
  '                               `needs:` or `then:`',
  '  xtask --validate             parse and check the file; run nothing',
  '  xtask --check-ci             does the CI file still run the gate sets?',
  '  xtask --dry-run <task>       print the resolved plan; run nothing',
  '  xtask --emit-schema          print the JSON Schema for this file format',
  '  xtask --version              print which engine this is',
  '',
  'the file is `$xtaskFileName`, at the repository root.',
];

/// The directory holding `xtask.yaml`, looked for from [from] upwards.
///
/// **Upwards, and that is a decision.** §4 puts the file at the repository
/// root, and everything in it is relative to that root: `in:`, a set's globs,
/// what `remove` is allowed to touch. Reading `./xtask.yaml` would be correct
/// only when somebody happens to be standing at the top — from `packages/lake`
/// it finds nothing, and the obvious repair, taking the current directory as
/// the root, resolves every path against the wrong place without saying so.
/// Walking up makes the root a property of the repository rather than of where
/// the terminal is.
String? findRoot(String from) {
  var directory = p.absolute(from);
  while (true) {
    if (File(p.join(directory, xtaskFileName)).existsSync()) {
      return directory;
    }
    final parent = p.dirname(directory);
    if (parent == directory) {
      return null;
    }
    directory = parent;
  }
}

/// Runs one invocation and answers with the exit code §5.3 gives it.
///
/// Everything the command touches is a parameter: where it was run, the
/// environment, the two output sinks, how an executable is found and how a
/// process is started. Not for purity — it is what lets the surface be
/// asserted without a toolchain, and what lets the GitHub half of §7.1 be
/// tested from a machine that is not a runner.
Future<int> runCli(
  List<String> args, {
  required String workingDirectory,
  required Map<String, String> environment,
  required void Function(String line) out,
  required void Function(String line) err,
  required ExecutableResolver resolver,
  required ProcessStarter starter,
  Map<String, Verb> verbs = const {},
}) async {
  final request = parseArguments(args);

  if (request is ShowUsage) {
    final problem = request.problem;
    if (problem == null) {
      usage.forEach(out);
      return ExitCode.success;
    }
    err('xtask: $problem');
    usage.forEach(err);
    return ExitCode.invalidFile;
  }

  // Answered before the file is looked for, because it is not about a file:
  // it says what an `xtask.yaml` may contain, which is how a repository that
  // has not got one yet gets its first.
  if (request is EmitSchema) {
    out(xtaskJsonSchema().trimRight());
    return ExitCode.success;
  }

  if (request is ShowVersion) {
    out('xtask $packageVersion');
    return ExitCode.success;
  }

  // A project verb shadowing a primitive would change what `do: remove` means
  // without anything saying so, and §6 is a closed list precisely so that the
  // answer to "what does this verb do" is one place. Refusing costs a project
  // a rename; the alternative costs somebody a deleted directory.
  final shadowed = verbs.keys.where(builtInVerbNames.contains).toList()..sort();
  if (shadowed.isNotEmpty) {
    err(
      'xtask: this project registers ${shadowed.map((v) => '`$v`').join(', ')}'
      ', which the engine already ships as a built-in verb. Rename the '
      "project's verb: two things answering to one name in `do:` is one of "
      'them running when the file says the other',
    );
    return ExitCode.invalidFile;
  }

  final root = findRoot(workingDirectory);
  if (root == null) {
    err(
      'xtask: no `$xtaskFileName` in `$workingDirectory` or any directory '
      'above it. It belongs at the repository root, and every path in it '
      'is relative to wherever it is',
    );
    return ExitCode.invalidFile;
  }

  final path = p.join(root, xtaskFileName);
  final XtaskFile file;
  try {
    file = parseXtaskFile(
      File(path).readAsStringSync(),
      sourceUrl: Uri.file(path),
    );
  } on XtaskFormatException catch (problem) {
    err('$problem');
    return ExitCode.invalidFile;
  } on FileSystemException catch (problem) {
    // `findRoot` proved the file is there, so this is a permission or a
    // device — worth a sentence rather than a stack trace.
    err('xtask: cannot read `$path`: ${problem.osError?.message ?? problem}');
    return ExitCode.invalidFile;
  }

  final known = {...builtInVerbs(root: root), ...verbs};

  try {
    switch (request) {
      case ShowUsage() || EmitSchema() || ShowVersion():
        throw StateError('answered above');

      case Validate():
        final problems = validateFile(
          file,
          knownVerbs: known.keys.toSet(),
          sets: SetExpander(root: root),
        );
        if (!problems.ok) {
          err('$problems');
          return ExitCode.invalidFile;
        }
        out(
          report.read(
            path,
            file.tasks.length,
            file.gates.length,
            file.sets.length,
          ),
        );
        return ExitCode.success;

      case CheckCi():
        final found = checkCi(file, root: root);
        report.workflow(found).forEach(out);
        if (!found.ok) {
          found.problems.forEach(err);
          return ExitCode.invalidFile;
        }
        return ExitCode.success;

      case ListTasks(:final gate):
        // Narrowed to one set, the heading would repeat what was asked for;
        // over the whole file it is what makes the answer readable.
        (gate == null
                ? report.grouping(file)
                : report.listing(tasksInGate(file, _gate(file, gate))))
            .forEach(out);
        return ExitCode.success;

      case WhyTask(:final task):
        if (file.gates.containsKey(task)) {
          // Answerable, but not this question. What puts a gate set in a plan
          // is that somebody typed it; what is IN it is `--gate-members`.
          throw XtaskFormatException(
            '`$task` is a gate set, not a task — a run reaches it because '
            'somebody typed it. For what it runs, `--gate-members $task`',
            file.gates[task],
          );
        }
        if (!file.tasks.containsKey(task)) {
          throw XtaskFormatException('there is no task called `$task`');
        }
        report.why(task, _routesTo(file, task)).forEach(out);
        return ExitCode.success;

      case GateMembers(:final gate):
        for (final task in tasksInGate(file, _gate(file, gate))) {
          out(task.name);
        }
        return ExitCode.success;

      case DryRunTask(:final task, :final arguments):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        return await dryRun(
          file: file,
          root: root,
          plan: _planFor(file, task),
          resolver: resolver,
          log: out,
          verbs: known,
          environment: environment,
          passedThrough: (task: task, arguments: arguments),
        );

      case RunTask(
        :final task,
        :final arguments,
        :final keepGoing,
        :final concurrency,
      ):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        return await Executor(
          bodies: BodyResolver(
            root: root,
            resolver: resolver,
            sets: file.sets,
            verbs: known,
            environment: environment,
            passedThrough: (task: task, arguments: arguments),
          ),
          starter: starter,
          log: out,
          markers: LogMarkers.forHost(environment),
          keepGoing: keepGoing,
          concurrency: concurrency,
        ).run(_planFor(file, task));
    }
  } on XtaskFormatException catch (problem) {
    err('$problem');
    return ExitCode.invalidFile;
  }
}

/// Refuses arguments handed to something with no body to hand them to.
///
/// A gate set gathers tasks and runs nothing of its own, so `xtask check --
/// --name x` has nowhere to put `--name x`; so does a task whose whole content
/// is `needs:`. Passing them silently to nothing is the exact shape of failure
/// this tool exists against: a command that looks as though it did what was
/// asked.
void _refuseArgumentsWithNowhereToGo(
  XtaskFile file,
  String name,
  List<String> arguments,
) {
  if (arguments.isEmpty) {
    return;
  }
  final quoted = arguments.map((a) => '`$a`').join(' ');
  if (file.gates.containsKey(name)) {
    throw XtaskFormatException(
      '`$name` is a gate set, so there is nothing for $quoted to be an '
      'argument to. Name the task that takes them',
      file.gates[name],
    );
  }
  final task = file.tasks[name];
  if (task == null || task.body != null) {
    return;
  }
  throw XtaskFormatException(
    'task `$name` has no `run:` and no `do:` of its own, so there is nothing '
    'for $quoted to be an argument to. Name the task that takes them',
    task.span,
  );
}

/// Every way a run reaches [task]: the gate sets that run it, and the tasks
/// somebody types that lead to it.
///
/// **The gate sets are the half that used to be free.** A composite was a
/// task, so `entryPoints` found it and the route ran through its `needs:`. A
/// declared gate set has no such edge, and without this `--why format` would
/// answer "nothing reaches it" about a task that every `check` runs — the one
/// answer §8 says this question exists to prevent.
Map<String, List<PlanEdge>> _routesTo(XtaskFile file, String task) {
  final routes = <String, List<PlanEdge>>{};
  for (final gate in file.gates.keys) {
    for (final member in tasksInGate(file, gate)) {
      final route = routeTo(file, from: member.name, to: task);
      if (route == null) {
        continue;
      }
      // The first member that reaches it, which is the one the run reaches it
      // through: members are planned in declared order.
      // The edge is written even when the member IS the task, because an
      // empty route means "you typed it" — true of a task, and never of a
      // gate set, which reaches it by running it.
      routes.putIfAbsent(
        'gate $gate',
        () => [PlanEdge('gate $gate', 'runs', member.name), ...route],
      );
    }
  }
  for (final entry in entryPoints(file)) {
    final route = routeTo(file, from: entry, to: task);
    if (route != null) {
      routes[entry] = route;
    }
  }
  return routes;
}

/// The plan for [name], whether it is a gate set or a task.
///
/// **One name space, asked in one place.** §7 says a person types what they
/// want to happen, and a gate set is as much that as a task is — `xtask check`
/// used to work only because a composite task happened to carry the same name.
/// A gate set is now what its declaration says it is, so this is where the two
/// meet, and `_checkNoNameCollision` in the validator is what keeps the
/// question answerable.
Plan _planFor(XtaskFile file, String name) {
  if (!file.gates.containsKey(name)) {
    return planRun(file, name);
  }
  if (file.tasks.containsKey(name)) {
    // §8 reports this too, but a run must not quietly pick one of them: the
    // composite this replaced could not be ambiguous, and silently preferring
    // the gate set would run a plan the reader did not ask for.
    throw XtaskFormatException(
      '`$name` is both a gate set and a task, so there is no telling which '
      'one this asks for. Rename one of them',
      file.gates[name],
    );
  }
  final plan = planGate(file, name);
  if (plan.steps.isEmpty) {
    // **Silence would be a green gate that ran nothing.** An empty plan
    // printed nothing and answered 0, so a CI job whose only step is `xtask
    // check` passed in complete silence when every member's `gate:` was
    // misspelled — the exact failure this tool is against, reached by the one
    // path that does not validate first.
    throw XtaskFormatException(
      'gate set `$name` has no tasks in it, so running it would check '
      'nothing and answer 0. Put a task in it, or stop declaring it',
      file.gates[name],
    );
  }
  return plan;
}

/// [gate], if the file knows the name.
///
/// A gate set that is not declared is a typo, and the answer to a typo must
/// not be an empty list: `--gate-members ci-analize` printing nothing reads as
/// "that job checks nothing", which is the failure this whole tool is about.
/// Whether a DECLARED gate has members is `--validate`'s question (§8), not
/// this one's.
String _gate(XtaskFile file, String gate) {
  final known = file.gates.keys.toSet();
  if (known.contains(gate)) {
    return gate;
  }
  throw XtaskFormatException(
    'there is no gate set called `$gate`'
    '${known.isEmpty ? '' : ' — this file has '
              '${(known.toList()..sort()).map((g) => '`$g`').join(', ')}'}',
  );
}
