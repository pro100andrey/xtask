/// Gate sets and the `collects:` derivation — §4.3 and §7.1 of `xtask.md`.
library;

import 'model.dart';

/// Every task in gate set [gate], in **declaration order**.
///
/// The order is the order they appear in the file, which is meaningful — cheap
/// gates before slow ones — and is the only place ordering is implicit (§4.3).
/// It rests on the parser keeping a mapping's key order; `parse` pins that with
/// a test rather than trusting it, because the YAML specification does not
/// promise it and every implementation does.
List<Task> tasksInGate(XtaskFile file, String gate) => [
  for (final task in file.tasks.values)
    if (task.gate.contains(gate)) task,
];

/// Every gate set [file] mentions — declared membership or collection.
///
/// **Existing and being runnable are different questions**, and this answers
/// the first. A gate set exists as soon as a task says it is in one, whether
/// or not any composite gathers it; whether a gate nothing collects is a
/// MISTAKE is §8's question, and `--validate` answers it. Both used to be
/// worked out inline wherever they were needed — three separate expressions
/// over `file.tasks.values` — which is one concept with no owner.
Set<String> gateSets(XtaskFile file) => {
  for (final task in file.tasks.values) ...task.gate,
  ...collectedGates(file),
};

/// Every gate set some composite collects, and which can therefore be run.
Set<String> collectedGates(XtaskFile file) => {
  for (final task in file.tasks.values)
    if (task.collects != null) task.collects!,
};

/// [file] with every `collects:` composite given the members it collects.
///
/// **The seam between gates and the graph.** `graph.dart` knows `needs:` and
/// `then:` and nothing about gate sets; teaching it a third kind of edge would
/// give the run order two authors. Instead a composite is rewritten into an
/// ordinary task whose `needs:` are its gate's members, and the planner then
/// answers the same question it always answers.
///
/// Collected members are appended **after** any `needs:` the composite wrote
/// itself, so a composite that wants something to happen before its gate — a
/// dependency fetch, say — still gets it first.
XtaskFile withCollectedGates(XtaskFile file) {
  final rewritten = <String, Task>{};
  file.tasks.forEach((name, task) {
    final gate = task.collects;
    rewritten[name] = gate == null
        ? task
        : _collecting(task, tasksInGate(file, gate));
  });

  return XtaskFile(
    version: file.version,
    sets: file.sets,
    tasks: Map.unmodifiable(rewritten),
  );
}

Task _collecting(Task composite, List<Task> members) => Task(
  name: composite.name,
  span: composite.span,
  desc: composite.desc,
  args: composite.args,
  argvFrom: composite.argvFrom,
  each: composite.each,
  workingDirectory: composite.workingDirectory,
  env: composite.env,
  envRequired: composite.envRequired,
  needs: List.unmodifiable([
    ...composite.needs,
    // A composite that collects a gate it is itself in would need itself,
    // which the planner would report as a cycle. It is a plausible thing to
    // write — `check` in gate `check` — and the answer is that gathering a set
    // does not mean gathering yourself.
    for (final member in members)
      if (member.name != composite.name) member.name,
  ]),
  then: composite.then,
  gate: composite.gate,
  collects: composite.collects,
);
