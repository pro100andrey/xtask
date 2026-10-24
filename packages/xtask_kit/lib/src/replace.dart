/// Replacing an installed directory whole, so that a failed copy leaves the
/// earlier one as it was.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

/// Copies [sources] into a fresh directory beside [into], then swaps it in
/// for whatever [into] held, and answers with an [ExitCode].
///
/// The copy is `cp -a`, started through [context] like any other process the
/// verb starts: it keeps the executable bits, which `dart:io` cannot set, and
/// its output reaches the run's report. Until the copy has succeeded nothing
/// at [into] is touched — a full disk halfway through leaves the earlier
/// install working and a `.new` beside it, which the next run clears.
///
/// POSIX only, because `cp -a` is. The window in which [into] does not exist
/// is two renames long rather than the length of a copy; it is not zero, and
/// nothing here claims it is.
Future<int> replaceDirectory(
  VerbContext context, {
  required List<String> sources,
  required String into,
}) async {
  final fresh = '$into.new';
  final old = '$into.old';
  for (final leftover in [fresh, old]) {
    if (Directory(leftover).existsSync()) {
      Directory(leftover).deleteSync(recursive: true);
    }
  }
  Directory(fresh).createSync(recursive: true);
  final copied = await context.run(['cp', '-a', ...sources, fresh]);
  if (copied != ExitCode.success) {
    context.log('`cp -a` into $fresh exited with $copied');
    Directory(fresh).deleteSync(recursive: true);
    return ExitCode.taskFailed;
  }
  if (Directory(into).existsSync()) {
    Directory(into).renameSync(old);
  }
  Directory(p.dirname(into)).createSync(recursive: true);
  Directory(fresh).renameSync(into);
  if (Directory(old).existsSync()) {
    Directory(old).deleteSync(recursive: true);
  }
  return ExitCode.success;
}

/// Why [path] cannot be made a link this install owns, or null where it can.
///
/// Anything there that is not a link was put there by somebody else — a
/// binary copied in by hand, another installer's file — and replacing it
/// would destroy it without asking. A link is taken to be an earlier
/// install's, dangling or not.
String? notALink(String path) =>
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.notFound || FileSystemEntityType.link => null,
      _ => '$path is not a link; move it away first',
    };

/// Why [path] is not a link this install may replace or remove, or null
/// where it is — or where nothing is there.
///
/// An install lays down a link into its own directory, [within], so only a
/// link whose target lies inside it is the install's. Anything else is
/// somebody else's: a file ([notALink]), and a link to anywhere else, since
/// pipx, `uv tool` and others link into `~/.local/bin` as well. The target is
/// read from the link itself and resolved from the link's directory, so that
/// a dangling link an earlier install left, or a relative one, is told
/// apart by where it leads rather than by whether it still leads anywhere.
String? notOurLink(String path, {required String within}) {
  if (notALink(path) case final why?) {
    return why;
  }
  if (!FileSystemEntity.isLinkSync(path)) {
    return null;
  }
  final target = p.normalize(p.join(p.dirname(path), Link(path).targetSync()));
  if (p.isWithin(within, target)) {
    return null;
  }
  return '$path is not a link this install made — it points at $target; '
      'move it away first';
}

/// Makes [path] a link to [target], replacing a link already there.
///
/// Checked against [notOurLink] by the caller first; a dangling link counts as
/// one to replace, which is why the type is read without following it.
void pointLink(String path, String target) {
  final link = Link(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    link.deleteSync();
  }
  Directory(p.dirname(path)).createSync(recursive: true);
  link.createSync(target);
}
