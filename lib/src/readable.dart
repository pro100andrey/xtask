/// Reading `xtask.yaml` as text, and reading what the parser made of it.
///
/// **Two passes, because the two questions have different exact answers.** §8
/// refuses an alias, a merge key, and whitespace that looks like a space and
/// is not one. This module used to answer all three with one character-by-
/// character scan of the raw text — quotes, comments, indicators, brace depth
/// — on the reasoning that by the time a document exists `package:yaml` has
/// expanded every alias into a copy and the evidence is gone.
///
/// **The evidence is not gone.** An alias does not produce a copy: it produces
/// the SAME node, reachable from two places, which
/// [refuseUnreadableDocument] finds by walking the document and asking about
/// object identity. A merge key is a
/// plain key called `<<`, because `package:yaml` does not implement YAML 1.1's
/// merge and hands it back untouched. And a scalar knows whether it was
/// written in quotes, so "an invisible character where a person meant a space"
/// can be asked of the values that are text rather than guessed at from a
/// state machine tracking whether the scan is inside a string.
///
/// What is left for the raw text is what only the raw text has: the whitespace
/// that indents a line, which is not a value and never reaches a node. That is
/// twelve lines and knows no grammar.
///
/// **Written this way after the scan had been narrowed five times.** Each
/// narrowing fixed the file in front of it and refused the next: a `#` inside
/// a plain scalar, a `-` inside a word, `<<` in a sentence, a `,` outside a
/// flow collection, a `[` inside a block scalar. Every one of them is a rule
/// about YAML's grammar, and re-deriving that grammar beside a parser that
/// already has it is a list nobody finishes.
library;

import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

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
  0xFEFF, // zero-width no-break space, i.e. a byte-order mark adrift
};

/// U+FEFF, which is a byte-order mark at the start of a file and a stray
/// zero-width space anywhere else.
const _byteOrderMark = 0xFEFF;

/// [source] without a leading byte-order mark.
///
/// **Removed rather than refused, and rather than allowed.** A BOM is what
/// Notepad and older Visual Studio write, on a project whose own CI runs
/// `windows-latest`, so the file that carries one is an ordinary file. Refused
/// as invisible whitespace it was a sentence about text pasted from a
/// document, about a character no editor shows. Passed through untouched it
/// was worse: `package:yaml` does not skip one either, and the column it
/// occupies puts the first key one column in — so a second top-level key is
/// then less indented than the first, and a two-key file comes back as
/// `Only expected one document`, pointing at the line after the mistake.
///
/// Every offset downstream is into the string this returns, which is the
/// string the document is parsed from too, so nothing can disagree about a
/// span. It is one column adrift from the bytes on disk, on the first line
/// only, and no editor draws that column anyway.
String withoutByteOrderMark(String source) =>
    source.isNotEmpty && source.codeUnitAt(0) == _byteOrderMark
    ? source.substring(1)
    : source;

/// Refuses what only the raw text of [source] can show, before it is parsed.
///
/// Two things, and neither needs to know any grammar:
///
/// **A non-printable character, anywhere.** It is not text in a value, in a
/// key or in a comment, and YAML's own printable set excludes it too.
///
/// **An invisible space where a line is indented.** That is where one pasted
/// from a document does its damage, and indentation is the one part of the
/// file that never becomes a node — so it is the one part the parsed document
/// cannot be asked about. Inside a value the same question is asked after
/// parsing, where a quoted scalar can be told from a plain one; in a comment
/// it is not asked at all, because YAML reads no structure there and a file
/// was refused for a narrow no-break space in a line of prose.
void refuseUnreadableSyntax(String source, Uri? sourceUrl) {
  final file = SourceFile.fromString(source, url: sourceUrl);
  Never refuse(int offset, String message) =>
      throw XtaskFormatException(message, file.location(offset).pointSpan());

  var indenting = true;
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) {
      refuse(i, 'a non-printable character has no meaning in this file');
    }
    if (c == 0x0A) {
      indenting = true;
      continue;
    }
    if (indenting && _invisibleSpace.contains(c)) {
      refuse(i, invisibleSpaceAt(c));
    }
    if (c != 0x20 && c != 0x09 && c != 0x0D) {
      indenting = false;
    }
  }
}

/// Why [c] is refused where a space belongs.
///
/// One sentence, because the raw pass and the document pass both say it and a
/// reader meeting it twice must not meet two versions of it.
String invisibleSpaceAt(int c) =>
    'this is U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}, not a '
    'space — it was almost certainly pasted from a document. YAML would '
    'have complained about the structure several lines from here instead';

/// Refuses what §8 names, asked of [document] rather than of its text.
///
/// **An alias, because it defeats R2.** `sets:` already exists to say a thing
/// once, and the reader of a task that says `*base` has to leave the task and
/// go find the declaration — which is the property R2 protects. An anchor with
/// nothing pointing at it is not refused: it is dead text that changes no
/// task, and the refusal arrives with the alias, which is where the harm is.
///
/// **A merge key, because it is inheritance with precedence rules.**
/// `package:yaml` implements YAML 1.2, where `<<` is an ordinary key, so it
/// arrives here spelled exactly as it was written.
///
/// **And an invisible space inside a value that was not quoted.** Quoted, it
/// is data somebody meant; plain, it is a character that will not compare
/// equal to the space it looks like.
void refuseUnreadableDocument(YamlNode document) {
  final seen = <YamlNode>{};
  void walk(YamlNode node, String where) {
    if (!seen.add(node)) {
      throw XtaskFormatException(
        'a YAML alias is refused, and $where is one: it is the same node as '
        'somewhere else in this file. `sets:` already exists to say a thing '
        'once, and a task has to be readable without leaving it — what it '
        'does is read from its own keys, and an alias makes that untrue',
        node.span,
      );
    }
    switch (node) {
      case YamlMap():
        for (final entry in node.nodes.entries) {
          final key = entry.key as YamlNode;
          if (key.value == '<<') {
            throw XtaskFormatException(
              'the YAML merge key `<<` is refused. It is inheritance with '
              'precedence rules, and a task is meant to be read completely '
              'from its own keys',
              key.span,
            );
          }
          walk(key, 'the key at $where');
          walk(entry.value, 'the value of `${key.value}`');
        }
      case YamlList():
        for (final item in node.nodes) {
          walk(item, 'an entry of $where');
        }
      case YamlScalar(:final value, :final style):
        if (value is! String || style.isQuoted) {
          return;
        }
        for (final c in value.codeUnits) {
          if (_invisibleSpace.contains(c)) {
            throw XtaskFormatException(invisibleSpaceAt(c), node.span);
          }
        }
      case _:
        return;
    }
  }

  walk(document, 'the file');
}
