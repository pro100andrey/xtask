import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';
import 'package:xtask/src/readable.dart';

/// What the scan says about [source], or null when it says nothing.
///
/// Reached directly, which is the point of the module: the scan runs before
/// anything reads the text as YAML, so it can be asked about a fragment that
/// is not a document at all — and inside the parser it could only be asked by
/// handing in one.
String? refusalOf(String source) {
  try {
    refuseUnreadableSyntax(source, null);
  } on XtaskFormatException catch (e) {
    return e.message;
  }
  return null;
}

void main() {
  group('an anchor, an alias and a merge key are refused', () {
    test('wherever a node begins', () {
      expect(refusalOf('a: &b c\n'), contains('anchor'));
      expect(refusalOf('a: *b\n'), contains('alias'));
      expect(refusalOf('a:\n  <<: {b: c}\n'), contains('merge key'));
    });

    test('including after the indicators that open a node', () {
      // `&` and `*` are indicators only where a node begins, and a node begins
      // after a newline, a colon, a dash, a bracket, a brace or a comma.
      for (final source in ['a: [&b]\n', 'a: {b: *c}\n', 'a: [x, &y]\n']) {
        expect(refusalOf(source), isNotNull, reason: source);
      }
    });
  });

  group('and only where they are indicators', () {
    test('a glob is an ordinary scalar and needs no quoting', () {
      expect(refusalOf('s: [packages/*/coverage, a&b]\n'), isNull);
    });

    test('but a `#` inside a word is not a comment, and hides nothing', () {
      // YAML opens a comment at the start of a line or after whitespace only,
      // so `red#1` is an ordinary plain scalar. Reading every unquoted `#` as
      // a comment skipped the rest of that line, and an anchor written there
      // walked past the one rule this scan exists to enforce.
      expect(refusalOf('s: [red#1, &b lib]\n'), contains('anchor'));
      expect(refusalOf('s: [red#1, *b]\n'), contains('alias'));
      expect(refusalOf('a: b#c\n'), isNull, reason: 'and it is still a scalar');
    });

    test('a comment is not scanned for them', () {
      expect(refusalOf('# an & and a * in a comment\na: b\n'), isNull);
    });

    test('and a `#` after a space is one, wherever on the line', () {
      expect(refusalOf('a: b # an & and a * here\n'), isNull);
      expect(refusalOf('a: b\t# and after a tab\n'), isNull);
    });

    test('nor is anything inside quotes', () {
      expect(refusalOf("a: 'literally &b and *b'\n"), isNull);
      expect(refusalOf('a: "&b *b"\n'), isNull);
    });

    test('and an escaped quote does not end the string early', () {
      // A `\"` inside a double-quoted scalar keeps the scan inside it; reading
      // it as the end would have looked for indicators in ordinary text.
      expect(
        refusalOf(
          r'a: "he said \"&b\" once"'
          '\n',
        ),
        isNull,
      );
    });

    test('a single `<` is not a merge key', () {
      expect(refusalOf('a: 1 < 2\n'), isNull);
    });
  });

  group('a character that looks like a space and is not one', () {
    test('is named by its code point, where YAML would name a structure', () {
      // The motivating case is a no-break space pasted from a document, used
      // as indentation. YAML answers it with a parse error about structure
      // several lines away from the invisible character that caused it.
      final message = refusalOf('a:\n\u00A0 b: c\n');
      expect(message, contains('U+00A0'));
      expect(message, contains('pasted'));
    });

    test('and every one of them is', () {
      for (final code in [0x2007, 0x200B, 0x202F, 0x3000, 0xFEFF]) {
        expect(
          refusalOf('a: b\n${String.fromCharCode(code)}\n'),
          isNotNull,
          reason: 'U+${code.toRadixString(16)}',
        );
      }
    });

    test('but not inside a quoted string, where it is data', () {
      expect(refusalOf("a: 'a\u00A0b'\n"), isNull);
    });

    test('and not inside a comment, where YAML reads no structure at all', () {
      // Both halves of the refusal are false about a comment: nothing there is
      // indentation, and YAML would not have complained about the structure
      // several lines down because it does not read one. A narrow no-break
      // space pasted into a line of prose — which is where prose gets pasted —
      // refused the whole file and explained it in terms of indentation.
      expect(
        refusalOf('version: 1\n# a note with a\u00A0nbsp\ntasks: {}\n'),
        isNull,
      );
      expect(refusalOf('a: b # note\u2003here\n'), isNull);
    });

    test('and a non-printable character has no meaning at all', () {
      expect(refusalOf('a: b\n\u0000\n'), contains('non-printable'));
      expect(
        refusalOf('a:\tb\r\n'),
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
        expect(refusalOf('a: \uFEFFb\n'), contains('U+FEFF'));
      },
    );

    test('and an empty file is left alone', () {
      expect(withoutByteOrderMark(''), '');
    });
  });

  test('the refusal points at the character, not at the file', () {
    // A span is what lets the message print the offending line with a caret
    // under it, which is the whole reason this runs before the parser.
    try {
      refuseUnreadableSyntax(
        'version: 1\ntasks:\n  base: &b {desc: x}\n',
        null,
      );
      fail('expected a refusal');
    } on XtaskFormatException catch (e) {
      expect(e.span, isNotNull);
      expect(e.span!.start.line, 2, reason: 'zero-based: the third line');
      expect('$e', contains('line 3'));
    }
  });

  group('and it refuses the syntax, not the punctuation', () {
    // The scan claims to be exact rather than approximate, and was not: `-`
    // was read as a block-sequence indicator wherever it appeared, though
    // YAML makes it one only when something separates it from what follows,
    // and `<<` was refused everywhere though it is a merge key only where a
    // key can be.

    test('an indicator inside a word does not make the next `&` an anchor', () {
      // `-` was narrowed first and `,` and `:` left behind, which is the same
      // refusal about punctuation for two of the four cases.
      expect(refusalOf('desc: fail-&-report'), isNull);
      expect(refusalOf('desc: x -*- y'), isNull);
      expect(refusalOf('desc: red,&blue'), isNull);
      expect(refusalOf('desc: a,*b'), isNull);
      expect(refusalOf('desc: x:&y'), isNull);
    });

    test('and `<<` outside key position is ordinary text', () {
      expect(refusalOf('desc: shift a << b'), isNull);
      expect(refusalOf('args: [--x=a<<b]'), isNull);
    });

    test('but the real ones are still refused', () {
      expect(refusalOf('sets: &base'), contains('anchor'));
      expect(refusalOf('[&a]'), contains('anchor'));
      expect(refusalOf('[a, &b]'), contains('anchor'));
      expect(refusalOf('- &item'), contains('anchor'));
      expect(refusalOf('needs: [*ref]'), contains('alias'));
      expect(refusalOf('  <<: *base'), contains('merge key'));
    });
  });
}
