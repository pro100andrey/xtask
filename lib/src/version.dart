/// This package's version, for `--version` — §7 of `xtask.md`.
library;

/// The version, spelled the same as `pubspec.yaml` spells it.
///
/// **A second mention of one fact, made safe rather than removed.** The number
/// is in the manifest because pub needs it there, and it has to be in code
/// because a compiled entry point has no manifest beside it to read. §1 is
/// about drift, not about a fact being named twice — so the answer is that
/// nothing may drift: `test/dogfood_test.dart` reads `pubspec.yaml` and fails
/// if these two disagree, naming both numbers.
///
/// A generator was considered and refused. For one line it is more machinery
/// than the drift it prevents, and it would ship this repository's release
/// tooling to every consumer of the package; the gate is what stops the drift
/// in either design, so only the gate was built.
const packageVersion = '0.1.0';
