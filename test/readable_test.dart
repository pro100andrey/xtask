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

    test('a comment is not scanned for them', () {
      expect(refusalOf('# an & and a * in a comment\na: b\n'), isNull);
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

    test('and a non-printable character has no meaning at all', () {
      expect(refusalOf('a: b\n\u0000\n'), contains('non-printable'));
      expect(
        refusalOf('a:\tb\r\n'),
        isNull,
        reason: 'tab, carriage return and newline are ordinary',
      );
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
}
