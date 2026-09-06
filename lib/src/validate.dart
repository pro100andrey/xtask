/// `--validate` — the first gate any project should adopt.
library;

import 'boundary.dart';
import 'context.dart';
import 'errors.dart';
import 'gates.dart';
import 'graph.dart';
import 'model.dart';
import 'sets.dart';

/// Everything wrong with a file, rather than the first thing.
///
/// **Collecting is the point, and it is a departure from the parser.**
/// `parseXtaskFile` throws at the first violation, which is right for it —
/// without a document there is nothing to keep checking. After parsing there
/// is, and a gate that reports one problem per run makes somebody fix, rerun,
/// fix, rerun. §8 calls this the first gate a project adopts; a gate that
/// takes five runs to list five problems is one people stop running.
final class ValidationReport {
  const ValidationReport(this.problems);

  /// In the order they were found: structure first, then names, then the
  /// filesystem — cheapest and most likely to be the real cause first.
  final List<XtaskFormatException> problems;

  bool get ok => problems.isEmpty;

  /// Every problem, one per paragraph, as `--validate` prints them.
  @override
  String toString() => problems.join('\n\n');
}

/// Checks everything §8 lists that survives parsing.
///
/// [knownVerbs] is the built-in primitives (§6) plus whatever the project
/// registered (§9) — passed in rather than listed here, because a second list
/// of verb names is the defect §1 exists to remove.
///
/// [sets] expands globs so that a set matching nothing is caught. §8 puts it
/// here deliberately: it is checkable without running any task, and the
/// failure it prevents is a green gate that examined no files. Omit it only
/// where the filesystem is genuinely unavailable, and know that the check is
/// then not done.
ValidationReport validateFile(
  XtaskFile file, {
  required Set<String> knownVerbs,
  SetExpander? sets,
}) {
  final problems = <XtaskFormatException>[];

  for (final task in file.tasks.values) {
    _checkDoesSomething(task, problems);
    _checkVerb(task, knownVerbs, problems);
    _checkSetReferences(task, file, problems);
    _checkWorkingDirectory(task, file, problems);
    _checkRemoveArguments(task, file, problems);
  }

  _checkGraph(file, problems);
  _checkDeclaredGates(file, problems);
  _checkNoNameCollision(file, problems);
  _checkExclusive(file, problems);
  if (sets != null) {
    _checkSetsExpand(file, sets, problems);
  }

  return ValidationReport(List.unmodifiable(problems));
}

/// A task with no body, nothing to depend on and nothing to continue into is a
/// task that does nothing (§8).
///
/// **`then:` counts, and it was left out.** A task whose whole content is a
/// continuation is reached, runs nothing of its own, and then runs what
/// follows it — which is something. `publish then verify`, `verify then
/// notify` runs all three and answers 0, while this reported the middle one as
/// a name with a description attached: a file the run accepts and the gate the
/// README tells every project to adopt refuses.
void _checkDoesSomething(Task task, List<XtaskFormatException> problems) {
  if (task.body != null || task.needs.isNotEmpty || task.then.isNotEmpty) {
    return;
  }
  problems.add(
    XtaskFormatException(
      'task `${task.name}` has no body, no `needs:` and no `then:`, so running '
      'it does nothing. A gate set gathers tasks; a task that gathers nothing '
      'is a name with a description attached',
      task.span,
    ),
  );
}

/// An `in:` that leaves the repository (§8).
///
/// The other half of this fence — a set's members and patterns — is reached
/// from here through `_checkSetsExpand`, so leaving `in:` to be caught at
/// resolve time made one boundary answer at two different moments: a file
/// `--validate` called clean was refused by `--dry-run`. §8's claim is that
/// this class is found without running anything, and `in:` is a written
/// string, checkable the moment the file is read.
void _checkWorkingDirectory(
  Task task,
  XtaskFile file,
  List<XtaskFormatException> problems,
) {
  final written = task.workingDirectory;
  if (written == null) {
    return;
  }

  // **The composed form too, where the members are known here.** A `values:`
  // set is deliberately exempt from the boundary — its members are not paths —
  // and `in: sub/$each` builds one out of them. Checking only the written
  // string reopened the gap this function was added to close: a file
  // `--validate` called clean, refused by `--dry-run`. Those members are
  // literal and sitting in the file, so composing them costs nothing and
  // needs no filesystem.
  final set = file.sets[task.each];
  final composed = [
    written,
    if (written.endsWith(eachMarker) && set is ValueSet)
      for (final value in set.values)
        written.substring(0, written.length - eachMarker.length) + value,
  ];

  for (final path in composed) {
    if (!leavesRoot(path)) {
      continue;
    }
    problems.add(
      XtaskFormatException(
        workingDirectoryLeavesRoot(task: task.name, written: path),
        task.span,
      ),
    );
    return;
  }
}

/// The repository boundary, asked of the arguments `do: remove` will delete.
///
/// **The one body that deletes, and the one place the fence was missing.**
/// `boundary.dart` says every place that turns a written string into a path
/// calls it, and `in:` and the sets do. These arguments did not: a task with
/// `do: remove` and `args: ['/etc']` was answered "nothing wrong" here and
/// refused by the run, so the mode whose whole promise is finding this class
/// without running anything did not find it for the verb that most needs it.
///
/// Literal arguments only, which is all this can see without a filesystem —
/// a member a glob finds is the resolver's to check, and it does.
void _checkRemoveArguments(
  Task task,
  XtaskFile file,
  List<XtaskFormatException> problems,
) {
  final body = task.body;
  if (body is! DoBody || body.verb != removeVerbName) {
    return;
  }

  // **The set's members too, where they are known here.** `$all` and `$each`
  // stand for what a set holds, and a `values:` set is deliberately exempt
  // from the boundary everywhere else — its members are not paths. Fed to
  // this verb they are: `values: ['/etc']` with `args: [$all]` was called
  // clean here and refused by the run, which is the gap this check was added
  // to close, reopened one substitution along. Literal and sitting in the
  // file, so composing them costs nothing and needs no filesystem.
  //
  // A glob set's members are the resolver's to check and it does; a list
  // set's went through `_refuseUnrooted` when the file was read.
  final substituted = file.sets[task.all ?? task.each];
  final written = [
    ...task.args,
    if (substituted is ValueSet)
      for (final argument in task.args)
        // Composed, not only substituted whole. `_checkWorkingDirectory` does
        // this for `in:` and this did not, so `args: ['out/$each']` over a
        // `values:` set holding `../../etc` was called clean here and refused
        // by the run as `out/../../etc`.
        if (argument == allMarker || argument == eachMarker)
          ...substituted.values
        else if (argument.endsWith(eachMarker))
          for (final value in substituted.values)
            argument.substring(0, argument.length - eachMarker.length) + value,
  ];

  // Distinct, because the span is the task's: `args: ['/etc', 'x', '/etc']`
  // printed the same sentence twice under the same underlined line, which
  // reads as the validator repeating itself rather than as two facts.
  for (final argument in written.toSet()) {
    if (!leavesRoot(argument)) {
      continue;
    }
    // Every one of them. This module opens by saying everything wrong with a
    // file rather than the first thing, and three bad paths answered one at a
    // time is three round trips.
    problems.add(
      XtaskFormatException(removeLeavesRoot(written: argument), task.span),
    );
  }
}

void _checkVerb(
  Task task,
  Set<String> knownVerbs,
  List<XtaskFormatException> problems,
) {
  final body = task.body;
  if (body is! DoBody || knownVerbs.contains(body.verb)) {
    return;
  }
  problems.add(
    XtaskFormatException(
      unknownVerb(task: task.name, verb: body.verb, known: knownVerbs),
      task.span,
    ),
  );
}

void _checkSetReferences(
  Task task,
  XtaskFile file,
  List<XtaskFormatException> problems,
) {
  for (final (key, name) in [
    ('each', task.each),
    ('all', task.all),
  ]) {
    if (name == null || file.sets.containsKey(name)) {
      continue;
    }
    problems.add(
      XtaskFormatException(
        noSuchSet(task: task.name, key: key, name: name),
        task.span,
      ),
    );
  }
}

/// Cycles and dangling `needs`/`then`, for every task rather than for one.
///
/// **Asked of the planner rather than reimplemented.** The order and the
/// cycle rule live in `graph.dart`; a second walk here would be a second
/// answer to the same question, free to drift from the one that actually runs.
/// Planning every task also reaches a cycle nothing depends on, which planning
/// one entry point never would.
void _checkGraph(XtaskFile file, List<XtaskFormatException> problems) {
  final seen = <String>{};
  // **What a plan that succeeded has already walked.** Planning a task a
  // successful plan reached walks a subgraph of what was just walked, so it
  // can only succeed too — nothing is lost by skipping it, and the walk of an
  // n-task chain stops being n walks of it. A four-thousand task file spent
  // fifty-five seconds here.
  //
  // Still in declaration order, because [ValidationReport] promises problems
  // in the order they were found and seeding from the entry points instead
  // would report the same ones in a different one.
  final covered = <String>{};
  for (final name in file.tasks.keys) {
    if (covered.contains(name)) {
      continue;
    }
    try {
      covered.addAll(planRun(file, name).names);
    } on XtaskFormatException catch (problem) {
      // The same ring is reachable from every task on it, so it would
      // otherwise be reported once per member.
      if (seen.add(problem.message)) {
        problems.add(problem);
      }
    }
  }
}

/// Every gate set a task names is one the file declares, and every declared
/// one has members.
///
/// **A gate set that existed by being mentioned could not be misspelled**, so
/// `gate: [chekc]` was simply a different gate set — one nothing ran, and one
/// nothing could name as missing. §1's green result nobody checked, from one
/// transposed letter.
void _checkDeclaredGates(XtaskFile file, List<XtaskFormatException> problems) {
  final declared = file.gates.keys.toSet();
  final used = <String>{for (final task in file.tasks.values) ...task.gate};

  if (declared.isEmpty) {
    if (used.isNotEmpty) {
      problems.add(
        XtaskFormatException(
          'this file uses gate sets — ${_quoted(used)} — and declares none. '
          'Write `gates: [${(used.toList()..sort()).join(', ')}]` at the top: '
          'a name that is only ever mentioned cannot be misspelled, because '
          'the misspelling is a new gate set',
        ),
      );
    }
    return;
  }

  for (final task in file.tasks.values) {
    for (final gate in task.gate) {
      if (declared.contains(gate)) {
        continue;
      }
      problems.add(
        XtaskFormatException(
          'task `${task.name}` names the gate set `$gate`, which `gates:` does '
          'not declare. Declared: ${_quoted(declared)}',
          task.span,
        ),
      );
    }
  }

  for (final entry in file.gates.entries) {
    if (tasksInGate(file, entry.key).isNotEmpty) {
      continue;
    }
    problems.add(
      XtaskFormatException(
        'gate set `${entry.key}` is declared and no task is in it, so running '
        'it checks nothing. A gate that examined nothing is worse than no '
        'gate at all: it reports the same green as one that passed',
        entry.value,
      ),
    );
  }
}

/// A gate set and a task may not share a name.
///
/// **Because a person types one name.** A gate set used to BE a task, so
/// `xtask check` was unambiguous by construction. Now the two are different
/// kinds of thing reached by one word, and a file where `check` is both leaves
/// the command line with a question nothing in the file answers.
///
/// An edge naming a gate set is the same problem from the other side, and the
/// planner says so where it walks the edges — one sentence, from the place
/// that has the route.
void _checkNoNameCollision(
  XtaskFile file,
  List<XtaskFormatException> problems,
) {
  for (final gate in file.gates.keys) {
    if (!file.tasks.containsKey(gate)) {
      continue;
    }
    // The planner's sentence, not a third wording of it.
    problems.add(bothAGateSetAndATask(gate, file.tasks[gate]!.span));
  }
}

/// A token only one task holds, and a `serial:` with nothing to serialise.
///
/// **Both are a key that does nothing, said out loud.** `exclusive:` keeps two
/// tasks apart; a name only one task writes keeps it apart from nobody, and
/// reads in the file as a guarantee that is being made. `serial:` orders the
/// members of an `each:`, and on a task with no `each:` there is one body and
/// nothing to order.
void _checkExclusive(XtaskFile file, List<XtaskFormatException> problems) {
  // Distinct TASKS, not occurrences: `exclusive: [db, db]` on one task counted
  // as two holders and slipped past the very check below.
  final holders = <String, Set<String>>{};
  for (final task in file.tasks.values) {
    for (final token in task.exclusive) {
      holders.putIfAbsent(token, () => {}).add(task.name);
    }
    if (task.serial && task.each == null) {
      problems.add(
        XtaskFormatException(
          'task `${task.name}` is `serial:` and has no `each:`, so there is '
          'one body and nothing for it to be in order with',
          task.span,
        ),
      );
    }
  }

  for (final entry in holders.entries) {
    if (entry.value.length > 1) {
      continue;
    }
    problems.add(
      XtaskFormatException(
        'task `${entry.value.single}` holds `${entry.key}` exclusively and no '
        'other task asks for it, so nothing is being kept apart. Name it in '
        'the other task too, or drop it',
        file.tasks[entry.value.single]!.span,
      ),
    );
  }
}

String _quoted(Iterable<String> names) =>
    (names.toList()..sort()).map((name) => '`$name`').join(', ');

/// A set that expands to nothing (§4.2), found without running anything.
void _checkSetsExpand(
  XtaskFile file,
  SetExpander sets,
  List<XtaskFormatException> problems,
) {
  file.sets.forEach((name, set) {
    try {
      sets.expand(name, set);
    } on EmptySetException catch (problem) {
      // **Only the emptiness is passed over, and only where the set said its
      // members are made by the run.** Skipping the whole expansion took the
      // repository boundary and the pattern syntax with it: `include:
      // ['/etc/host*']` validated clean, and the fence it dropped is the one
      // whose reason is that a set is fed to verbs that delete.
      //
      // Read off the refusal rather than worked out from the set again: the
      // rule is `sets.dart`'s, and a copy here is a copy that can disagree.
      if (problem.onlyYet) {
        return;
      }
      problems.add(problem);
    } on XtaskFormatException catch (problem) {
      problems.add(problem);
    }
  });
}
