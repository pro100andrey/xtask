/// The command surface: reading the file once, and dispatching one request.
///
/// **What an invocation MEANS is `request.dart`'s.** This module is the half
/// that touches a machine — finding the root, reading the file, choosing what
/// to do — and the grammar is the half that touches nothing, which is why
/// `--check-ci` can use it to decide whether a workflow step is an invocation
/// at all.
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
import 'gates.dart';
import 'graph.dart';
import 'markers.dart';
import 'model.dart';
import 'parse.dart';
import 'primitives.dart';
import 'report.dart' as report;
import 'request.dart';
import 'schema.dart';
import 'sets.dart';
import 'validate.dart';
import 'version.dart';

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
