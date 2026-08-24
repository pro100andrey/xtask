// This repository's own entry point, and the shape the README asks every
// consumer to write: the project owns the entry point, because the project owns
// the verbs. A project with verbs passes them here —
//
//   exitCode = await runXtask(args, verbs: {'regen': regen});
//
// — while `xtask` itself registers none yet: the built-in `remove` is the
// engine's, and no job in this repository needs real logic so far.
//
// The file name is the declaration. `dart run :xtask` resolves to this path and
// nothing else; no manifest entry names it.
import 'dart:io';

import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXtask(args);
}
