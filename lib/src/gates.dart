/// What is in a gate set.
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
