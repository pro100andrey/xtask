// This repository's own entry point, and the shape `packages/xtask/doc/
// dart-verbs.md` asks every consumer to write: the project owns the entry
// point, because the project owns the verbs. A project with verbs passes them
// here —
//
//   exitCode = await runXtask(args, verbs: {'regen': regen});
//
// — and this repository registers the two publishes: each package to pub,
// in the mode that skips a version pub.dev already serves, so `xtask
// publish` uploads what a release bumped and nothing else.
//
// The file name is the declaration. `dart run :xtask` resolves to this path and
// nothing else; no manifest entry names it. The installed `xtask` is a
// different file — `packages/xtask/bin/xtask.dart` — and hands a run here.
import 'dart:io';

import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXtask(
    args,
    verbs: {
      'publish-xtask': pubPublish(
        const PubPackage('packages/xtask', alreadyServed: AlreadyServed.skip),
      ),
      'publish-kit': pubPublish(
        const PubPackage(
          'packages/xtask_kit',
          alreadyServed: AlreadyServed.skip,
        ),
      ),
    },
  );
}
