/// `--validate` — the first gate any project should adopt.
library;

import 'boundary.dart';
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

/// A task with no body, nothing to depend on and no gate set to gather is a
/// task that does nothing (§8).
void _checkDoesSomething(Task task, List<XtaskFormatException> problems) {
  if (task.body != null || task.needs.isNotEmpty) {
    return;
  }
  problems.add(
    XtaskFormatException(
      'task `${task.name}` has no body and no `needs:`, so running it does '
      'nothing. A gate set gathers tasks; a task that gathers nothing is a '
      'name with a description attached',
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
      'task `${task.name}` names the verb `${body.verb}`, which is neither '
      'built in nor registered by this project. The engine ships no project '
      'verbs${knownVerbs.isEmpty ? '' : ' — known: '
                '${(knownVerbs.toList()..sort()).join(', ')}'}',
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
        'task `${task.name}` has `$key: $name`, and there is no set called '
        '`$name`',
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
  for (final name in file.tasks.keys) {
    try {
      planRun(file, name);
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
    problems.add(
      XtaskFormatException(
        '`$gate` is both a gate set and a task, and a person types one name. '
        'Rename one of them: a gate set is run by being named, so there is '
        'nothing left for a task of the same name to be',
        file.tasks[gate]!.span,
      ),
    );
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
    } on XtaskFormatException catch (problem) {
      problems.add(problem);
    }
  });
}
