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

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:xtask/xtask.dart';
import 'package:xtask_kit/xtask_kit.dart';
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXtask(args, verbs: {'publish': _publish});
}

/// `do: publish` — the package `args:` names, published to pub unless
/// pub.dev serves its version already, and waited for only where another
/// package here needs the version it uploads ([_neededNext]).
Future<int> _publish(VerbContext context) async {
  if (context.args case [final directory]) {
    return publishToPub(
      context,
      PubPackage(
        directory,
        alreadyServed: AlreadyServed.skip,
        waitUntilServed: await _neededNext(context, directory),
      ),
    );
  }
  context.log('publish: which package? `args: [<directory>]`');
  return ExitCode.invalidFile;
}

/// Whether a package beside [directory] under `packages/` depends on it with
/// a constraint no version pub.dev serves yet allows — so that it needs the
/// one about to be uploaded, and resolves against pub.dev for it. Waiting
/// then is what keeps it from failing for a reason that is not its own;
/// otherwise the wait is ten minutes spent on nothing.
///
/// `dependencies:` only: a dev dependency is not what a package's users
/// resolve. Anything this cannot read — a manifest, the registry — is a wait,
/// which costs minutes, where guessing wrong costs a broken release.
Future<bool> _neededNext(VerbContext context, String directory) async {
  try {
    final name = manifestField(
      context.file(p.join(directory, 'pubspec.yaml')).readAsStringSync(),
      'name',
    );
    if (name == null) {
      return true;
    }
    final constraints = <VersionConstraint>[
      for (final other in context.directory('packages').listSync())
        if (other is Directory &&
            !p.equals(other.path, context.directory(directory).path))
          if (File(p.join(other.path, 'pubspec.yaml')) case final pubspec
              when pubspec.existsSync())
            ?_constraintOn(pubspec.readAsStringSync(), name),
    ];
    if (constraints.isEmpty) {
      return false;
    }
    // pub.dev, which is where this repository's packages go.
    final served = [
      for (final version in await askRegistry('https://pub.dev', name))
        Version.parse(version),
    ];
    return constraints.any(
      (constraint) => !served.any(constraint.allows),
    );
  } on Object {
    return true;
  }
}

/// The constraint [text], a `pubspec.yaml`, puts on [name] in its
/// `dependencies:`, or null where it has none there.
VersionConstraint? _constraintOn(String text, String name) {
  final dependencies =
      (loadYaml(text) as Map<Object?, Object?>)['dependencies'];
  if (dependencies is! Map<Object?, Object?> ||
      !dependencies.containsKey(name)) {
    return null;
  }
  return switch (dependencies[name]) {
    final String constraint => VersionConstraint.parse(constraint),
    {'version': final String constraint} => VersionConstraint.parse(
      constraint,
    ),
    _ => VersionConstraint.any,
  };
}
