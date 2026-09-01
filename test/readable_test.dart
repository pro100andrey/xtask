import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/readable.dart';
import 'package:yaml/yaml.dart';

/// What the raw pass says about [source], or null when it says nothing.
///
/// It runs before anything reads the text as YAML, so it can be asked about a
/// fragment that is not a document at all.
String? rawRefusalOf(String source) {
  try {
    refuseUnreadableSyntax(source, null);
  } on XtaskFormatException catch (e) {
    return e.message;
  }
  return null;
}

/// What the document pass says about [source], or null when it says nothing.
String? refusalOf(String source) {
  final raw = rawRefusalOf(source);
  if (raw != null) {
    return raw;
  }
  try {
    refuseUnreadableDocument(loadYamlNode(source));
  } on XtaskFormatException catch (e) {
    return e.message;
  } on YamlException catch (e) {
    // Counted as a refusal, because the two passes are not the only guards:
    // `parseXtaskFile` turns this into the same exception with the same span.
    // Where the parser already points at the character, saying it twice is a
    // second grammar to keep in step.
    return e.message;
  }
  return null;
}

void main() {
  group('an alias and a merge key are refused', () {
    // **Asked of the document rather than of its text.** An alias does not
    // produce a copy, it produces the same node reached twice, and a merge key
    // arrives as a plain key called `<<` because `package:yaml` implements
    // YAML 1.2. Derived from the raw text instead, this was a state machine
    // re-deriving YAML's grammar beside a parser that already had it, narrowed
    // five times and wrong in a new way after each.
    test('however the file spells them', () {
      expect(refusalOf('a: &b c\nd: *b\n'), contains('alias'));
      expect(refusalOf('a:\n  <<: {b: c}\n'), contains('merge key'));
    });

    test('including with no space after the comma that precedes them', () {
      // The one the old scan let through: `,` was held to the same "needs a
      // space" rule as `-` and `:`, which is true of them in block context and
      // false of a comma inside brackets. Deleting one space walked past the
      // only rule this module enforces.
      expect(refusalOf('a: [one,&x two]\nb: [three,*x]\n'), contains('alias'));
    });

    test('including where a `#` inside a word used to hide them', () {
      // YAML opens a comment at the start of a line or after whitespace only,
      // so `red#1` is an ordinary plain scalar. Reading every unquoted `#` as
      // a comment skipped the rest of that line.
      expect(refusalOf('s: [red#1, &b lib]\nt: [*b]\n'), contains('alias'));
    });

    test('including from inside a block scalar, where nothing is a node', () {
      // The bracket in this block permanently opened a flow collection for the
      // old scan, and every comma after it was then an entry separator.
      expect(
        refusalOf(
          'n: |\n  [ a bracket opens this line\nd: red,&blue is fine\n',
        ),
        isNull,
      );
    });

    test('but an anchor nothing points at is dead text', () {
      // What is refused is the alias: R2 says a task is read completely from
      // its own keys, and it is `*base` that sends the reader somewhere else.
      // An anchor with nothing referencing it changes no task, and the refusal
      // arrives with the alias, which is where the harm is.
      expect(refusalOf('a: &b c\n'), isNull);
    });
  });

  group('and punctuation that only looks like an indicator is text', () {
    // Every one of these was refused at some point by a scan deriving YAML's
    // grammar a second time, and each narrowing broke the next case along.
    test('an indicator inside a word', () {
      for (final source in [
        'desc: fail-&-report\n',
        'desc: x -*- y\n',
        'desc: red,&blue\n',
        'desc: a,*b\n',
        'desc: x:&y\n',
      ]) {
        expect(refusalOf(source), isNull, reason: source);
      }
    });

    test('a glob, quoted or not', () {
      expect(refusalOf('s: [packages/*/coverage, a&b]\n'), isNull);
    });

    test('`<<` outside key position', () {
      expect(refusalOf('desc: shift a << b\n'), isNull);
      expect(refusalOf('args: [--x=a<<b]\n'), isNull);
    });
  });

  group('a character that looks like a space and is not one', () {
    test('is refused where a line is indented', () {
      // The motivating case: one pasted from a document, used as indentation.
      // YAML answers it with a parse error about structure several lines away
      // from the character that caused it.
      final message = rawRefusalOf('a:\n\u00A0 b: c\n');
      expect(message, contains('U+00A0'));
      expect(message, contains('pasted'));
    });

    test('and inside a value that was not quoted', () {
      expect(refusalOf('a: one\u00A0two\n'), contains('U+00A0'));
      expect(refusalOf('a: {b: one\u2003two}\n'), contains('U+2003'));
    });

    test('but not inside a quoted one, where it is data', () {
      expect(refusalOf("a: 'one\u00A0two'\n"), isNull);
      expect(refusalOf('a: "one\u00A0two"\n'), isNull);
    });

    test('and not inside a comment, where YAML reads no structure', () {
      // Both halves of the refusal are false about a comment: nothing there is
      // indentation, and YAML would not have complained about the structure
      // further down because it does not read one.
      expect(refusalOf('a: 1\n# a note with a\u00A0nbsp\nb: 2\n'), isNull);
      expect(refusalOf('a: b # note\u2003here\n'), isNull);
    });

    test('and every one of them is named by its code point', () {
      for (final code in [0x2007, 0x200B, 0x202F, 0x3000, 0xFEFF]) {
        expect(
          rawRefusalOf('a: b\n${String.fromCharCode(code)}\n'),
          isNotNull,
          reason: 'U+${code.toRadixString(16)}',
        );
      }
    });

    test('and a non-printable character has no meaning at all', () {
      expect(rawRefusalOf('a: b\n\u0000\n'), contains('non-printable'));
      expect(
        rawRefusalOf('a:\tb\r\n'),
        isNull,
        reason: 'tab, carriage return and newline are ordinary',
      );
    });
  });

  group('a byte-order mark at the start of the file is not a stray one', () {
    test('it is removed rather than refused', () {
      // It is what Notepad and older Visual Studio write, on a project whose
      // own CI runs windows-latest.
      expect(withoutByteOrderMark('\uFEFFversion: 1\n'), 'version: 1\n');
    });

    test(
      'and only at the start, because anywhere else it is a stray space',
      () {
        expect(withoutByteOrderMark('version: 1\n'), 'version: 1\n');
        expect(withoutByteOrderMark('a: \uFEFFb\n'), 'a: \uFEFFb\n');
        // Refused, though not by us: `package:yaml` answers a mid-line mark
        // with `Unexpected character` pointed at the character itself, which
        // is a diagnostic and not the useless one §8 is written against.
        expect(refusalOf('a: \uFEFFb\n'), isNotNull);
      },
    );

    test('and an empty file is left alone', () {
      expect(withoutByteOrderMark(''), '');
    });
  });

  test('a refusal carries the span it is about', () {
    // A span is what lets the message print the offending line with a caret
    // under it.
    try {
      refuseUnreadableDocument(
        loadYamlNode('version: 1\ntasks:\n  base: &b x\n  t: *b\n'),
      );
      fail('expected a refusal');
    } on XtaskFormatException catch (e) {
      expect(e.span, isNotNull);
      expect('$e', contains('line 3'));
    }
  });
}
