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
/// **`root` is a boundary, not a default, and a boundary needs one guard.**
/// This test used to exist twice — once for the patterns in a set, once for
/// the arguments `remove` deletes — and the two copies were not the whole
/// fence. A set's written members never met either of them, so
/// `sets: {escape: ['/etc']}` walked straight through `expand`, and `in:` had
/// no check at all, so a task could run its body two levels above the root.
/// Both were reachable from a committed file with no diagnostic anywhere:
/// exactly the failure the copies were written to prevent, arriving through
/// the gap between them.
///
/// So it is one function, and every place that turns a written string into a
/// path calls it.
///
/// **Both notations, not just the file's own.** The rule is the one those
/// copies applied — nothing absolute, no segment that is `..` — but they asked
/// it of POSIX alone, and every caller then joins the answer with the
/// platform's own `p.join`. On Windows that let four native spellings through
/// a gate written to stop them: `..\..` is one POSIX segment and climbs two
/// directories, `\foo` is absolute, and `\\server\share` is so absolute
/// that `p.join` discards the root entirely and lands a recursive delete on
/// somebody else's file server. A fence read in one notation is not a fence on
/// a machine that writes in the other, so this asks both.
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

/// The name `remove` is written under in `do:`.
///
/// Spelled once, because four things name it: the closed list of built-in
/// verbs, the binding beside it, the diagnostics that say what a set fed to it
/// should look like, and `--validate`.
///
/// **Here and not beside the implementation.** `validate.dart` needs the name
/// and nothing else, and reaching for it through `primitives.dart` brought
/// `dart:io` and `package:glob` into the module whose promise is that it
/// answers without a filesystem at all — so nothing then stops a later edit
/// from calling the verb it is checking.
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
