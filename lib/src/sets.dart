import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'boundary.dart';
import 'errors.dart';
import 'globs.dart';
import 'model.dart';

/// Why task [task]'s `[key]: [name]` names a set the file has not got.
///
/// One sentence for a rule two readers report: `--validate` when the file is
/// read, the resolver when a run reaches the task.
String noSuchSet({
  required String task,
  required String key,
  required String name,
}) => 'task `$task` has `$key: $name`, and there is no set called `$name`';

/// Turning a named set into the strings a task is given.
///
/// Sets exist so a task can iterate without a loop and pass file arguments
/// without `$(shell find …)`. That is only worth anything if the expansion is
/// the engine's: a shell doing it brings back the portability problem the whole
/// design is arranged around.
final class SetExpander {
  SetExpander({required this.root});

  /// The directory patterns are relative to, and **may not leave** — see
  /// [_refuseUnrooted].
  final String root;

  /// The members of [set], as the arguments a task receives.
  ///
  /// The answer is unmodifiable, and both branches answer alike. The list arm
  /// used to hand back the parsed model's own list while the glob arm built a
  /// fresh one, so the obvious `expand(...)..addAll(task.args)` worked against
  /// a glob and permanently poisoned a list — in a gate set, the second
  /// task sharing an `all:` would receive the first one's arguments
  /// appended to the file list, and the gate would go green having checked the
  /// wrong thing. Invisible for globs, which is most of the suite.
  List<String> expand(String name, NamedSet set) {
    final members = switch (set) {
      // Checked one by one, and this is not decoration: a written member met
      // no boundary at all until it did, so `['/etc', '../..']` expanded to
      // real paths and reached a working directory and a verb that deletes.
      // The glob arm has been refusing the same thing since it was written;
      // the two arms disagreeing was the hole.
      //
      // **Written order, not sorted.** §4.2 promises a deterministic order so
      // that an argument list does not depend on the filesystem — it does not
      // ask for an author's list to be rearranged. `each: test-packages` runs
      // in this order, somebody chose it, and R2's whole claim is that what is
      // written is what happens.
      //
      // Members are literal. Globs among them — §12's `build-outputs` has
      // three — are `remove`'s to expand under §6's rule that a missing path
      // is not an error, which is why `clean` may run twice.
      ListSet(:final members) => [
        for (final member in members) _refuseUnrooted(name, set, member),
      ],
      // **Not asked whether they leave the repository, because they are not
      // paths.** That question refused `a:b` for looking like a Windows
      // drive, and it has no meaning at all about `dev` or `stable`. A set
      // that says what it holds is asked the right questions.
      ValueSet(:final values) => values,
      GlobSet() => _matches(name, set),
    };
    _refuseEmpty(name, set, members);
    return List.unmodifiable(members);
  }

  /// Everything under [root] the include patterns reach, minus the exclusions.
  ///
  /// **One walk, done here rather than by `Glob.listSync`.** That method
  /// refuses outright when the glob's path style is not the platform's
  /// (`glob.dart:145`), and every pattern here is POSIX by design — so the
  /// whole feature threw a `StateError` on Windows, past §5.3's exit codes and
  /// past `--validate`, which §8 says must check globs without running
  /// anything. Walking here also means one pass instead of one per pattern
  /// variant, and it means the walk can be **pruned**, which is what makes an
  /// exclusion protective rather than decorative.
  List<String> _matches(String name, GlobSet set) {
    final includes = _globs(name, set, set.include);
    final excludes = _globs(name, set, set.exclude);
    // A directory whose contents are all excluded is itself excluded. Without
    // this, `**/test_data/**` — which needs a segment after `test_data` —
    // leaves the directory itself a member, and §6's `remove` then deletes
    // recursively exactly the files the exclusion was written to protect.
    final prunes = _globs(name, set, [
      for (final pattern in set.exclude)
        if (pattern.endsWith('/**')) pattern.substring(0, pattern.length - 3),
    ]);

    final reach = Reach(set.include);

    final found = <String>[];
    void walk(Directory directory) {
      // Sorted here as well as at the end: a directory listing is in whatever
      // order the filesystem felt like, and a walk that descends in that order
      // is a walk whose failure messages arrive in it too.
      final List<FileSystemEntity> entries;
      try {
        entries = directory.listSync(followLinks: false).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
      } on FileSystemException catch (problem) {
        // **Unless it simply went away.** A directory removed while this walk
        // is inside it — by a `do: remove` running beside this task, or by
        // anything else on the machine — has nothing left to be short of, and
        // calling that "the file was refused" answers a machine race with a
        // code documented as never being the code's fault.
        if (!directory.existsSync()) {
          return;
        }
        // **Refused, not skipped.** A directory this process cannot read may
        // hold members, so passing over it makes the set quietly smaller than
        // the file says — a gate that examined fewer files and went green,
        // which is the failure this whole tool is against.
        //
        // Refused HERE, because unhandled it left `--validate` on a stack
        // trace and exit 255, a number §5.3 does not have, from the one gate
        // the README tells every project to put in CI.
        throw XtaskFormatException(
          'set `$name` cannot be read: `${_relative(directory.path)}` is not '
          'listable — ${problem.osError?.message ?? problem.message}. This is '
          'about this machine rather than the file, and it is refused rather '
          'than passed over: a directory that cannot be read may hold members, '
          'and a set that is quietly short is a gate that checked less than it '
          'says',
          set.span,
        );
      }
      for (final entry in entries) {
        // §6 says `remove` never follows a symlink. Listing takes the same
        // line, and for a second reason: a link into an ancestor is a loop.
        if (entry is Link) {
          continue;
        }
        final relative = _relative(entry.path);
        if (excludes.any((g) => g.matches(relative))) {
          continue;
        }
        if (entry is Directory && prunes.any((g) => g.matches(relative))) {
          continue;
        }
        if (includes.any((g) => g.matches(relative))) {
          found.add(relative);
        }
        // **Pruned on the includes, not only on the exclusions**, and only the
        // DESCENT is pruned — a directory can be a member itself, which is how
        // `packages/*/coverage` reaches a directory to delete.
        //
        // Include patterns were used to match and never to prune, so
        // `include: ['src/**/*.ts']` walked all of `node_modules` and all of
        // `.git` — once per set, per task, per run — to find nothing there by
        // construction.
        if (entry is Directory && reach.into(relative)) {
          walk(entry);
        }
      }
    }

    walk(Directory(root));
    return found..sort();
  }

  /// Every reading of every pattern, as globs, refusing what cannot be one.
  List<Glob> _globs(String name, NamedSet set, List<String> patterns) => [
    for (final pattern in patterns)
      for (final variant in zeroOrMoreDirectories(
        _refuseUnrooted(
          name,
          set,
          pattern,
        ),
      ))
        _glob(name, set, variant),
  ];

  /// [written] unchanged, or a refusal if it names anything outside [root].
  ///
  /// **`root` is a boundary, not a default.** An absolute pattern or one
  /// climbing through `..` used to walk wherever it liked — `include:
  /// ['/etc/hos*']` came back with real paths — and handing those to §6's
  /// `remove`, which deletes recursively and treats a missing path as fine, is
  /// deletion outside the repository with no diagnostic and nothing
  /// `--validate` could see.
  ///
  /// Applied to a written member as well as to a pattern, because what a set
  /// hands on is the same string either way. The test itself lives in
  /// [leavesRoot], so that the fence has one gate rather than a copy per
  /// caller.
  String _refuseUnrooted(String name, NamedSet set, String written) {
    if (!leavesRoot(written)) {
      return written;
    }
    throw XtaskFormatException(
      'set `$name` reaches outside the repository with `$written`. What a set '
      'names is relative to the root and stays there: a set is fed to verbs '
      "that delete, and a path the repository does not own is not this file's "
      'to name'
      '${_drivePrefixed(written) ? ' — one letter and a colon reads as a '
                'Windows drive, whatever it was meant as' : ''}',
      set.span,
    );
  }

  /// Whether [written] is refused for looking like `C:` rather than for
  /// anything about paths — the one shape whose refusal needs explaining.
  static bool _drivePrefixed(String written) =>
      written.length > 1 &&
      written[1] == ':' &&
      RegExp('[A-Za-z]').hasMatch(written[0]);

  /// A pattern is always read as POSIX, whatever the host is.
  ///
  /// `xtask.yaml` is committed and read on every platform, so
  /// `packages/**/*.lake` has to mean the same thing on all of them. Handing
  /// the host's own context to `Glob` would make `/` a separator on one
  /// platform and `\` on another, and the file would quietly match different
  /// things depending on who ran it. Matching, unlike listing, does not care
  /// which platform it runs on.
  Glob _glob(String name, NamedSet set, String pattern) {
    try {
      return Glob(pattern, context: p.posix);
    } on FormatException catch (e) {
      // `[`, `a{b`, `{` — the typos this is most likely to meet. Unwrapped,
      // they escaped as a scanner exception whose "line 1, column 2" pointed
      // inside the pattern string rather than at the line of xtask.yaml.
      throw XtaskFormatException(
        '`$pattern` in set `$name` is not a valid pattern: ${e.message}',
        set.span,
      );
    }
  }

  /// [path] relative to [root], written with `/` on every platform.
  ///
  /// The separator is normalised for the same reason the patterns are: this
  /// string becomes a process argument, and an argument list that differs
  /// between platforms is a portability claim with a hole in it. Windows
  /// accepts `/` in paths; the tools this passes them to accept it too.
  String _relative(String path) => relativePosix(path, root: root);

  /// An expansion that found nothing is an error, and there is no key to
  /// soften it (§4.2).
  ///
  /// A task whose `all:` came back empty runs its body with no arguments,
  /// and `dart format` with no arguments formats the whole tree. The worse
  /// case is quieter: inside a gate, the set was empty, the task passed, the
  /// gate went green and nothing was checked — defect 3 of §1 reproduced by a
  /// new route. A pattern matches nothing for two reasons, the repository
  /// genuinely having none and the pattern being broken, and in a gate the
  /// second is the dangerous one.
  void _refuseEmpty(String name, NamedSet set, List<String> members) {
    if (members.isNotEmpty) {
      return;
    }
    final detail = switch (set) {
      ListSet() => 'it is written with no members',
      ValueSet() => 'its `values:` are written with no members',
      // Blames the exclusion only when there was something for it to remove;
      // otherwise it points at a pattern that matched nothing, which is the
      // typo actually worth reporting.
      GlobSet(:final include, :final exclude) =>
        'nothing under the repository root matches ${_quoted(include)}'
            '${exclude.isEmpty ? '' : ', with or without ${_quoted(exclude)}'}',
    };
    throw EmptySetException(
      'set `$name` is empty — $detail. An empty set is refused rather than '
      'passed on: a task given no arguments where it expected files does not '
      'fail, it succeeds having done nothing, and in a gate that is a green '
      'result nobody checked',
      set.span,
      // **The one place this is decided.** `produced:` says the members are
      // made by the run, so before the task that makes them has run this
      // emptiness is a moment rather than a mistake. Every reader used to
      // work that out again from the set it happened to be holding.
      onlyYet: set is GlobSet && set.produced,
    );
  }

  String _quoted(List<String> patterns) =>
      patterns.map((pattern) => '`$pattern`').join(', ');
}
