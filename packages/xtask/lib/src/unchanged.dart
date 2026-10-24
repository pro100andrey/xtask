/// `unchanged:` — what a set's files held, and what became of it.
///
/// The question every freshness gate asks: generated code is committed, so
/// regenerating it must change nothing. Projects wrote it as a verb each — one
/// read the files before and after, one asked `git status`, one built the
/// check into the generator — and each covered a different part of it. This
/// is the part they share, asked by the engine: the files a set names, byte
/// for byte, before and after.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'exit_codes.dart';
import 'model.dart';
import 'sets.dart';

/// Why [task]'s `unchanged:` cannot be compared, or null when it can.
///
/// **One sentence for every reader**: `--validate` reports it when the file
/// is read, and `--dry-run` and the run refuse it, through [unchangedReach],
/// before any task has started — a gate that could not compare must not run
/// the generator and then say nothing.
String? unchangedRefusal(Task task, Map<String, NamedSet> sets) {
  final name = task.unchanged;
  if (name == null) {
    return null;
  }
  final set = sets[name];
  if (set == null) {
    return noSuchSet(task: task.name, key: 'unchanged', name: name);
  }
  if (set is ValueSet) {
    // Values are not paths, and the engine has been told so: there is no
    // file called `dev` to read, and reading one anyway would compare
    // whatever happened to be lying at the root under that name.
    return 'task `${task.name}` has `unchanged: $name`, and set `$name` holds '
        'values rather than paths, so there are no files to compare. Name a '
        'set of paths: a list, or a glob';
  }
  return null;
}

/// What a set reaches: its members, or none and the set's own refusal.
///
/// `empty` is kept rather than thrown, because a set the run is about to
/// fill is empty before it and that is a change, not a mistake. Only a set
/// empty before AND after has nothing to compare.
typedef Reach = ({List<String> members, EmptySetException? empty});

/// What [task]'s `unchanged:` set reaches when the run begins, or why it
/// cannot be compared.
///
/// **One answer for `--dry-run` and the run**, which had two: the dry run
/// asked [unchangedRefusal] alone and answered 0 for a set the run then
/// refused with 2 — one outside the root, a pattern that is no pattern, a
/// set empty with nothing in the run to fill it. Every refusal here is known
/// before anything has run, and the run says them before anything does: a
/// gate that cannot compare must not run the generator first.
///
/// An empty set is refused here unless a task is to make it (`produced-by:`),
/// the rule every other reader of a set keeps. Before this, the run read such
/// a set as a moment rather than a mistake and refused it only at the end,
/// after the generator — answering 1, "added", where the generator wrote
/// into it and 2 where it did not.
///
/// Throws [RunFailure].
Reach unchangedReach(
  SetExpander expander,
  Task task,
  Map<String, NamedSet> sets,
) {
  if (unchangedRefusal(task, sets) case final refusal?) {
    throw RunFailure(ExitCode.invalidFile, refusal);
  }
  final name = task.unchanged!;
  final reach = _reach(expander, task, name, sets[name]!);
  if (reach.empty case final empty? when !empty.onlyYet) {
    throw RunFailure(
      ExitCode.invalidFile,
      'task `${task.name}` has nothing to compare:\n$empty',
    );
  }
  return reach;
}

/// The members of set [name], for [task]: an empty set kept, anything else
/// the set refuses thrown as the task's [RunFailure], since a set that cannot
/// be expanded stops a task wherever it is read.
Reach _reach(SetExpander expander, Task task, String name, NamedSet set) {
  try {
    return (members: expander.expand(name, set), empty: null);
  } on EmptySetException catch (problem) {
    return (members: const <String>[], empty: problem);
  } on XtaskFormatException catch (problem) {
    throw RunFailure(
      ExitCode.invalidFile,
      'task `${task.name}` cannot run:\n$problem',
    );
  }
}

/// Every file a set reaches, by its path from the root, with its bytes.
///
/// [empty] is the set's own refusal when it had no members — see [Reach].
final class Holding {
  const Holding(this.files, {this.empty});

  final Map<String, Uint8List> files;

  final EmptySetException? empty;
}

/// What set [name] holds on disk now, for [task]: what [reach] found, where
/// the caller has already expanded it, and otherwise the set expanded here.
///
/// A member that is a directory is every file beneath it: a set of generated
/// TREES, one directory per target, is how one project names them, and
/// comparing the directory as an entry would see nothing that happened
/// inside it. A link is not followed and not read, as the set walk follows
/// none; a member that is not there is simply not held, so one that appears
/// is a file added.
///
/// Throws [RunFailure]: a set that cannot be read stops the task as a set
/// that cannot be expanded does.
Holding holding(
  SetExpander expander,
  Task task,
  String name,
  NamedSet set, {
  Reach? reach,
}) {
  final (:members, :empty) = reach ?? _reach(expander, task, name, set);
  if (empty != null) {
    return Holding(const {}, empty: empty);
  }

  final files = <String, Uint8List>{};
  void read(String relative) {
    final path = p.joinAll([expander.root, ...p.posix.split(relative)]);
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        files[relative] = File(path).readAsBytesSync();
      } else if (type == FileSystemEntityType.directory) {
        final entries = Directory(path).listSync(followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          read('$relative/${p.basename(entry.path)}');
        }
      }
      // Absent, a link, or something that is neither: nothing to hold.
    } on FileSystemException catch (problem) {
      // Refused rather than passed over, for the reason the set walk gives: a
      // file that cannot be read may be the one that changed, and a check
      // that quietly read less is a green nobody earned.
      throw RunFailure(
        ExitCode.taskFailed,
        'task `${task.name}` cannot read `$relative` of set `$name`: '
        '${problem.osError?.message ?? problem.message}',
      );
    }
  }

  members.forEach(read);
  return Holding(files);
}

/// What changed between [before] and [after], one line per file, by path.
///
/// Empty when nothing did. A file added and a file removed are changes like
/// any other: a generator that stopped writing one is as stale as one that
/// writes it differently.
List<String> changes(Holding before, Holding after) {
  final paths = {...before.files.keys, ...after.files.keys}.toList()..sort();
  return [
    for (final path in paths)
      if (_change(before.files[path], after.files[path]) case final change?)
        '$change  $path',
  ];
}

/// What happened to one file, padded so that the paths line up, or null.
String? _change(Uint8List? was, Uint8List? now) => switch ((was, now)) {
  (null, _) => 'added  ',
  (_, null) => 'removed',
  (final was?, final now?) => _same(was, now) ? null : 'changed',
};

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var at = 0; at < a.length; at++) {
    if (a[at] != b[at]) {
      return false;
    }
  }
  return true;
}

/// The failure a task that changed its `unchanged:` set ends with.
///
/// The files are named, a screenful at most: the fix is to look at them, and
/// a list that has to be found again in `git status` is half an answer.
RunFailure changedASet(Task task, String set, List<String> changed) {
  const shown = 20;
  final opening =
      'task `${task.name}` changed what set `$set` holds, and it is to leave '
      'it as the run found it:';
  // Left as the task wrote them, and said so: the regenerated files are the
  // fix, and putting the old ones back would only make somebody run the
  // generator again to get them.
  const advice =
      'They are left as the task wrote them. If they are what the sources '
      'make now, review them and commit them';
  return RunFailure(
    ExitCode.taskFailed,
    [
      opening,
      for (final line in changed.take(shown)) '  $line',
      if (changed.length > shown) '  … and ${changed.length - shown} more',
      advice,
    ].join('\n'),
  );
}
