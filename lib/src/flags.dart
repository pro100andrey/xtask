/// The options a run may carry, named once.
library;

/// Flags that modify a run rather than replacing it with something else.
///
/// **One list, because two of them drift.** The command line decides what it
/// accepts and `--check-ci` decides what a workflow step may carry, and they
/// had a copy each: adding a flag to one meant `--check-ci` reporting a
/// working workflow as a step doing something other than running a gate. That
/// is the duplicate-list defect this tool exists to remove, grown inside it.
const runModifiers = {'-j', '--jobs', '--keep-going'};

/// Of those, the ones whose value may be written as a separate word.
///
/// `--jobs=4` carries its value after an `=` and `-j4` carries it joined;
/// `-j=4` is neither, and the command line refuses it.
const takesAValue = {'-j', '--jobs'};

/// Whether [written] is a number of jobs the command line would accept.
///
/// Asked by the parser when it reads one and by `--check-ci` when it vouches
/// for a step that carries one, so a workflow cannot be called green for a
/// command that exits 2 the moment it runs.
bool isAJobCount(String written) =>
    written == 'auto' || (int.tryParse(written) ?? 0) >= 1;
