/// The built-in verbs, and the whole of the list.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'boundary.dart';
import 'context.dart';
import 'errors.dart';
import 'exit_codes.dart';
import 'globs.dart';

/// Every verb the engine ships.
///
/// **A closed list, and adding to it is a decision.** A primitive is added
/// only when a real task needs it, and only if it passes R3: total,
/// argument-driven, and never branching on the result of anything.
/// `remove: [paths]` qualifies; `test -f X && Y` does not. That rule is what
/// stops this from becoming a portable shell — the failure the npm ecosystem
/// took, one package per utility (`rimraf`, `mkdirp`, `cross-env`, `shx`), all
/// of them existing only because `package.json` scripts are shell.
///
/// Passed to the validator as the built-in half of what a `do:` may name, so
/// that no second list of these names exists anywhere (§8).
const builtInVerbNames = <String>{removeVerbName};

/// The name `remove` is written under in `do:`.
///
/// Spelled once, because three things name it: the closed list above, the
/// binding below, and the diagnostics that say what a set fed to it should
/// look like.
const removeVerbName = 'remove';

/// The built-in verbs, bound to the repository [root] they may act inside.
Map<String, Verb> builtInVerbs({required String root}) => {
  removeVerbName: (context) => removeVerb(context, root: root),
};

/// `remove` — deletes each path it is given (§6).
///
/// A path that does not exist is **not** an error. Directories go recursively.
/// Symlinks are removed, never followed. Globs are expanded here.
///
/// **The two sentences §6 appears to say at once, resolved.** It states that a
/// missing path is fine and that "an expansion matching nothing is an error
/// (§4.2)", which read together would make `clean` fail on a clean tree the
/// second time it runs — absurd for a task whose job is to leave nothing
/// behind. They are two different expansions:
///
/// - a **named set** expanding to nothing is an error (§4.2), because a task
///   given no files where it expected files succeeds having checked nothing;
/// - a **glob among this verb's arguments** matching nothing is not, because
///   "delete what is there" is satisfied by there being nothing.
///
/// §12's `build-outputs` is a list of four literals, three of which contain
/// glob characters. The set is never empty, so §4.2 never fires; the patterns
/// inside it are this verb's to expand, under this verb's rule.
Future<int> removeVerb(VerbContext context, {required String root}) async {
  for (final argument in context.args) {
    final refusal = _outsideRoot(argument);
    if (refusal != null) {
      context.log(refusal);
      return ExitCode.invalidFile;
    }

    final List<String> paths;
    try {
      paths = pathsMatching(argument, root: root);
    } on FormatException catch (problem) {
      // **The same refusal a set gets for the same typo.** Uncaught, a `[` or
      // an `a{b` among these arguments left the verb as a raw
      // `FormatException` whose "line 1, column 2" points inside the pattern
      // string rather than at anything in the file — reported as "task threw
      // FormatException", which sends the reader to look at this engine.
      context.log(
        '`remove` cannot read `$argument` as a pattern: ${problem.message}',
      );
      return ExitCode.invalidFile;
    }
    for (final path in paths) {
      await _delete(underRoot(root, path), context);
    }
  }
  return ExitCode.success;
}

/// Whether [argument] names anything the repository does not own.
///
/// The check that matters most in the file, because this is the verb that
/// deletes: an absolute path or one climbing through `..` would take a
/// recursive delete outside the repository, and §6's "a missing path is not an
/// error" means it would do so without a word.
String? _outsideRoot(String argument) {
  if (!leavesRoot(argument)) {
    return null;
  }
  return '`remove` refuses `$argument`: it names a path outside the '
      'repository. A verb that deletes recursively and treats a missing path '
      'as ordinary is the last place to take a path on trust';
}

/// What [argument] names on disk: itself, or everything its pattern matches.
///
/// **Public, because `--dry-run` has to be able to ask.** This is the verb that
/// deletes recursively, and a dry run that printed the PATTERN told a reader
/// least about the one operation they most want to check against what they
/// meant. Answering the question is not running the verb: nothing here removes
/// anything.
///
/// Throws [FormatException] for a pattern that will not compile, which the
/// caller turns into a sentence about the file.
List<String> pathsMatching(String argument, {required String root}) {
  if (!_looksLikeGlob(argument)) {
    // A literal. Returned whether or not it exists — the caller's business,
    // and §6 says a missing one is not an error.
    return [argument];
  }

  // **Read the same way `sets:` reads it.** This compiled the argument raw,
  // so `**/` meant "one directory or more" here and "none or more" over
  // there — two dialects in one file, and `clean` is written with exactly the
  // shape that tells them apart. A pattern has to mean one thing.
  final globs = [
    for (final variant in zeroOrMoreDirectories(argument))
      Glob(variant, context: p.posix),
  ];
  // Built once. Asked with `[argument]`, this allocated a single-element list
  // per directory and re-derived the pattern's shape inside every call.
  final reach = Reach([argument]);

  final found = <String>[];
  void walk(Directory directory) {
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      // **Passed over, and this is the opposite call from `sets`.** A set that
      // is quietly short is a gate that checked less than it says; a delete
      // that is quietly short leaves a file behind, which §6 already permits —
      // a missing path is not an error and `clean` may run twice. Raising here
      // instead left `--dry-run` on a stack trace and exit 255, and a
      // directory removed by another member while this one is walking is
      // ordinary rather than exceptional.
      return;
    }
    for (final entry in entries) {
      final relative = relativePosix(entry.path, root: root);
      if (globs.any((glob) => glob.matches(relative))) {
        found.add(relative);
        // Not descended into: it is about to be deleted whole, and listing
        // what is inside it only to delete the parent is work for nothing.
        continue;
      }
      // **Pruned, as `sets:` prunes.** This walked every directory under the
      // root looking for `build/**`, so `do: remove` read all of `.git` and
      // all of `node_modules` on every invocation to find nothing there by
      // construction — 0.19s against 0.01s on eighteen thousand files, and a
      // repository is bigger than that. `sets` was taught this and this was
      // not, which is one rule living in two walkers.
      if (entry is Directory && reach.into(relative)) {
        walk(entry);
      }
    }
  }

  if (Directory(root).existsSync()) {
    walk(Directory(root));
  }
  // Sorted, so that what a failure reports is the same on every machine.
  return found..sort();
}

bool _looksLikeGlob(String argument) =>
    argument.contains('*') ||
    argument.contains('?') ||
    argument.contains('[') ||
    argument.contains('{');

Future<void> _delete(String path, VerbContext context) async {
  // `Link` first, and by type rather than by asking the path: §6 says a
  // symlink is removed and never followed, and `Directory(link).delete` on a
  // link to a directory is exactly the "followed" case.
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.notFound:
      // Not an error, and not silent either: a `clean` that reports nothing is
      // indistinguishable from a `clean` that did nothing because its pattern
      // was wrong.
      return;
    // **Said after it happened, and only if it did.** The line went out first,
    // so a directory this process may not write reported `removed …` and then
    // failed — a true-looking sentence about a file that is still there.
    case FileSystemEntityType.link:
      await _deleting(path, () => Link(path).delete());
      context.log('removed link $path');
    case FileSystemEntityType.directory:
      await _deleting(path, () => Directory(path).delete(recursive: true));
      context.log('removed $path/');
    case FileSystemEntityType.file:
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      await _deleting(path, () => File(path).delete());
      context.log('removed $path');
  }
}

/// Runs [delete], turning a filesystem refusal into one this table has.
///
/// Unguarded, a permission error or a path another member removed first came
/// out through the general handler as "the project's own verb threw
/// PathAccessException", which sends the reader to look at a verb the engine
/// ships. A path that is simply gone is already answered above.
Future<void> _deleting(String path, Future<void> Function() delete) async {
  try {
    await delete();
  } on FileSystemException catch (problem) {
    throw RunFailure(
      ExitCode.taskFailed,
      '`remove` could not delete `$path`: '
      '${problem.osError?.message ?? problem.message}',
    );
  }
}

/// Every path `remove` would actually delete for [arguments] — what is on disk,
/// in the order it would go.
///
/// **What `--dry-run` prints under a `do: remove` block.** Every other body is
/// fully worked out by the time it is described: a `run:` shows the argv the
/// child will be handed. This one showed the PATTERN, so the one operation
/// that deletes recursively was the one a reader could not check against what
/// they meant.
///
/// It does not call the verb. It asks what the verb asks, and removes nothing.
/// Anything the run would refuse — a path outside the repository, a pattern
/// that will not compile — comes back empty here, because the run says why and
/// half a sentence is worse than none.
List<String> removeWouldDelete(
  List<String> arguments, {
  required String root,
}) {
  final found = <String>{};
  for (final argument in arguments) {
    if (leavesRoot(argument)) {
      return const [];
    }
    final List<String> matched;
    try {
      matched = pathsMatching(argument, root: root);
    } on FormatException {
      return const [];
    }
    for (final path in matched) {
      final at = underRoot(root, path);
      // §6 says a missing path is not an error, so a literal that is not there
      // is not something this would delete — and saying it would be a promise
      // about a file that does not exist.
      if (FileSystemEntity.typeSync(at, followLinks: false) !=
          FileSystemEntityType.notFound) {
        found.add(path);
      }
    }
  }
  return found.toList()..sort();
}
