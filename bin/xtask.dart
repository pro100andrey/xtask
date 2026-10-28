// This repository's own entry point, and the shape `packages/xtask/doc/
// dart-verbs.md` asks every consumer to write: the project owns the entry
// point, because the project owns the verbs. A project with verbs passes them
// here —
//
//   exitCode = await runXtask(args, verbs: {'regen': regen});
//
// — and this repository registers one: `publish`, a package to pub, the
// directory its task hands it, in the mode that skips a version pub.dev
// already serves, so `xtask publish` uploads what a release bumped and
// nothing else.
//
// The file name is the declaration. `dart run :xtask` resolves to this path and
// nothing else; no manifest entry names it. The installed `xtask` is a
// different file — `packages/xtask/bin/xtask.dart` — and hands a run here.
import 'dart:io';

import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXtask(args, verbs: {'publish': _publish});
}

/// `do: publish` — the package `args:` names, published to pub unless
/// pub.dev serves its version already.
Future<int> _publish(VerbContext context) async {
  if (context.args case [final directory]) {
    return publishToPub(
      context,
      PubPackage(directory, alreadyServed: AlreadyServed.skip),
    );
  }
  context.log('publish: which package? `args: [<directory>]`');
  return ExitCode.invalidFile;
}
