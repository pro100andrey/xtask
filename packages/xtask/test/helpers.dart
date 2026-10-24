/// What more than one suite needs, written once.
///
/// **Only what was genuinely the same.** Three files carried a
/// character-identical refusal helper under two names, and eleven made a
/// temporary directory and registered its own teardown — each copy carrying
/// the same leak risk independently. The three `FakeStarter`s are NOT here:
/// they record different things on purpose, and one shape wide enough for all
/// three would be a fake nobody's test is about.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:xtask/src/errors.dart';

/// The message [body]'s refusal renders, span and caret included.
///
/// Fails the test where there is no refusal, because a check that passes when
/// nothing was refused is a check that stopped checking.
String refusalOf(void Function() body) {
  try {
    body();
  } on XtaskFormatException catch (e) {
    return e.toString();
  }
  fail('expected a refusal, got none');
}

/// A temporary directory, removed when the test ends.
///
/// The teardown is registered here rather than written out per suite: eleven
/// copies of `createTempSync` plus a recursive delete is eleven chances to
/// leave a tree behind, and `addTearDown` runs even when the test fails.
Directory tempRepo(String tag) {
  final root = Directory.systemTemp.createTempSync('xtask_${tag}_');
  addTearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });
  return root;
}

/// Matches the summary's row for [name], marked [mark], that says [rest].
///
/// The row's padding is the widest name's in that run, which is
/// `report_test.dart`'s to pin; a suite running a whole plan asks only which
/// row is there and what it says. Matched against the joined output.
Matcher summaryRow(String mark, String name, [String rest = '']) => matches(
  RegExp(
    '^ *${RegExp.escape('$mark $name')} .*${RegExp.escape(rest)}',
    multiLine: true,
  ),
);

/// Resets SIGINT and SIGQUIT to their defaults and becomes the program named
/// after it.
///
/// **Because of where the suite may be running.** A non-interactive shell
/// starts its background jobs with SIGINT and SIGQUIT ignored, that
/// disposition is inherited across `exec`, and Dart's `watch()` on an ignored
/// signal receives nothing — so a test that sends one would be measuring how
/// the suite was launched.
const withSignalDefaults =
    'import os, signal, sys\n'
    'signal.signal(signal.SIGINT, signal.SIG_DFL)\n'
    'signal.signal(signal.SIGQUIT, signal.SIG_DFL)\n'
    'os.execvp(sys.argv[1], sys.argv[1:])';
