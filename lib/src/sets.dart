import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'boundary.dart';
import 'errors.dart';
import 'model.dart';

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
  /// a glob and permanently poisoned a list — in a `collects:` gate, the second
  /// task sharing an `argv-from` would receive the first one's arguments
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

    final found = <String>[];
    void walk(Directory directory) {
      // Sorted here as well as at the end: a directory listing is in whatever
      // order the filesystem felt like, and a walk that descends in that order
      // is a walk whose failure messages arrive in it too.
      final entries = directory.listSync(followLinks: false).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
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
        if (entry is Directory) {
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
      for (final variant in _zeroOrMoreDirectories(
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
      'to name',
      set.span,
    );
  }

  /// [pattern], and the same pattern with each `**/` standing for no directory
  /// at all.
  ///
  /// **`package:glob` reads `**/` as one directory or more.** So
  /// `packages/**/*.lake` — a pattern of exactly the shape a monorepo writes
  /// — finds `packages/a/b.lake` and silently does not find
  /// `packages/b.lake`.
  /// Bash's `globstar`, git's ignore rules and every glob a person has met
  /// elsewhere read it as none or more, so the file would mean one thing to
  /// its author and another to this engine. The consequence is the one this
  /// whole tool is against: not an error, but a gate that examined fewer files
  /// than it was written to examine and went green anyway.
  Set<String> _zeroOrMoreDirectories(String pattern) {
    // Find the first `**` that stands as a WHOLE segment, skipping past any
    // that do not. Stopping at the first occurrence and giving up if it was
    // part of a larger token — as this did — abandons the zero-directory
    // reading of every later, legitimate one: `a**/b/**/c` was left untouched
    // entirely, and `{**/a,b}` never expanded because a brace preceded it.
    var index = pattern.indexOf('**/');
    while (index > 0 && pattern[index - 1] != '/') {
      index = pattern.indexOf('**/', index + 1);
    }
    if (index == -1) {
      return {pattern};
    }

    final withStar = pattern.substring(0, index + 3);
    final withoutStar = pattern.substring(0, index);
    final tails = _zeroOrMoreDirectories(pattern.substring(index + 3));
    return {
      for (final tail in tails) withStar + tail,
      for (final tail in tails) withoutStar + tail,
      // `**/` on its own yields the empty pattern, which `Glob` refuses. It is
      // the engine's own by-product, so it is dropped here rather than
      // surfacing as a crash on a pattern the library accepts.
    }..removeWhere((variant) => variant.isEmpty);
  }

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
  String _relative(String path) =>
      p.posix.joinAll(p.split(p.relative(path, from: root)));

  /// An expansion that found nothing is an error, and there is no key to
  /// soften it (§4.2).
  ///
  /// A task whose `argv-from` came back empty runs its body with no arguments,
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
      // Blames the exclusion only when there was something for it to remove;
      // otherwise it points at a pattern that matched nothing, which is the
      // typo actually worth reporting.
      GlobSet(:final include, :final exclude) =>
        'nothing under the repository root matches ${_quoted(include)}'
            '${exclude.isEmpty ? '' : ', with or without ${_quoted(exclude)}'}',
    };
    throw XtaskFormatException(
      'set `$name` is empty — $detail. An empty set is refused rather than '
      'passed on: a task given no arguments where it expected files does not '
      'fail, it succeeds having done nothing, and in a gate that is a green '
      'result nobody checked',
      set.span,
    );
  }

  String _quoted(List<String> patterns) =>
      patterns.map((pattern) => '`$pattern`').join(', ');
}
