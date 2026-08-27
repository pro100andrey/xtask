/// Whether a task's keys agree with each other.
///
/// **Not the parser's, whatever the file it used to live in.** `parse.dart`
/// says of itself that it checks the document against the types and nothing
/// more — "it does not check that a name refers to something real, does not
/// look for cycles and does not touch the filesystem" — and then held a
/// hundred and seventy lines asking whether `each:` and `$each` agree, whether
/// `all:` and `each:` may be written together, and whether a marker stands
/// where a marker may stand. Those are the same kind of question as a dangling
/// `needs:`, and this is where they belong.
///
/// **Answered with a list rather than a throw, and that is the point of the
/// move.** Written as throws, the first mistake in a task hid the rest: a file
/// with three of them cost three rounds of fix-and-rerun, which is the loop
/// `validate.dart` argues against in as many words. `parse.dart` still refuses
/// — it is the only gate on the run path, and `bodies.dart` relies on it — but
/// it now refuses with all of them at once.
library;

import 'errors.dart';
import 'model.dart';

/// `$all` as a word of its own, rather than the start of a longer name.
final _bareMarker = RegExp(r'\$all(?![A-Za-z0-9_])');

/// `$each` as a word of its own, rather than the start of a longer name.
final _bareEach = RegExp(r'\$each(?![A-Za-z0-9_])');

/// Every way [task]'s own keys contradict each other, in the order found.
///
/// Empty when they do not. Needs no filesystem, no graph and no other task —
/// which is what makes it a list rather than a walk.
List<XtaskFormatException> incoherences(Task task) => [
  ..._allMarker(task),
  ..._eachMarker(task),
];

/// `each:` and its marker have to agree, and the marker has to END what it is
/// written in.
///
/// **The suffix is the line, and it is drawn once.** `$each` standing whole or
/// finishing a string is a value put where a value goes — `packages/$each`,
/// `--flavor=$each`. Text AFTER it is a derived path, `build/$each.dart`, and
/// that is where a substitution stops being a value and becomes a
/// computation. A computation wants a modifier, a modifier wants a language,
/// and R1 exists to say this file is not one. Deriving a path is a verb's job.
Iterable<XtaskFormatException> _eachMarker(Task task) sync* {
  final name = task.name;
  final argv = switch (task.body) {
    RunBody(:final argv) => argv,
    _ => const <String>[],
  };

  if (argv.isNotEmpty && _bareEach.hasMatch(argv.first)) {
    yield XtaskFormatException(
      'task `$name` runs `${argv.first}`. The first entry of `run:` is the '
      'program, resolved on PATH before anything is substituted — a member '
      'does not name one',
      task.span,
    );
  }

  final written = [
    ...argv.skip(1),
    ...task.args,
    ...task.env.values,
    ?task.workingDirectory,
  ];
  // **Every occurrence but a trailing one.** `endsWith` alone looked only at
  // the last, so `$each/$each` passed and the resolver — which substitutes the
  // trailing one — left the other in the argument as literal text.
  final badly = written.where(
    (word) =>
        _bareEach.hasMatch(word) &&
        (_bareEach.allMatches(word).length > 1 || !word.endsWith(eachMarker)),
  );
  if (badly.isNotEmpty) {
    yield XtaskFormatException(
      'task `$name` writes `${badly.first}`. `\$each` stands for one member '
      'and may end what it is written in, but nothing may follow it: '
      r'`packages/$each` is a path composed around a value, and '
      r'`$each.dart` is a path computed FROM one. Computing belongs in a '
      'verb, where this file cannot go',
      task.span,
    );
  }

  final used = written.any((word) => word.endsWith(eachMarker));
  if (task.each != null && !used) {
    yield XtaskFormatException(
      'task `$name` has `each: ${task.each}` and never writes `\$each`, so '
      'the body runs once per member with no way to tell them apart',
      task.span,
    );
  }
  if (task.each == null && used) {
    yield XtaskFormatException(
      'task `$name` writes `\$each` and has no `each:` to say which set its '
      'members come from',
      task.span,
    );
  }

  // **The one pairing that is provably wrong.** `in: $each` says the member IS
  // the directory, so the member is a path from the repository root and the
  // body runs inside it; the same member in argv is then a path read from two
  // different places. A COMPOSED `in:` — `packages/$each` — says the opposite,
  // that the member is a name, and both halves are legitimate at once.
  if (task.workingDirectory == eachMarker &&
      [...argv.skip(1), ...task.args].any((w) => w.endsWith(eachMarker))) {
    yield XtaskFormatException(
      'task `$name` puts `\$each` in its arguments and also runs `in: '
      r'$each`. A member is a path from the repository root, and `in:` moves '
      'into it — the two would be relative to different places. Compose the '
      r'directory instead, `in: some/dir/$each`, so the member is a name',
      task.span,
    );
  }
}

/// `all:` and its marker have to agree, and the marker has to be a whole
/// argument.
///
/// **Refused here rather than left to make a strange run.** A set named and
/// never used is a task that quietly does not check what its author thought;
/// a marker with no set is a program handed the literal text `$all`. Neither
/// fails — both succeed at the wrong thing, which is what §1 is about.
///
/// A marker inside a larger string is refused too, and that is the line R1
/// draws: `$all` stands for N arguments, and there is nothing for N arguments
/// to mean inside one. Splitting a string is a shell's job and this has no
/// shell.
Iterable<XtaskFormatException> _allMarker(Task task) sync* {
  final name = task.name;
  final argv = switch (task.body) {
    RunBody(:final argv) => argv,
    _ => const <String>[],
  };

  // **The program is not an argument.** `run:` names an executable first, and
  // §5.4 resolves it on PATH before anything is substituted — so `$all` there
  // is not a set expanded into position, it is a program by that name. It
  // counted as a marker here while the resolver substituted only over the
  // arguments, which let a file declare a set, satisfy every check below and
  // reach the command line with nothing: the run then answered 3, saying the
  // machine lacked a tool, about a file that was wrong.
  if (argv.isNotEmpty && _bareMarker.hasMatch(argv.first)) {
    yield XtaskFormatException(
      'task `$name` runs `${argv.first}`. `\$all` stands for arguments, and '
      'the first entry of `run:` is the program — there is nothing for a set '
      'to expand into there',
      task.span,
    );
  }

  final oneThing = [?task.workingDirectory, ...task.env.values].where(
    _bareMarker.hasMatch,
  );
  if (oneThing.isNotEmpty) {
    final where = oneThing.first;
    // Neither refused nor substituted before, so the body ran in a directory
    // literally called `$all` and failed much later as "could not be started".
    yield XtaskFormatException(
      'task `$name` writes `\$all` in `$where`. It stands for every member of '
      'a set, and a directory and an environment value are each one thing — '
      'there is nothing for a list to be there',
      task.span,
    );
  }

  final written = [...argv.skip(1), ...task.args];
  final markers = written.where((word) => word == allMarker).length;
  // A delimited token, so that `--allow=\$allowlist` — a literal argument for
  // a tool that does its own expansion — is text and not a mistake.
  final embedded = written.where(
    (word) => word != allMarker && _bareMarker.hasMatch(word),
  );

  if (embedded.isNotEmpty) {
    yield XtaskFormatException(
      'task `$name` writes `${embedded.first}`. `\$all` stands for every '
      'member of a set, so it is a whole argument or nothing — there is no '
      'meaning for several arguments inside one, and no shell here to split '
      'them',
      task.span,
    );
  }
  if (task.all != null && markers == 0) {
    yield XtaskFormatException(
      'task `$name` has `all: ${task.all}` and never writes `\$all`, so the '
      r'set reaches nothing. Put `$all` where its members belong',
      task.span,
    );
  }
  if (task.all == null && markers > 0) {
    yield XtaskFormatException(
      'task `$name` writes `\$all` and has no `all:` to say which set it '
      'stands for',
      task.span,
    );
  }
  if (markers > 1) {
    yield XtaskFormatException(
      'task `$name` writes `\$all` $markers times. One set expanded twice into '
      'one command line is two answers to what the task is about',
      task.span,
    );
  }
  if (task.all != null && task.each != null) {
    // The combination that used to be legal and meant nothing anybody wanted:
    // every member of the `each:` set received the WHOLE `all:` set.
    yield XtaskFormatException(
      'task `$name` has both `each:` and `all:`. One runs the body once per '
      'member and the other runs it once for all of them; a task is one or '
      'the other',
      task.span,
    );
  }
}
