/// Replacing an installed directory whole, so that a failed copy leaves the
/// earlier one as it was.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xtask/xtask.dart';

/// Copies [sources] into a fresh directory beside [into], then swaps it in
/// for whatever [into] held, and answers with an [ExitCode].
///
/// **Only a directory [owner] laid down is replaced.** [into] is refused,
/// naming why, where it exists without [owner]'s mark ([notOurDirectory]) —
/// an app unpacked there by hand, another installer's — and the fresh one is
/// marked before it is swapped in ([markDirectory]), so the next run knows it.
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
  required String owner,
}) async {
  if (notOurDirectory(into, owner: owner) case final why?) {
    context.log(why);
    return ExitCode.taskFailed;
  }
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
  markDirectory(fresh, owner: owner);
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

/// The file an install leaves in the directory it lays down, holding who laid
/// it down: what tells that directory from one of the same name somebody
/// else's put there.
///
/// A mark rather than a guess from the contents: `~/.local/lib/<binary>` and
/// `~/.local/share/<name>` are names anybody may have used, and a directory
/// that looks like an install — a tarball unpacked by hand — is exactly the
/// one that must not be replaced or removed.
const ownerMark = '.xtask_kit';

/// Leaves [owner]'s mark ([ownerMark]) in [directory], which exists.
void markDirectory(String directory, {required String owner}) =>
    File(p.join(directory, ownerMark)).writeAsStringSync('$owner\n');

/// Why [path] is not a directory [owner] may replace or remove, or null
/// where it is — or where nothing is there.
///
/// It is [owner]'s only where it holds [owner]'s mark ([markDirectory]).
/// Anything else is somebody else's, and so is a mark naming another owner:
/// two installs under one name are two installs, not one to replace the
/// other.
String? notOurDirectory(String path, {required String owner}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return null;
  }
  final mark = File(p.join(path, ownerMark));
  if (type == FileSystemEntityType.directory &&
      mark.existsSync() &&
      mark.readAsStringSync().trim() == owner) {
    return null;
  }
  return '$path is not a directory this install made — it has no '
      '$ownerMark naming $owner; move it away first';
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
