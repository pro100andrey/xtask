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
Set<String> zeroOrMoreDirectories(String pattern) {
  // Find the first `**` that stands as a WHOLE segment, skipping past any that
  // do not. Stopping at the first occurrence and giving up if it was part of a
  // larger token abandons the zero-directory reading of every later,
  // legitimate one: `a**/b/**/c` was left untouched entirely that way.
  //
  // A segment begins after `/` — and also after `{` or `,`, which is what the
  // previous reading missed. Inside a brace each alternative is a pattern in
  // its own right, so `{**/*.dart,**/*.yaml}` — one pattern, two globstars,
  // neither preceded by a slash — came back untouched and matched nothing at
  // the top level. A set written that way examined every nested file and no
  // root one, and said nothing about it.
  const segmentStarts = {'/', '{', ','};
  var index = pattern.indexOf('**/');
  while (index > 0 && !segmentStarts.contains(pattern[index - 1])) {
    index = pattern.indexOf('**/', index + 1);
  }
  if (index == -1) {
    return {pattern};
  }

  final withStar = pattern.substring(0, index + 3);
  final withoutStar = pattern.substring(0, index);
  final rest = pattern.substring(index + 3);
  final tails = zeroOrMoreDirectories(rest);

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
