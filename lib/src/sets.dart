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
  /// The answer is unmodifiable, and both branches answer alike: a caller
  /// that appends to what it is handed must not be able to poison the parsed
  /// model's own list, which in a gate set is the list the next task sharing
  /// the set receives.
  List<String> expand(String name, NamedSet set) {
    final members = switch (set) {
      // Each member is asked the boundary question the glob arm asks, so the
      // two arms cannot disagree about `['/etc', '../..']`.
      //
      // Written order, not sorted: a set promises an order that does not depend
      // on the filesystem, not that an author's list is rearranged. Members are
      // literal — globs among them are `remove`'s to expand under `remove`'s
      // own rule.
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
  /// whole feature threw a `StateError` on Windows, past the exit codes and
  /// past `--validate`, which must check globs without running
  /// anything. Walking here also means one pass instead of one per pattern
  /// variant, and it means the walk can be **pruned**, which is what makes an
  /// exclusion protective rather than decorative.
  List<String> _matches(String name, GlobSet set) {
    final includes = _globs(name, set, set.include);
    final excludes = _globs(name, set, set.exclude);
    // A directory whose contents are all excluded is itself excluded. Without
    // this, `**/test_data/**` — which needs a segment after `test_data` —
    // leaves the directory itself a member, and `remove` then deletes
    // recursively exactly the files the exclusion was written to protect.
    final prunes = _globs(name, set, [
      for (final pattern in set.exclude)
        if (pattern.endsWith('/**')) pattern.substring(0, pattern.length - 3),
    ]);
    final reach = Reach(set.include);
    final found = <String>[];

    // The relative path is carried rather than re-derived: `p.relative` per
    // entry, over thirty thousand of them on an ordinary repository, is a
    // third of the walk to work out what the parent already knew.
    void walk(Directory directory, String at) {
      for (final entry in _listing(directory, at, name, set)) {
        // `remove` never follows a symlink. Listing takes the same
        // line, and for a second reason: a link into an ancestor is a loop.
        if (entry is Link) {
          continue;
        }
        final relative = at.isEmpty
            ? p.basename(entry.path)
            : '$at/${p.basename(entry.path)}';
        if (excludes.any((g) => g.matches(relative))) {
          continue;
        }
        if (entry is Directory && prunes.any((g) => g.matches(relative))) {
          continue;
        }
        if (includes.any((g) => g.matches(relative))) {
          found.add(relative);
        }
        // Pruned on the includes as well as the exclusions, and only the
        // DESCENT is: a directory can be a member itself, which is how
        // `packages/*/coverage` reaches one to delete.
        if (entry is Directory && reach.into(relative)) {
          walk(entry, relative);
        }
      }
    }

    walk(Directory(root), '');
    return found..sort();
  }

  /// What [directory] holds, sorted, or nothing if it has gone away.
  ///
  /// Sorted here as well as at the end: a listing arrives in whatever order the
  /// filesystem felt like, and a walk that descends in that order is a walk
  /// whose failure messages arrive in it too.
  ///
  /// A directory this process cannot read is REFUSED rather than passed over:
  /// it may hold members, and a set that is quietly short is a gate that
  /// examined less than the file says. One that simply went away — a
  /// `do: remove` running beside this task, or anything else on the machine —
  /// has nothing left to be short of.
  List<FileSystemEntity> _listing(
    Directory directory,
    String at,
    String name,
    GlobSet set,
  ) {
    try {
      return directory.listSync(followLinks: false).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException catch (problem) {
      if (!directory.existsSync()) {
        return const [];
      }
      throw XtaskFormatException(
        'set `$name` cannot be read: `${at.isEmpty ? '.' : at}` is not '
        'listable — ${problem.osError?.message ?? problem.message}. This is '
        'about this machine rather than the file, and it is refused rather '
        'than passed over: a directory that cannot be read may hold members, '
        'and a set that is quietly short is a gate that checked less than it '
        'says',
        set.span,
      );
    }
  }

  /// Every reading of every pattern, as globs, refusing what cannot be one.
  List<Glob> _globs(String name, NamedSet set, List<String> patterns) => [
    for (final pattern in patterns)
      for (final variant in _readings(name, set, pattern))
        _glob(name, set, variant),
  ];

  /// Every reading of [pattern], reported at the set's own line.
  ///
  /// `zeroOrMoreDirectories` refuses a pattern with too many of them, and that
  /// refusal is a `FormatException` — which, unwrapped, would leave `expand`
  /// past the exit codes, as any malformed pattern would.
  Set<String> _readings(String name, NamedSet set, String pattern) {
    final rooted = _refuseUnrooted(name, set, pattern);
    try {
      return zeroOrMoreDirectories(rooted);
    } on FormatException catch (problem) {
      throw XtaskFormatException(
        'in set `$name`: ${problem.message}',
        set.span,
      );
    }
  }

  /// [written] unchanged, or a refusal if it names anything outside [root].
  ///
  /// `root` is a boundary, not a default: what a set hands on can reach a
  /// working directory and `remove`, which deletes recursively and treats
  /// a missing path as fine.
  ///
  /// Asked of a written member as well as of a pattern, since a set hands on
  /// the same string either way. The test itself lives in [leavesRoot], so the
  /// fence has one gate rather than a copy per caller.
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

  /// An expansion that found nothing is an error, and there is no key to
  /// soften it (sets).
  ///
  /// A task whose `all:` came back empty runs its body with no arguments, and
  /// `dart format` with no arguments formats the whole tree. The worse case is
  /// quieter: inside a gate, the set was empty, the task passed, the gate went
  /// green and nothing was checked — the third defect this tool is against,
  /// reproduced by a new route. A pattern matches nothing for two reasons, the
  /// repository genuinely having none and the pattern being broken, and in a
  /// gate the second is the dangerous one.
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
      GlobSet(:final include, :final exclude, :final producedBy) =>
        'nothing under the repository root matches ${_quoted(include)}'
            '${exclude.isEmpty ? '' : ', with or without ${_quoted(exclude)}'}'
            '${producedBy == null ? '' : ' — task `$producedBy` makes its '
                      'members, and it has not run yet'}',
    };
    throw EmptySetException(
      'set `$name` is empty — $detail. An empty set is refused rather than '
      'passed on: a task given no arguments where it expected files does not '
      'fail, it succeeds having done nothing, and in a gate that is a green '
      'result nobody checked',
      set.span,
      // **The one place this is decided.** `produced-by:` says the members
      // are made by a task, so before that task has run this emptiness is a
      // moment rather than a mistake. Every reader asks the refusal rather
      // than the set.
      onlyYet: set is GlobSet && set.producedBy != null,
    );
  }

  String _quoted(List<String> patterns) =>
      patterns.map((pattern) => '`$pattern`').join(', ');
}
