import 'package:glob/glob.dart';
// `listSync` lives in this extension, not on `Glob` itself: the package keeps
// its filesystem access separate so it can also run where `dart:io` cannot.
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'model.dart';

/// Turning a named set into the strings a task is given — §4.2 of `xtask.md`.
///
/// Sets exist so a task can iterate without a loop and pass file arguments
/// without `$(shell find …)`. That is only worth anything if the expansion is
/// the engine's: a shell doing it brings back the portability problem the whole
/// design is arranged around.
final class SetExpander {
  SetExpander({required this.root});

  /// The directory patterns are relative to — the repository root.
  final String root;

  /// The members of [set], as the arguments a task receives.
  ///
  /// Throws [XtaskFormatException] when the answer would be empty; see
  /// [_refuseEmpty] for why that is a refusal and not an empty list.
  List<String> expand(String name, NamedSet set) {
    final members = switch (set) {
      // **Written order, not sorted.** §4.2 promises a deterministic order so
      // that an argument list does not depend on the filesystem — it does not
      // ask for an author's list to be rearranged. `each: test-packages` runs
      // in this order, somebody chose it, and R2's whole claim is that what is
      // written is what happens.
      ListSet(:final members) => members,
      GlobSet() => _matches(set),
    };
    _refuseEmpty(name, set, members);
    return members;
  }

  /// Everything on disk the include patterns reach, minus the exclusions.
  ///
  /// Sorted, because a directory listing is in whatever order the filesystem
  /// felt like and a task's arguments may not be.
  List<String> _matches(GlobSet set) {
    final found = <String>{};
    for (final pattern in set.include) {
      for (final variant in _zeroOrMoreDirectories(pattern)) {
        for (final entity in _glob(variant).listSync(
          root: root,
          // §6 says the `remove` primitive never follows a symlink. Listing
          // takes the same line, and for a second reason: a link into an
          // ancestor turns a walk into a loop.
          followLinks: false,
        )) {
          found.add(_relative(entity.path));
        }
      }
    }

    final excluded = [
      for (final pattern in set.exclude)
        for (final variant in _zeroOrMoreDirectories(pattern)) _glob(variant),
    ];

    return found
        .where((path) => !excluded.any((glob) => glob.matches(path)))
        .toList()
      ..sort();
  }

  /// [pattern], and the same pattern with each `**/` standing for no directory
  /// at all.
  ///
  /// **`package:glob` reads `**/` as one directory or more.** So
  /// `packages/**/*.lake` — the pattern §12 of `xtask.md` actually contains —
  /// finds `packages/a/b.lake` and silently does not find `packages/b.lake`.
  /// Bash's `globstar`, git's ignore rules and every glob a person has met
  /// elsewhere read it as none or more, so the file would mean one thing to
  /// its author and another to this engine.
  ///
  /// The consequence is the one this whole tool is against: not an error, but
  /// a gate that examined fewer files than it was written to examine and went
  /// green anyway. So the engine matches the expectation rather than the
  /// library, and the difference is spelled out here because it is a place
  /// where reading the library's own documentation would mislead.
  Set<String> _zeroOrMoreDirectories(String pattern) {
    final index = pattern.indexOf('**/');
    // Only when `**` is a whole segment: `a**/b` is a different pattern, and
    // dropping part of it would change what the author asked for.
    final isSegment = index == 0 || (index > 0 && pattern[index - 1] == '/');
    if (index == -1 || !isSegment) {
      return {pattern};
    }

    // Split at the first `**/`, expand the rest, then offer both readings of
    // this one. Recursion over the tail is what makes a pattern with two of
    // them yield all four readings and not just the all-or-nothing pair.
    final withStar = pattern.substring(0, index + 3);
    final withoutStar = pattern.substring(0, index);
    final tails = _zeroOrMoreDirectories(pattern.substring(index + 3));
    return {
      for (final tail in tails) withStar + tail,
      for (final tail in tails) withoutStar + tail,
    };
  }

  /// A pattern is always read as POSIX, whatever the host is.
  ///
  /// `xtask.yaml` is committed and read on every platform, so
  /// `packages/**/*.lake` has to mean the same thing on all of them. Handing
  /// the host's own context to `Glob` would make `/` a separator on one
  /// platform and `\` another, and the file would quietly match different
  /// things depending on who ran it.
  Glob _glob(String pattern) => Glob(pattern, context: p.posix);

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
      GlobSet(:final include, :final exclude) =>
        'nothing under `$root` matches ${_quoted(include)}'
            '${exclude.isEmpty ? '' : ' once ${_quoted(exclude)} is excluded'}',
    };
    throw XtaskFormatException(
      'set `$name` is empty — $detail. An empty set is refused rather than '
      'passed on: a task given no arguments where it expected files does not '
      'fail, it succeeds having done nothing, and in a gate that is a green '
      'result nobody checked',
    );
  }

  String _quoted(List<String> patterns) =>
      patterns.map((pattern) => '`$pattern`').join(', ');
}
