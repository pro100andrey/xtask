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
