/// How a pattern in `xtask.yaml` is read, wherever it is read.
library;

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

/// [pattern]'s readings, given that [open] brace groups are already open where
/// it begins.
///
/// **The depth is carried, not recomputed.** Each step recurses on the tail of
/// the pattern, and a tail that begins inside `{…}` has no `{` of its own to
/// count — so `{**/*.lake,**/*.yaml}` saw its first globstar as a segment
/// start and its second as an ordinary comma, and the set matched every nested
/// `.yaml` and no root one.
Set<String> _readings(String pattern, int open) {
  // Find the first `**` that stands as a WHOLE segment, skipping past any that
  // do not. Stopping at the first occurrence and giving up if it was part of a
  // larger token abandons the zero-directory reading of every later,
  // legitimate one: `a**/b/**/c` was left untouched entirely that way.
  var index = pattern.indexOf('**/');
  while (index > 0 && !_startsSegment(pattern, index, open)) {
    index = pattern.indexOf('**/', index + 1);
  }
  if (index == -1) {
    return {pattern};
  }

  final withStar = pattern.substring(0, index + 3);
  final withoutStar = pattern.substring(0, index);
  final rest = pattern.substring(index + 3);
  final tails = _readings(rest, open + _depthOf(pattern, index + 3));

  // **Unless dropping it would empty a brace alternative.** `{**/,b}` has an
  // alternative that is nothing BUT the globstar, so the zero-directory
  // reading of it is `{,b}` — which `package:glob` builds without complaint
  // and then throws `Bad state: No element` from, at match time, past the
  // `FormatException` guard that catches a malformed pattern. A variant this
  // function invented must not be one the file could not have written.
  final emptiesAnAlternative =
      (withoutStar.endsWith('{') || withoutStar.endsWith(',')) &&
      (rest.isEmpty || rest.startsWith(',') || rest.startsWith('}'));

  return {
    for (final tail in tails) withStar + tail,
    if (!emptiesAnAlternative)
      for (final tail in tails) withoutStar + tail,
    // `**/` on its own yields the empty pattern, which `Glob` refuses. It is
    // the engine's own by-product, so it is dropped here rather than surfacing
    // as a crash on a pattern the library accepts.
  }..removeWhere((variant) => variant.isEmpty);
}

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
