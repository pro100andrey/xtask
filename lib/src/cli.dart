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

  /// What a task comes to on this machine, for the one task the command line
  /// named.
  ///
  /// **Built here and nowhere else, which is the whole reason the module
  /// exists.** The set expanded, the member `$each` stands for, the directory,
  /// the environment, the program §5.4 finds — that is one answer, and
  /// `--dry-run` is supposed to print the very answer a run performs. It was
  /// constructed twice from the same six values, once in this arm and once
  /// inside `dryRun`, so a seventh would have reached one of them and the dry
  /// run would have promised something the run did not do — silently, and in
  /// the one place whose job is to be checkable against what somebody meant.
  BodyResolver bodiesFor(
    String task,
    List<String> arguments, {
    bool cacheSets = false,
  }) => BodyResolver(
    root: root,
    resolver: resolver,
    sets: file.sets,
    verbs: known,
    environment: environment,
    passedThrough: (task: task, arguments: arguments),
    cacheSets: cacheSets,
  );

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
        refuseUnlessATask(file, task);
        report.why(task, routesTo(file, task)).forEach(out);
        return ExitCode.success;

      case GateMembers(:final gate):
        for (final task in tasksInGate(file, _gate(file, gate))) {
          out(task.name);
        }
        return ExitCode.success;

      case DryRunTask(:final task, :final arguments):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        return await dryRun(
          plan: planFor(file, task),
          // Nothing runs, so nothing can change what a set expands to
          // between two steps of the plan.
          bodies: bodiesFor(task, arguments, cacheSets: true),
          log: out,
        );

      case RunTask(
        :final task,
        :final arguments,
        :final keepGoing,
        :final concurrency,
      ):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        return await Executor(
          bodies: bodiesFor(task, arguments),
          starter: starter,
          log: out,
          markers: LogMarkers.forHost(environment),
          keepGoing: keepGoing,
          concurrency: concurrency,
        ).run(planFor(file, task));
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
