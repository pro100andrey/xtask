// This repository's own entry point, and the shape the README asks every
// consumer to write: the project owns the entry point, because the project owns
// the verbs. A project with verbs passes them here —
//
//   exitCode = await runXtask(args, verbs: {'regen': regen});
//
// — while this repository registers none yet: the built-in `remove` is the
// engine's, and no job here needs real logic so far.
//
// The file name is the declaration. `dart run :xtask` resolves to this path and
// nothing else; no manifest entry names it. The installed `xtask` is a
// different file — `packages/xtask/bin/xtask.dart` — and hands a run here.
import 'dart:io';

import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXtask(args);
}
