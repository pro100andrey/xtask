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
import 'budget.dart';
import 'ci.dart';
import 'completion.dart';
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
import 'primitives.dart';
import 'reading.dart';
import 'report.dart' as report;
import 'report_file.dart';
import 'request.dart';
import 'schema.dart';
import 'secrets.dart';
import 'sets.dart';
import 'style.dart';
import 'validate.dart';
import 'version.dart';

/// Runs one invocation and answers with the exit code the table gives it.
///
/// Everything the command touches is a parameter: where it was run, the
/// environment, the two output sinks, how an executable is found and how a
/// process is started. Not for purity — it is what lets the surface be
/// asserted without a toolchain, and what lets the GitHub markers be
/// tested from a machine that is not a runner.
///
/// [style] is how the lines a person reads are drawn, chosen by the caller
/// that has the terminal; plain where nothing says otherwise.
Future<int> runCli(
  List<String> args, {
  required String workingDirectory,
  required Map<String, String> environment,
  required void Function(String line) out,
  required void Function(String line) err,
  required ExecutableResolver resolver,
  required ProcessStarter starter,
  Map<String, Verb> verbs = const {},
  Interruption? interruption,
  Style style = Style.plain,
}) {
  final request = parseArguments(args);

  // **Masked here, at the two sinks, and nowhere else** — see `secrets.dart`.
  // Read before the request is answered, since its first line may be a
  // refusal of the command line, quoting it.
  final secrets = switch (findRoot(workingDirectory)) {
    final root? => readSecrets(root, environment, windows: resolver.windows),
    null => Secrets.none,
  };
  void shown(String line) => out(secrets.mask(line));
  void said(String line) => err(secrets.mask(line));

  // **Before a run's first line**, so that GitHub masks the bodies' output
  // too, which the engine does not filter. Only ahead of a run or a dry run:
  // `--gate-members` and `--names` are answers a program reads, and a line in
  // front of them would be a gate set called `::add-mask::…`. Nothing they
  // print is a value.
  if ((request is RunTask || request is DryRunTask) &&
      LogMarkers.forHost(environment) is GitHubMarkers) {
    secrets.addMasks.forEach(out);
  }

  Future<int> answer(
    void Function(String line) err, {
    void Function(report.RunSoFar run)? reportTo,
  }) => _answer(
    request,
    workingDirectory: workingDirectory,
    environment: environment,
    out: shown,
    relay: out,
    err: err,
    resolver: resolver,
    starter: starter,
    verbs: verbs,
    reportTo: reportTo,
    interruption: interruption,
    style: style,
  );

  if (request case RunTask(:final task, report: final path?)) {
    return _reporting(
      task,
      ReportFile(path, workingDirectory: workingDirectory, secrets: secrets),
      err: said,
      answer: (err, reportTo) => answer(err, reportTo: reportTo),
    );
  }
  // **A command line refused still answers the report it asked for.** Left
  // unwritten, the file is the last run's, and whatever waits on it reads
  // that run's code as this one's.
  if (request case ShowUsage(:final problem?)) {
    if (reportAskedIn(args) case final asked?) {
      return answer(said).then((code) {
        reportRefusal(
          asked,
          workingDirectory: workingDirectory,
          secrets: secrets,
          code: code,
          // The problem, and not the usage printed after it: that is help
          // for a person, and the same screenful in every refusal.
          refusal: 'xtask: $problem',
          err: said,
        );
        return code;
      });
    }
  }
  return answer(said);
}

/// A run with `--report`: the run as [answer] gives it, written to [file]
/// before it begins, as it goes, and once it has its code.
///
/// **Written before anything is looked at**, file included: a run refused
/// before a task began is a run too, and whatever reads the report is
/// told why rather than finding none. And a report that cannot be written
/// at all is said before any task runs — a run asked for one and left
/// without it reads, to the program waiting on it, like a run that never
/// happened, after the run has spent its minutes.
///
/// What the run says on [err] is the refusal the report carries: in a run,
/// only what refused it goes there.
Future<int> _reporting(
  String task,
  ReportFile file, {
  required void Function(String line) err,
  required Future<int> Function(
    void Function(String line) err,
    void Function(report.RunSoFar run) reportTo,
  )
  answer,
}) async {
  try {
    file.write(report.runReport(task, null));
  } on FileSystemException catch (e) {
    err(file.cannotWrite(e));
    return ExitCode.invalidFile;
  }

  // Once it has been written, a later write that fails is said once and
  // does not change what the run answers: the run is what was asked about.
  var said = false;
  void keep(Map<String, Object?> json) {
    try {
      file.write(json);
    } on FileSystemException catch (e) {
      if (!said) {
        said = true;
        err(file.cannotWrite(e));
      }
    }
  }

  report.RunSoFar? last;
  final refused = <String>[];
  final code = await answer(
    (line) {
      refused.add(line);
      err(line);
    },
    (run) => keep(report.runReport(task, last = run)),
  );
  keep(
    report.runReport(
      task,
      last,
      code: code,
      refusal: refused.isEmpty ? null : refused.join('\n'),
    ),
  );
  return code;
}

/// [request] answered, with the code the table gives it.
///
/// [out] and [err] are masked; [relay] is [out] as it is, for the output of
/// a body the engine passes on.
Future<int> _answer(
  Request request, {
  required String workingDirectory,
  required Map<String, String> environment,
  required void Function(String line) out,
  required void Function(String line) relay,
  required void Function(String line) err,
  required ExecutableResolver resolver,
  required ProcessStarter starter,
  required Map<String, Verb> verbs,
  void Function(report.RunSoFar run)? reportTo,
  Interruption? interruption,
  Style style = Style.plain,
}) async {
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

  if (request is CheckSchema) {
    // Also before the file: it is a question about the engine and one file.
    final path = request.path;
    final committed = File(p.join(workingDirectory, path));
    if (!committed.existsSync()) {
      err(
        'xtask: there is no `$path` to compare. Write one with:\n'
        '  xtask --emit-schema > $path',
      );
      return ExitCode.invalidFile;
    }
    final String text;
    try {
      text = committed.readAsStringSync();
    } on FileSystemException catch (e) {
      // **A sentence and 2, not a trace and 255.** A failure the operating
      // system reports — permissions, a directory — is said as it is. One it
      // does not is the decoding, and its likeliest cause is the regenerating
      // command itself: PowerShell 5.1's `>` writes UTF-16, which no editor's
      // schema loader reads either.
      final os = e.osError;
      err(
        os != null
            ? 'xtask: `$path` cannot be read (${os.message})'
            : 'xtask: `$path` cannot be read as UTF-8 text (${e.message}). '
                  'Regenerate it from a shell whose `>` writes UTF-8 — '
                  "PowerShell 5.1's writes UTF-16:\n"
                  '  xtask --emit-schema > $path',
      );
      return ExitCode.invalidFile;
    }
    if (!isCurrentSchema(text)) {
      err(
        'xtask: `$path` is not the schema this engine ($packageVersion) '
        'emits, so an editor reading it completes keys and refusals that '
        'are not these. Regenerate it:\n'
        '  xtask --emit-schema > $path',
      );
      return ExitCode.invalidFile;
    }
    out('`$path` is the schema this engine emits');
    return ExitCode.success;
  }

  if (request is ShowCompletion) {
    out(completionScript(request.shell).trimRight());
    return ExitCode.success;
  }

  if (request is ShowVersion) {
    out('xtask $packageVersion');
    return ExitCode.success;
  }

  // A project verb shadowing a primitive would change what `do: remove` means
  // without anything saying so, and the built-in verbs are a closed list
  // precisely so that the answer to "what does this verb do" is one place.
  // Refusing costs a project a rename; the alternative costs somebody a deleted
  // directory.
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

  // **Answered by the function a project's own entry point calls**, so that
  // the two cannot drift: the members a project reads in-process and the
  // lines a shell loop reads here are one implementation, refusals included.
  // After the shadowing check, where it always was, because a project whose
  // verbs are refused is refused whatever it asked.
  if (request case GateMembers(:final gate)) {
    try {
      gateMembers(gate, workingDirectory: workingDirectory).forEach(out);
      return ExitCode.success;
    } on XtaskFormatException catch (problem) {
      err('$problem');
      return ExitCode.invalidFile;
    }
  }

  final ({String root, String path, XtaskFile file}) read;
  try {
    read = readFrom(workingDirectory);
  } on XtaskFormatException catch (problem) {
    err('$problem');
    return ExitCode.invalidFile;
  }
  final (:root, :path, :file) = read;

  final known = {...builtInVerbs, ...verbs};

  /// What a task comes to on this machine, for the one task the command line
  /// named.
  ///
  /// **Built here and nowhere else, which is the whole reason the module
  /// exists.** The set expanded, the member `$each` stands for, the directory,
  /// the environment, the program the resolver finds — that is one answer, and
  /// `--dry-run` is supposed to print the very answer a run performs. It was
  /// constructed twice from the same six values, once in this arm and once
  /// inside `dryRun`, so a seventh would have reached one of them and the dry
  /// run would have promised something the run did not do — silently, and in
  /// the one place whose job is to be checkable against what somebody meant.
  BodyResolver bodiesFor(
    String task,
    List<String> arguments,
    Narrowing only, {
    bool cacheSets = false,
  }) => BodyResolver(
    root: root,
    resolver: resolver,
    sets: file.sets,
    verbs: known,
    environment: environment,
    passedThrough: (task: task, arguments: arguments),
    cacheSets: cacheSets,
    only: only,
  );

  try {
    switch (request) {
      case ShowUsage() ||
          EmitSchema() ||
          CheckSchema() ||
          ShowVersion() ||
          ShowCompletion() ||
          GateMembers():
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
          report.refusals(found).forEach(err);
          return ExitCode.invalidFile;
        }
        return ExitCode.success;

      case ListTasks(:final gate):
        // Narrowed to one set, the heading would repeat what was asked for;
        // over the whole file it is what makes the answer readable.
        (gate == null
                ? report.grouping(file, host: resolver.os, style: style)
                : report.listing(
                    tasksInGate(file, declaredGate(file, gate)),
                    host: resolver.os,
                    style: style,
                  ))
            .forEach(out);
        return ExitCode.success;

      case WhyTask(:final task):
        refuseUnlessATask(file, task);
        report.why(task, routesTo(file, task)).forEach(out);
        return ExitCode.success;

      case ShowGraph(:final name):
        // **Planned first, and only for what that buys.** A name `xtask
        // <name>` would refuse — unknown, both a gate set and a task, a gate
        // set with nothing in it, a ring — is refused here in the run's own
        // words, rather than drawn as a tree of something that cannot run.
        if (name != null) {
          planFor(file, name);
        }
        final sets = SetExpander(root: root);
        report
            .graph(
              file,
              name: name,
              host: resolver.os,
              fanOf: (task) => _fanOf(file, sets, task, named: name != null),
              style: style,
            )
            .forEach(out);
        return ExitCode.success;

      case ListNames():
        names(file).forEach(out);
        return ExitCode.success;

      case DryRunTask(:final task, :final arguments, :final only):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        final plan = planFor(file, task);
        _refuseNarrowingNothing(file, plan, task, only);
        return await dryRun(
          plan: plan,
          // Nothing runs, so nothing can change what a set expands to
          // between two steps of the plan.
          bodies: bodiesFor(task, arguments, only, cacheSets: true),
          log: out,
        );

      case RunTask(
        :final task,
        :final arguments,
        :final keepGoing,
        :final concurrency,
        :final only,
      ):
        _refuseArgumentsWithNowhereToGo(file, task, arguments);
        final plan = planFor(file, task);
        _refuseNarrowingNothing(file, plan, task, only);
        return await Executor(
          bodies: bodiesFor(task, arguments, only),
          starter: starter,
          log: out,
          relay: relay,
          markers: LogMarkers.forHost(environment),
          keepGoing: keepGoing,
          concurrency: concurrency,
          reportTo: reportTo,
          interruption: interruption,
          style: style,
        ).run(plan);
    }
  } on XtaskFormatException catch (problem) {
    err('$problem');
    return ExitCode.invalidFile;
  }
}

/// What [task]'s `each:` set comes to now, as `--graph` draws it.
///
/// **Expanded as the run expands it**, so the tree names the members a run
/// started now would reach. Empty because its `produced-by:` task has not
/// run is "not yet", as `--dry-run` says. Empty otherwise, it is a row's
/// detail where nothing was [named] — a picture of the whole file is not
/// refused for one task in it — and the run's refusal where a name was.
/// Every other refusal is the run's own, and answered 2 as the run would.
report.Fan _fanOf(
  XtaskFile file,
  SetExpander sets,
  Task task, {
  required bool named,
}) {
  final name = task.each!;
  final set = file.sets[name];
  if (set == null) {
    throw XtaskFormatException(
      noSuchSet(task: task.name, key: 'each', name: name),
      task.span,
    );
  }
  try {
    return report.Members(sets.expand(name, set));
  } on EmptySetException catch (empty) {
    if (empty.onlyYet && set is GlobSet) {
      return report.MembersNotYet(set.producedBy!);
    }
    if (!named) {
      return report.NoMembers(name);
    }
    rethrow;
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

/// Refuses an `--only` that could narrow nothing, before anything runs.
///
/// **Three ways for it to say less than it looks like it says**, and each one
/// is the run going green over more than was meant: a set the file has not
/// got, a set nothing in this plan expands, and a pattern that is not one.
/// A pattern that matches no member is the fourth, and it is asked where the
/// members are known — when the set is read, which a set produced by a task
/// in the plan is not before that task has run.
void _refuseNarrowingNothing(
  XtaskFile file,
  Plan plan,
  String task,
  Narrowing only,
) {
  for (final MapEntry(key: name, value: patterns) in only.entries) {
    if (!file.sets.containsKey(name)) {
      final known = file.sets.keys;
      throw XtaskFormatException(
        '`--only $name=…` names a set, and there is no set called `$name`'
        '${unknownNameHint(name, known, otherwise: theFileHas(known))}',
      );
    }
    final reads = plan.steps.any(
      (step) => step.task.each == name || step.task.all == name,
    );
    if (!reads) {
      throw XtaskFormatException(
        '`--only $name=…` narrows set `$name`, and nothing `$task` runs has '
        'it as `each:` or `all:` — so the run would be the whole run, said '
        'to be a part of one',
      );
    }
    for (final pattern in patterns) {
      memberPattern(name, pattern);
    }
  }
}
