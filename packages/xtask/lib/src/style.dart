/// How the lines a person reads are drawn: in colour or not, with Unicode
/// glyphs or ASCII ones.
///
/// **Chosen once, where the terminal is touched, and handed down as a
/// value.** Whether stdout is a terminal is a fact `lib/xtask.dart` alone may
/// ask (`boundaries_test.dart`), and a renderer that asked again would be a
/// second answer to one question. Everything below takes a [Style] and
/// defaults to [Style.plain], which is what every test and every pipe sees:
/// the bytes a program reads from `xtask check | …` are the bytes it read
/// before there was any colour at all.
///
/// **Only the lines a person reads.** What a program reads — `--report`,
/// `--names`, `--gate-members`, `--check-ci`, `--emit-schema`, and GitHub's
/// `::group::`, `::error::` and `::add-mask::` — is never handed a style, so
/// there is nothing in it to colour.
library;

/// What a fragment of a line is, which is what decides its colour.
enum Tint {
  /// Passed: `✓`.
  passed('32'),

  /// Failed: `✗` and the code it failed with.
  failed('31'),

  /// Did not run, for a reason the file gives or the run stopped at: `⊘`,
  /// `⏹`.
  warned('33'),

  /// What a reader looks at second — a time, a reason, a count.
  faint('2'),

  /// A task's heading, `── name ──`.
  heading('1');

  const Tint(this.code);

  /// The SGR parameter that draws it.
  final String code;
}

/// The glyphs a human-readable line is drawn with.
///
/// **A set, so the two cannot be mixed.** A tree drawn with ASCII branches
/// and a `✓` beside them is a tree whose marks are the part a legacy console
/// cannot show, so every glyph is chosen together.
enum Glyphs {
  /// The glyphs the tool has always drawn.
  unicode(
    passed: '✓',
    failed: '✗',
    skipped: '⊘',
    stopped: '⏹',
    notBegun: '·',
    branch: '├─ ',
    lastBranch: '└─ ',
    through: '│  ',
    rule: '──',
    times: '×',
    dash: '—',
  ),

  /// What a console that cannot draw [unicode] is given instead.
  ///
  /// **Words**, `FAIL` in capitals because it is the one a reader scans
  /// for. They are not one width, and a mark is never padded here: where
  /// marks must line up, the summary pads them to [markWidth], and `--graph`
  /// uses one beside a sentence, where padding would be a gap. The branches
  /// are as wide as [unicode]'s, so a tree keeps its shape.
  ascii(
    passed: 'ok',
    failed: 'FAIL',
    skipped: 'skip',
    stopped: 'stop',
    notBegun: '-',
    branch: '+- ',
    lastBranch: '`- ',
    through: '|  ',
    rule: '--',
    times: 'x',
    dash: '-',
  );

  const Glyphs({
    required this.passed,
    required this.failed,
    required this.skipped,
    required this.stopped,
    required this.notBegun,
    required this.branch,
    required this.lastBranch,
    required this.through,
    required this.rule,
    required this.times,
    required this.dash,
  });

  final String passed;
  final String failed;
  final String skipped;
  final String stopped;
  final String notBegun;

  /// A branch to a child that has a sibling after it.
  final String branch;

  /// A branch to the last child.
  final String lastBranch;

  /// What continues a branch past a child's lines.
  final String through;

  /// What a task's heading is drawn between.
  final String rule;

  /// What stands before an `each:` task's member count.
  final String times;

  /// What joins a clause to the one it explains.
  final String dash;

  /// How wide the widest mark is: the column every mark is padded to, and so
  /// where a name begins, which is where a member's mark and the total are
  /// drawn under it.
  int get markWidth => [
    passed,
    failed,
    skipped,
    stopped,
    notBegun,
  ].map((mark) => mark.length).reduce((a, b) => a > b ? a : b);
}

/// How the human-readable lines of one invocation are drawn.
final class Style {
  /// The style for a stdout described by the flags — injected, so the rule
  /// can be asserted without a terminal.
  ///
  /// **Colour**, in this order:
  ///
  /// 1. The legacy console below: none, whatever was asked. It prints an
  ///    escape as the text `←[32m`, so a forced colour there is noise on
  ///    every mark rather than colour.
  /// 2. `NO_COLOR` set to anything but the empty string: none. It is a
  ///    person saying so, and a forced colour that overrode it would be the
  ///    tool deciding it knows better (no-color.org).
  /// 3. `FORCE_COLOR` set to `0` or `false`: none, even on a terminal, and
  ///    set to anything else but the empty string: colour, even into a pipe
  ///    — a CI log that renders escapes, or `less -R`. Both as Node's tools
  ///    read it, since that is where a pipeline exporting it learned it;
  ///    empty is unset, as it is for `NO_COLOR`.
  /// 4. Otherwise colour exactly when stdout is a terminal that draws ANSI
  ///    escapes. A pipe or a file is never coloured, so what a program reads
  ///    is byte for byte what it read before there was colour.
  ///
  /// **Which terminal draws ANSI**, by platform. On Windows, [ansiEscapes]:
  /// whether the console has virtual terminal processing is a fact of the
  /// console, and only the console can be asked it. On POSIX, `TERM` set and
  /// not `dumb`, and [ansiEscapes] is not read: Dart answers it from a list
  /// of `TERM` names, and `linux`, `foot` and `alacritty` are missing from
  /// it, so the console and two common emulators would never be coloured.
  /// Every terminal a POSIX machine still runs draws SGR colour; the one that
  /// says it cannot says so with `dumb`.
  ///
  /// **ASCII glyphs** exactly when stdout is a Windows console that draws no
  /// ANSI escapes — conhost without virtual terminal processing, whose raster
  /// fonts have no `✓` or `├`. Such a console is the one place a glyph comes
  /// out as a box; a console with VT processing, Windows Terminal among them,
  /// draws both. Not a POSIX terminal without escapes, `TERM=dumb` say: that
  /// is a terminal that cannot move the cursor, not one that cannot draw
  /// UTF-8. Not a pipe, whatever the platform: that is a file a program reads,
  /// and its bytes do not change.
  factory Style.choose({
    required Map<String, String> environment,
    required bool terminal,
    required bool ansiEscapes,
    required bool windows,
  }) {
    final legacyConsole = windows && terminal && !ansiEscapes;
    final glyphs = legacyConsole ? Glyphs.ascii : Glyphs.unicode;
    final term = environment['TERM'] ?? '';
    final drawsAnsi =
        terminal && (windows ? ansiEscapes : term.isNotEmpty && term != 'dumb');
    final refused = environment['NO_COLOR']?.isNotEmpty ?? false;
    final coloured =
        !legacyConsole &&
        !refused &&
        switch (environment['FORCE_COLOR']) {
          '0' || 'false' => false,
          null || '' => drawsAnsi,
          _ => true,
        };
    return Style._(coloured: coloured, glyphs: glyphs);
  }

  const Style._({required this.coloured, required this.glyphs});

  /// No colour, Unicode glyphs: a pipe, a file, every test.
  static const plain = Style._(coloured: false, glyphs: Glyphs.unicode);

  /// Colour and Unicode glyphs: a terminal that draws both.
  static const ansi = Style._(coloured: true, glyphs: Glyphs.unicode);

  /// No colour and ASCII glyphs: a console that draws neither.
  static const legacy = Style._(coloured: false, glyphs: Glyphs.ascii);

  /// Whether fragments are drawn in colour.
  final bool coloured;

  final Glyphs glyphs;

  /// [text] drawn as [tint]: as it is where there is no colour, and as it
  /// is where it is empty, since a code around nothing is bytes for nothing.
  ///
  /// **Around the whole of [text], never through it**, which is what keeps
  /// masking (`secrets.dart`) working at the exits: a value inside a painted
  /// fragment is still one run of characters in the line.
  String paint(String text, Tint tint) =>
      !coloured || text.isEmpty ? text : '\x1B[${tint.code}m$text\x1B[0m';
}

/// [parts] as one line, trailing whitespace dropped, each part drawn as its
/// tint where it has one.
///
/// **Trimmed before it is painted**, so a padded column with nothing in it
/// leaves no trailing spaces — the plain line is exactly what it was before
/// there was colour — and no escape code is drawn around nothing.
String render(List<(String, Tint?)> parts, Style style) {
  var keep = parts.map((part) => part.$1).join().trimRight().length;
  final line = StringBuffer();
  for (final (text, tint) in parts) {
    if (keep <= 0) {
      break;
    }
    final kept = text.length <= keep ? text : text.substring(0, keep);
    keep -= kept.length;
    line.write(tint == null ? kept : style.paint(kept, tint));
  }
  return line.toString();
}
