/// `--validate` — the first gate any project should adopt.
library;

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
  }

  _checkGraph(file, problems);
  _checkGates(file, problems);
  if (sets != null) {
    _checkSetsExpand(file, sets, problems);
  }

  return ValidationReport(List.unmodifiable(problems));
}

/// A task with no body, nothing to depend on and no gate set to gather is a
/// task that does nothing (§8).
void _checkDoesSomething(Task task, List<XtaskFormatException> problems) {
  if (task.body != null || task.needs.isNotEmpty || task.collects != null) {
    return;
  }
  problems.add(
    XtaskFormatException(
      'task `${task.name}` has no body, no `needs:` and no `collects:`, so '
      'running it does nothing. A composite gathers something; a task that '
      'gathers nothing is a name with a description attached',
      task.span,
    ),
  );
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
    ('argv-from', task.argvFrom),
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

/// An orphan gate: a task that believes it is checked and is not (§8).
void _checkGates(XtaskFile file, List<XtaskFormatException> problems) {
  final collected = collectedGates(file);

  for (final task in file.tasks.values) {
    for (final gate in task.gate) {
      if (collected.contains(gate)) {
        continue;
      }
      problems.add(
        XtaskFormatException(
          'task `${task.name}` is in the gate set `$gate`, and no task '
          'collects it — so nothing ever runs it. That is worse than being in '
          'no gate at all: the task looks checked and is not'
          '${collected.isEmpty ? '' : '. Collected: '
                    '${(collected.toList()..sort()).join(', ')}'}',
          task.span,
        ),
      );
    }
  }
}

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
