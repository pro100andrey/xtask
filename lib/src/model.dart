/// The typed shape of `xtask.yaml`.
///
/// Nothing here checks that a name refers to something that exists, and
/// nothing builds a graph. A value in this file means "the document fitted the
/// types"; whether it is coherent is `validate`'s question and whether it can
/// run is `graph`'s.
library;

import 'package:source_span/source_span.dart';

/// Every key a task may carry (§4.3).
///
/// **This is the only list of them.** §8 refuses an unknown task key, and the
/// obvious way to implement that refusal — a second set of names in the
/// validator — is the defect this tool exists to remove, reproduced inside
/// the tool written to remove it. Anything that needs to know what a
/// task key is reads this.
const taskKeys = <String>{
  'desc',
  'run',
  'do',
  'args',
  'all',
  'each',
  'in',
  'env',
  'env-required',
  'needs',
  'then',
  'gate',
  'timeout',
};

/// The one word that stands for every member of an `all:` set.
///
/// **Here, beside the keys, because two modules answer for it.** The parser
/// decides which files are legal and the resolver decides what a legal one
/// expands to; they had a private copy each, which is the contract and its
/// enforcement free to drift. They did: one counted the marker in the
/// executable slot and the other never substituted there, so a set could be
/// declared, pass every check, and reach nothing.
const allMarker = r'$all';

/// Every key the document may carry at the top level (§4.1).
const topLevelKeys = <String>{'version', 'gates', 'sets', 'tasks'};

/// Every key a glob set may carry (§4.2).
///
/// Here rather than beside the parser for the reason above: `--emit-schema`
/// projects it into a JSON Schema, and a second spelling of `include` is a
/// second spelling that an editor would accept and the engine would refuse.
const globSetKeys = <String>{'include', 'exclude'};

/// The keys that name a task's body. Exactly one, or none (§4.3).
const bodyKeys = <String>{'run', 'do'};

/// The only `version:` this engine reads. An unknown one is a hard refusal,
/// never a best-effort read (§4.1).
const supportedVersion = 1;

/// Something read out of the file, which therefore has a place in it.
///
/// **The span travels with the value, and that is the whole point.** §8
/// promises that a refusal says which line to look at, but a refusal is not
/// only raised while parsing: a set that expands to nothing, a cycle, a
/// dangling name — each is found after the document has become these types,
/// and each has to name a line. Dropping the span at the parser boundary is
/// what makes every later message say "somewhere in your file".
mixin Located {
  /// Where this was written — the key that names it, not the block it owns,
  /// so a message points at one line rather than reprinting a whole task.
  SourceSpan? get span;
}

/// A parsed `xtask.yaml`.
final class XtaskFile {
  const XtaskFile({
    required this.version,
    required this.gates,
    required this.sets,
    required this.tasks,
  });

  /// Always [supportedVersion] — parsing refuses anything else rather than
  /// carrying the number forward for somebody downstream to check.
  final int version;

  /// Every gate set the file declares, **in declaration order**, each with
  /// the line it was written on.
  ///
  /// **Declared, because a gate set that came into existence by being
  /// mentioned could not be misspelled.** It used to: a gate existed as soon
  /// as a task said it was in one, so `gate: [chekc]` made a new gate with one
  /// member — caught, but only sideways, by the orphan check downstream — and
  /// a misspelling was simply a different gate set. One declared list is
  /// what makes a name in `gate:` checkable at all.
  ///
  /// The order is the author's and is the order a report groups by. It carries
  /// no description: a gate set is not a task, it is the name of who runs a
  /// list.
  final Map<String, SourceSpan?> gates;

  /// Named sets, in declaration order. Unmodifiable — see [tasks].
  final Map<String, NamedSet> sets;

  /// Named tasks, **in declaration order**, which is load-bearing: §4.3 makes
  /// the run order of a gate set the order its tasks appear in the file, so
  /// that cheap gates come before slow ones. Dart's default map
  /// preserves insertion order and the parser inserts in document order; the
  /// YAML specification does not promise this, so a test pins it.
  ///
  /// **Unmodifiable, and that follows from the sentence above.** An order that
  /// is load-bearing and a map anybody can reorder do not go together. The
  /// same applies to every collection on [Task]: the `const []` defaults throw
  /// on mutation, so a parsed value that quietly accepted one would make the
  /// type behave two different ways depending on what the file happened to
  /// say.
  final Map<String, Task> tasks;
}

/// A set is either a plain list or a glob with exclusions (§4.2).
sealed class NamedSet with Located {
  const NamedSet({this.span});

  @override
  final SourceSpan? span;
}

/// Members written out one by one.
final class ListSet extends NamedSet {
  const ListSet(this.members, {super.span});

  final List<String> members;
}

/// Members found on disk. Expansion — and the rule that an expansion matching
/// nothing is an error — belongs to the `sets` slice, not here.
final class GlobSet extends NamedSet {
  const GlobSet({required this.include, required this.exclude, super.span});

  final List<String> include;
  final List<String> exclude;
}

/// What a task does. Absent means a pure composite (§4.3).
sealed class Body {
  const Body();
}

/// An external process, as argv. The first element is the executable, the rest
/// are arguments, and none of it is ever passed to a shell (§5.2).
final class RunBody extends Body {
  const RunBody(this.argv);

  final List<String> argv;
}

/// A verb: a built-in primitive, or one the project registered (§9).
final class DoBody extends Body {
  const DoBody(this.verb);

  final String verb;
}

/// One node of the task graph (§4.3).
final class Task with Located {
  const Task({
    required this.name,
    required this.desc,
    this.span,
    this.body,
    this.args = const [],
    this.all,
    this.each,
    this.workingDirectory,
    this.env = const {},
    this.envRequired = const [],
    this.needs = const [],
    this.then = const [],
    this.gate = const [],
    this.timeout,
  });

  @override
  final SourceSpan? span;

  /// The key this task was written under.
  final String name;

  /// One line, shown by `--list`. Required, so that a task cannot be added
  /// without saying what it is for.
  final String desc;

  /// `run:` or `do:`, or null for a pure composite. Two is refused at parse.
  final Body? body;

  /// Extra arguments appended to the body.
  final List<String> args;

  /// A set whose members replace the `$all` marker, in one invocation.
  ///
  /// **The marker is where they go, and that is the whole difference from the
  /// key this replaces.** `argv-from:` appended its set to the end of argv and
  /// nowhere else, so `cp <files> dest/` could not be written at all; and
  /// beside an `each:`, it handed the WHOLE set to every member, which nothing
  /// refused and nobody meant.
  final String? all;

  /// A set whose members the body runs once per, sequentially (§5.2).
  final String? each;

  /// `in:` — a path, or the literal `$each`. The substitution is execution's
  /// business; the model keeps what was written.
  final String? workingDirectory;

  /// Environment for this task only. A key rather than syntax, because
  /// `FOO=bar cmd` is shell on POSIX and something else on Windows (§6).
  final Map<String, String> env;

  /// Variables that must already be set. Checked before the body runs; the
  /// engine installs nothing (§7.1).
  final List<String> envRequired;

  /// Direct requirements only — transitive is the graph's business (§4.3).
  final List<String> needs;

  /// Continuations: run after this task's body, not a dependency (§4.3).
  final List<String> then;

  /// The gate sets this task belongs to.
  final List<String> gate;

  /// Seconds a `run:` body may take before it is killed, or null for no
  /// limit.
  ///
  /// **A `run:` body only.** A verb is a Dart function, and Dart cannot stop
  /// one from outside: a deadline on it would report a timeout while the verb
  /// carried on writing to the disk, which is worse than no deadline at all.
  /// `parse` refuses the combination rather than letting it half-work.
  final int? timeout;
}
