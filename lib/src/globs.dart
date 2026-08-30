/// How a pattern in `xtask.yaml` is read, wherever it is read.
///
/// **Two readers, and they have already drifted once.** The set expander and
/// the `remove` verb each compile patterns and each walk the repository for
/// them, so anything either of them decides about what a pattern MEANS has to
/// be decided here or it will be decided twice. It was: `**/` meant "one
/// directory or more" on one side and "none or more" on the other, in the same
/// file, with nothing to say so.
library;

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// [pattern], and the same pattern with each `**/` standing for no directory
/// at all.
///
/// **`package:glob` reads `**/` as one directory or more.** So
/// `packages/**/*.lake` — a pattern of exactly the shape a monorepo writes —
/// finds `packages/a/b.lake` and silently does not find `packages/b.lake`.
/// Bash's `globstar`, git's ignore rules and every glob a person has met
/// elsewhere read it as none or more, so the file would mean one thing to its
/// author and another to this engine. The consequence is the one this whole
/// tool is against: not an error, but a gate that examined fewer files than it
/// was written to examine and went green anyway.
///
/// **Here rather than inside `sets`, because there were two readers.** This
/// correction lived on the set expander, and `remove` compiled its own
/// patterns without it — so `packages/*/coverage` and `packages/**/coverage`
/// meant one thing under `sets:` and another under `do: remove`, in the same
/// file, with nothing to say so. A file format with two dialects is the defect
/// §1 exists to remove, and it had grown inside the tool.
Set<String> zeroOrMoreDirectories(String pattern) => _readings(pattern, 0);

/// How many readings of one pattern the engine will compile.
///
/// Generous: the shapes a person writes have one or two `**/`, and a monorepo
/// pattern like `packages/**/lib/**/src/**/*.dart` has eight.
const mostReadings = 32;

/// [pattern]'s readings, given that [open] brace groups are already open where
/// it begins.
///
/// **The depth is carried, not recomputed.** Each step recurses on the tail of
/// the pattern, and a tail that begins inside `{…}` has no `{` of its own to
/// count — so `{**/*.lake,**/*.yaml}` saw its first globstar as a segment
/// start and its second as an ordinary comma, and the set matched every nested
/// `.yaml` and no root one.
Set<String> _readings(String pattern, int open) {
  // **Left to right, and refused the moment it is too many.** This recursed on
  // the tail and combined on the way out, so the count was a by-product of
  // having built every reading — and the limit was applied after: twenty-four
  // globstars built sixteen million strings before refusing, and thirty ran
  // the process out of memory instead of reaching the sentence written for it.
  //
  // Counting the globstars instead and calling it `2^n` was worse than wrong,
  // it was wrong in the refusing direction: readings collapse. `a/**/**/b` has
  // three readings and not four, and six adjacent globstars have seven rather
  // than sixty-four — patterns the old check accepted and a count of segments
  // turns away. Accumulating the set says exactly how many there are, at every
  // step, having built only that many.
  var readings = {''};
  var rest = pattern;
  var depth = open;

  while (true) {
    // Find the first `**` that stands as a WHOLE segment, skipping past any
    // that do not. Stopping at the first occurrence and giving up if it was
    // part of a larger token abandons the zero-directory reading of every
    // later, legitimate one: `a**/b/**/c` was left untouched entirely that way.
    var index = rest.indexOf('**/');
    while (index > 0 && !_startsSegment(rest, index, depth)) {
      index = rest.indexOf('**/', index + 1);
    }
    if (index == -1) {
      return {
        for (final reading in readings) reading + rest,
        // `**/` on its own yields the empty pattern, which `Glob` refuses. It
        // is the engine's own by-product, so it is dropped here rather than
        // surfacing as a crash on a pattern the library accepts.
      }..removeWhere((variant) => variant.isEmpty);
    }

    final withStar = rest.substring(0, index + 3);
    final withoutStar = rest.substring(0, index);
    final tail = rest.substring(index + 3);

    // **Unless dropping it would empty a brace alternative.** `{**/,b}` has an
    // alternative that is nothing BUT the globstar, so the zero-directory
    // reading of it is `{,b}` — which `package:glob` builds without complaint
    // and then throws `Bad state: No element` from, at match time, past the
    // `FormatException` guard that catches a malformed pattern. A variant this
    // function invented must not be one the file could not have written.
    final emptiesAnAlternative =
        (withoutStar.endsWith('{') || withoutStar.endsWith(',')) &&
        (tail.isEmpty || tail.startsWith(',') || tail.startsWith('}'));

    readings = {
      for (final reading in readings) reading + withStar,
      if (!emptiesAnAlternative)
        for (final reading in readings) reading + withoutStar,
    };
    if (readings.length > mostReadings) {
      // **Refused, because nothing else bounds it.** Every reading becomes its
      // own compiled glob, matched against every entry of the walk, so the
      // cost of one line of `xtask.yaml` doubles per `**/` in it: eight
      // globstars is 256 globs per entry, and ten is over a thousand. A
      // pattern needing more than this is not saying what its author thinks it
      // says.
      throw FormatException(
        '`${_short(pattern)}` has more than $mostReadings readings, which is '
        'more than '
        'this engine will match against every file it walks. Each `**/` can '
        'double them, because it means none OR more directories. Name fewer '
        'of them, or split the set',
      );
    }

    depth += _depthOf(rest, index + 3);
    rest = tail;
  }
}

/// [pattern], short enough to read in a refusal.
///
/// The pattern is quoted so a reader can see which line of the file this is
/// about, and a pathological one is exactly the pattern that reaches here: a
/// thousand globstars printed whole is a refusal nobody can read.
String _short(String pattern) =>
    pattern.length <= 120 ? pattern : '${pattern.substring(0, 117)}...';

/// How many brace groups the first [upTo] characters of [pattern] open.
int _depthOf(String pattern, int upTo) {
  var depth = 0;
  for (var at = 0; at < upTo; at++) {
    if (pattern[at] == '{') {
      depth++;
    } else if (pattern[at] == '}') {
      depth--;
    }
  }
  return depth;
}

/// Whether the `**/` at [index] begins a segment of [pattern], given [open]
/// brace groups already open where the pattern begins.
///
/// After a `/` always. After `{` or `,` only **inside** a brace group, where
/// each alternative is a pattern in its own right — outside one a comma is an
/// ordinary character, and treating it as a segment start invented the variant
/// `data/a,b` for `data/a,**/b`. That variant is OR'd into the match and feeds
/// `do: remove`, so the cost of being generous here is deleting a path the
/// pattern did not name.
bool _startsSegment(String pattern, int index, int open) {
  final before = pattern[index - 1];
  if (before == '/') {
    return true;
  }
  if (before != '{' && before != ',') {
    return false;
  }
  return open + _depthOf(pattern, index) > 0;
}

/// What a set of include patterns can still reach, compiled once.
///
/// **Once per walk, not once per directory.** The predicate used to take a
/// `List<String>` and re-derive everything from it on every directory it was
/// asked about: split the pattern into segments, slice it, join the slice, and
/// **compile a fresh `Glob`** — which costs more than matching with one. A
/// pattern with no `**` compiles at every directory at every depth, so
/// `packages/*/coverage` paid for a compile per directory in the tree.
///
/// Held as a value, each pattern's shape is worked out when the walk starts
/// and the prefix globs are kept per depth.
final class Reach {
  Reach(List<String> patterns)
    : _shapes = [for (final pattern in patterns) _Shape(pattern)];

  final List<_Shape> _shapes;

  /// Whether anything under [directory] could match one of the patterns.
  ///
  /// Answered from a pattern's own shape, at the depth reached so far, so that
  /// a walk can stop descending instead of reading a subtree that cannot
  /// contain a match by construction.
  ///
  /// **Both walkers need this and only one had it.** Include patterns were
  /// used to match and never to prune, so `include: ['src/**/*.ts']` read all
  /// of `node_modules` and all of `.git` — once per set, per task, per run —
  /// to find nothing there. `sets` was taught to prune; `do: remove` was not,
  /// and walked the whole tree for `build/**` on every invocation.
  bool into(String directory) {
    final depth = _depthOfPath(directory);
    for (final shape in _shapes) {
      if (shape.reaches(directory, depth)) {
        return true;
      }
    }
    return false;
  }
}

/// How many segments [path] has, without splitting it into a list.
///
/// A relative path out of `p.relative` is normalised, so counting separators
/// is what splitting would have counted.
int _depthOfPath(String path) {
  var depth = 1;
  for (var at = 0; at < path.length; at++) {
    if (path.codeUnitAt(at) == 0x2F) {
      depth++;
    }
  }
  return depth;
}

/// Whether a brace group in [pattern] spans a `/`.
///
/// **Only that shape defeats pruning, and every brace used to.** The prune
/// decision slices the pattern by path segment; a brace whose alternatives sit
/// inside one segment — `packages/{a,b}/**` — splits and rejoins exactly, so
/// the arithmetic holds. One that spans a separator — `{a,b/c}/**` — makes the
/// segment COUNT depend on which alternative is taken, and a pattern with
/// four apparent segments may still reach five deep.
///
/// Reading every brace as unprunable turned pruning off for an ordinary
/// monorepo shape: `packages/{pkg000,pkg001}/**/*.dart` read all of
/// `node_modules`, `.git` and `build` — 250ms against 10ms for the same set
/// written without the brace, for twice the members.
///
/// An unbalanced brace is answered yes: it tells us nothing, and a prefix that
/// will not compile is already handled one level down.
bool _braceSpansASlash(String pattern) {
  var depth = 0;
  for (var at = 0; at < pattern.length; at++) {
    switch (pattern.codeUnitAt(at)) {
      case 0x5C: // \ — escapes whatever follows, including a brace
        at++;
      case 0x7B: // {
        depth++;
      case 0x7D: // }
        depth--;
      case 0x2F: // /
        if (depth > 0) {
          return true;
        }
    }
    if (depth < 0) {
      return true;
    }
  }
  return depth != 0;
}

/// One include pattern, with everything a prune decision needs worked out.
final class _Shape {
  _Shape(String pattern)
    : _anywhere = _braceSpansASlash(pattern),
      _segments = p.posix.split(pattern);

  /// Whether this pattern reaches into every directory at every depth.
  final bool _anywhere;
  final List<String> _segments;

  /// Prefix globs by depth. A null value is a prefix that would not compile on
  /// its own — an escape split across the slice — which tells us nothing and
  /// so must not be read as "no".
  final _prefixes = <int, Glob?>{};

  /// The first segment carrying a `**`, or -1.
  ///
  /// **`**` is not a whole segment.** `package:glob` lets it cross `/`
  /// wherever it appears, and `lib/**.dart` — the shape this repository's own
  /// example ships — is exactly that. Asking whether a segment IS `**` pruned
  /// `lib/src` out of it and lost every nested match, silently: the set stays
  /// non-empty, nothing is refused, and the gate checks fewer files and goes
  /// green.
  late final int _globstarAt = _segments.indexWhere((s) => s.contains('**'));

  bool reaches(String directory, int depth) {
    if (_anywhere) {
      return true;
    }
    // A `**` at or before this depth can match any number of directories
    // below, so everything under here is still in reach.
    if (_globstarAt >= 0 && _globstarAt < depth) {
      return true;
    }
    if (_segments.length <= depth) {
      // The pattern names fewer segments than this directory has, so nothing
      // inside it can match — the pattern ran out above here.
      return false;
    }
    final compiled = _prefixes.putIfAbsent(depth, () {
      try {
        return Glob(_segments.take(depth).join('/'), context: p.posix);
      } on FormatException {
        return null;
      }
    });
    return compiled == null || compiled.matches(directory);
  }
}
