/// Where the repository ends.
library;

import 'package:path/path.dart' as p;

/// A bare drive letter — `C:x`, which is relative to that drive's own
/// current directory. `p.windows.isAbsolute` says false about it, correctly,
/// and it still is not this repository's to name.
///
/// One letter and a colon, so `web:build` is not this and `a:b` is. A set that
/// holds paths is checked as one; a `values:` set is not asked this at all,
/// which is what the key is for — the question means nothing about `dev`, and
/// asking it refused `a:b` for looking like a drive.
final _drive = RegExp('^[A-Za-z]:');

/// Whether [path] names anything the repository root does not own.
///
/// `root` is a boundary, not a default, and a boundary needs one guard: every
/// place that turns a written string into a path calls this.
///
/// Nothing absolute, no segment that is `..`, asked in **both** notations. A
/// caller joins the answer with the platform's own `p.join`, and on Windows
/// `..\..` is one POSIX segment that climbs two directories, `\foo` is
/// absolute, and `\\server\share` is absolute enough that `p.join` discards
/// the root entirely.
bool leavesRoot(String path) =>
    p.posix.isAbsolute(path) ||
    p.windows.isAbsolute(path) ||
    _drive.hasMatch(path) ||
    p.posix.split(path).contains('..') ||
    p.windows.split(path).contains('..');

/// Why `in: [written]` on task [task] is refused.
///
/// Here rather than at either caller, because it was written at both: the
/// resolver refuses this when a run reaches the task, `--validate` refuses it
/// when the file is read, and one boundary saying two slightly different
/// sentences is how a diagnostic starts drifting from the rule it reports.
String workingDirectoryLeavesRoot({
  required String task,
  required String written,
}) =>
    'task `$task` says `in: $written`, which reaches outside the repository. '
    'A working directory is relative to the root and stays there — a task '
    'that runs somewhere the repository does not own is not something this '
    'file can vouch for';

/// [written] resolved under [root], or null when the root does not own it.
///
/// **The verb's question, and it is not the file's.** `in:` is text somebody
/// committed, so [leavesRoot] refuses an absolute path outright: a committed
/// file that names `/home/someone/src` is wrong on every other machine. A verb
/// is Dart, and the absolute path it most often holds is the one this engine
/// handed it — `context.workingDirectory` — so asking the file's question of a
/// verb refused the obvious way to be explicit, and said of the repository
/// root itself that it reaches outside the repository.
///
/// So an absolute path is allowed exactly where it lands inside the root, and
/// a relative one is still the file's rule: nothing that climbs, in either
/// platform's notation, because it is about to be joined with the platform's
/// own `p.join`.
String? verbDirectoryUnderRoot(String root, String written) {
  if (p.isAbsolute(written)) {
    final resolved = p.normalize(written);
    return p.equals(root, resolved) || p.isWithin(root, resolved)
        ? resolved
        : null;
  }
  return leavesRoot(written) ? null : underRoot(root, written);
}

/// Why a verb's own working directory is refused on task [task].
///
/// Said of what [verbDirectoryUnderRoot] turned down, so it is said of a path
/// that really is outside the root rather than of every absolute one.
///
/// A verb is Dart rather than YAML, so this names the task and quotes what the
/// verb asked for: the reader has to find a call, not a key.
String verbDirectoryLeavesRoot({
  required String task,
  required String written,
}) =>
    'task `$task` runs a verb that asked to start a program in `$written`, '
    'which reaches outside the repository. A working directory is relative to '
    'the root and stays there, whether the file wrote it or a verb did';

/// The name `remove` is written under in `do:`.
///
/// Spelled once, because four things name it: the closed list of built-in
/// verbs, the binding beside it, the diagnostics that say what a set fed to it
/// should look like, and `--validate`.
///
/// **Here and not beside the implementation.** `validate.dart` needs the name
/// and nothing else, and reaching for it through `primitives.dart` gave that
/// module the verb it is checking — one import away from calling it. It is a
/// smaller distance than it looks and not an airtight one: `sets.dart` brings
/// `dart:io` there anyway, so this removes a reason to reach rather than the
/// ability to.
const removeVerbName = 'remove';

/// Why `remove` refuses the argument [written].
///
/// Beside [workingDirectoryLeavesRoot] and for the same reason, which now has
/// three callers rather than two: the verb refuses this when a run reaches it,
/// `--dry-run` has to say the same thing rather than print a plan the run will
/// not carry out, and `--validate` answers the question without a filesystem
/// at all. This is the verb that deletes recursively; three sentences drifting
/// apart is the last place to allow it.
String removeLeavesRoot({required String written}) =>
    '`remove` refuses `$written`: it names a path outside the '
    'repository. A verb that deletes recursively and treats a missing path '
    'as ordinary is the last place to take a path on trust';

/// [posixPath], written the way this machine writes paths, under [root].
///
/// **The file speaks POSIX and the machine may not.** Every path in
/// `xtask.yaml` is written with `/`, because the file is committed and read on
/// three platforms. Joining one onto a native root without re-splitting leaves
/// a mixed separator — `C:\repo\packages/a` — which Windows accepts and
/// `--dry-run` then prints back at a reader as the plan.
///
/// `remove` and `--check-ci` re-split; `in:` and a verb's own working
/// directory did not, for no reason anybody wrote down. One function, so the
/// platform question stops being restated.
String underRoot(String root, String posixPath) => posixPath.isEmpty
    ? root
    : p.join(root, p.joinAll(p.posix.split(posixPath)));

/// [path] relative to [root], written with `/` on every platform.
///
/// The other direction, and normalised for the same reason: this string
/// becomes a process argument and a set member, and an argument list that
/// differs between platforms is a portability claim with a hole in it.
String relativePosix(String path, {required String root}) {
  final relative = p.relative(path, from: root);
  // **Split and rejoined only where that changes something.** On a POSIX host
  // `p.relative` has already produced the answer, and reproducing its input
  // exactly costs a list, a substring per segment and a second string — once
  // per entry of every walk, which is tens of thousands on a real repository.
  return p.style == p.Style.posix
      ? relative
      : p.posix.joinAll(p.split(relative));
}
