/// Reading `xtask.yaml` as text, before anything reads it as YAML.
///
/// **Before, because afterwards there is nothing left to see.** By the time a
/// document exists, `package:yaml` has expanded every alias into a copy and
/// the evidence is gone — so the two rules here are a scan of the raw text,
/// and this is the only code that ever holds it.
///
/// **Its own module, because it is its own job.** `parse.dart` says of itself
/// that it checks a document against the types; this is a character-by-
/// character pass with a state machine of its own — quotes, comments, escapes
/// — and it decides nothing about what a task is. Sitting inside the parser it
/// could only be reached by handing in a whole document.
library;

import 'package:source_span/source_span.dart';

import 'errors.dart';

/// Characters that look like a space and are not one.
///
/// The motivating case is a non-breaking space pasted from a document, used as
/// indentation. YAML's own answer to it is a parse error about structure,
/// several lines away from the invisible character that caused it, which is
/// the "useless message" §8's last bullet is written against.
const _invisibleSpace = {
  0x00A0, // no-break space
  0x1680, // ogham space mark
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, // en/em quad and friends
  0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x200B, // thin, hair, zero-width
  0x2028, 0x2029, // line and paragraph separator
  0x202F, // narrow no-break space
  0x205F, // medium mathematical space
  0x3000, // ideographic space
  0xFEFF, // zero-width no-break space, i.e. a stray byte-order mark
};

/// Where a YAML node begins, and therefore where `&` and `*` are indicators
/// rather than ordinary characters.
// \n : - [ { ,
const _nodeStart = <int?>{null, 0x0A, 0x3A, 0x2D, 0x5B, 0x7B, 0x2C};

/// Whether a node can begin after [previous], with [afterSpace] between.
///
/// **`-` is an indicator only when something separates it from what follows.**
/// It was taken as one wherever it appeared, and [previous] skips whitespace,
/// so `desc: fail-&-report` read the `-` of a hyphenated word as the start of
/// a block sequence and refused the `&` two characters later as an anchor —
/// about a description, on punctuation the author has no reason to suspect.
/// `desc: x -*- y` went the same way. The others need no space: `[&a]` and
/// `{&a: b}` are anchors as written.
bool _startsANode(int? previous, bool afterSpace) =>
    _nodeStart.contains(previous) && (previous != 0x2D || afterSpace);

/// Whether the first thing after [at] that is not a space is a `:`.
bool _keySeparatorAfter(String source, int at) {
  for (var i = at; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) {
      continue;
    }
    return c == 0x3A;
  }
  return false;
}

/// Refuses the syntax §8 names, reading [source] as text.
///
/// Two rules, and both are about a reader being able to trust a task:
///
/// **No anchors, aliases or merge keys.** `sets:` already exists to say a thing
/// once, so an anchor is a second mechanism for the same purpose — and in this
/// design two ways to say one thing have drifted everywhere they were allowed.
/// It also defeats R2 in practice if not in letter: the reader of a task that
/// says `*base` has to leave it and go find the declaration, which is the
/// property R2 was written to protect.
///
/// **No invisible whitespace.** See [_invisibleSpace].
///
/// The scan is exact rather than approximate. YAML treats `&` and `*` as
/// indicators only where a node begins, so `packages/*/coverage` is an
/// ordinary scalar and passes untouched — while `include: [**/x]` does not,
/// and should not: YAML would read that as an alias too, which is why the
/// examples in §12 quote their patterns.
void refuseUnreadableSyntax(String source, Uri? sourceUrl) {
  final file = SourceFile.fromString(source, url: sourceUrl);
  Never refuse(int offset, String message) =>
      throw XtaskFormatException(message, file.location(offset).pointSpan());

  var inSingle = false;
  var inDouble = false;
  var inComment = false;
  int? previous; // last significant character outside quotes and comments

  // **Whether a `#` here would start a comment.** YAML opens one only at the
  // start of a line or after whitespace: `red#1` is an ordinary plain scalar
  // and everything after the `#` on that line is still the document. Reading
  // every unquoted `#` as a comment skipped the rest of that line, so
  // `base: [red#1, &b lib]` hid an anchor from this scan entirely — and the
  // alias that used it. The one rule this file exists to enforce, walked past
  // by one character.
  //
  // Kept separately from [previous], which skips spaces on purpose: after
  // `a: ` it holds the colon, so it cannot answer this question.
  var afterSpace = true;

  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);

    if (_invisibleSpace.contains(c) && !inSingle && !inDouble) {
      refuse(
        i,
        'this is U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}, not a '
        'space — it was almost certainly pasted from a document. YAML would '
        'have complained about the structure several lines from here instead',
      );
    }
    if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) {
      refuse(i, 'a non-printable character has no meaning in this file');
    }

    if (inComment) {
      if (c == 0x0A) {
        inComment = false;
        previous = 0x0A;
        afterSpace = true;
      }
      continue;
    }
    if (inSingle) {
      if (c == 0x27) {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (c == 0x5C) {
        i++;
      } else if (c == 0x22) {
        inDouble = false;
      }
      continue;
    }

    switch (c) {
      case 0x23 when afterSpace: // #
        inComment = true;
        continue;
      case 0x27: // '
        inSingle = true;
        previous = c;
        afterSpace = false;
        continue;
      case 0x22: // "
        inDouble = true;
        previous = c;
        afterSpace = false;
        continue;
      case 0x20:
      case 0x09:
      case 0x0D:
        afterSpace = true;
        continue;
      case 0x0A:
        previous = 0x0A;
        afterSpace = true;
        continue;
    }

    if ((c == 0x26 || c == 0x2A) && _startsANode(previous, afterSpace)) {
      final anchor = c == 0x26;
      refuse(
        i,
        anchor
            ? 'a YAML anchor (`&`) is refused. `sets:` already exists to say a '
                  'thing once, and a task has to be readable without leaving '
                  'it: what it does is read from its own keys, and an anchor '
                  'makes that untrue'
            : 'a YAML alias (`*`) is refused, for the reason an anchor is. If '
                  'this was meant as a glob, quote it: YAML reads a value '
                  'beginning with `*` as an alias, whatever you meant',
      );
    }
    // **A merge key, and not every `<<`.** Refused wherever it appeared, an
    // ordinary shift or redirect in a description — `desc: shift a << b` —
    // was answered with a sentence about inheritance and precedence rules.
    // `<<` is the merge key only where a key can be, and only when a `:`
    // follows it; anywhere else YAML reads it as the plain text it is.
    final mergeKey =
        c == 0x3C &&
        i + 1 < source.length &&
        source.codeUnitAt(i + 1) == 0x3C &&
        _startsANode(previous, afterSpace) &&
        _keySeparatorAfter(source, i + 2);
    if (mergeKey) {
      refuse(
        i,
        'the YAML merge key `<<` is refused. It is inheritance with precedence '
        'rules, and a task is meant to be read completely from its own keys',
      );
    }

    previous = c;
    afterSpace = false;
  }
}
