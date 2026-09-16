/// The typed shape of `xtask.yaml`.
///
/// Nothing here checks that a name refers to something that exists, and
/// nothing builds a graph. A value in this file means "the document fitted the
/// types"; whether it is coherent is `validate`'s question and whether it can
/// run is `graph`'s.
library;

import 'package:source_span/source_span.dart';

/// Every key a task may carry (a task's keys).
///
/// **This is the only list of them.** An unknown task key is refused, and the
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
  'serial',
  'interruptible',
  'exclusive',
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

/// The one word that stands for the member an `each:` body is running for.
///
/// It may stand as a whole argument or END one, and nothing may follow it.
///
/// A prefix is what lets a set hold the part that cannot be derived — the bare
/// name — with the path composed where it is needed. A suffix would make
/// `$each.dart` a path computed FROM a value rather than one composed around
/// it, and computing wants a modifier, and a modifier wants a language.
const eachMarker = r'$each';

/// [written] with a trailing `$each` standing for [member].
///
/// Only at the end, which the parser has already refused anything else for.
/// The prefix survives, and that is the whole of what it buys: a set may hold
/// the bare name a path cannot be derived from — `lake_cli` — and the path is
/// composed where it is used, `in: packages/$each`.
String withMember(String written, String member) => written.endsWith(eachMarker)
    ? written.substring(0, written.length - eachMarker.length) + member
    : written;

/// Every string [written] can come to, with the markers standing for what
/// they name.
///
/// **The one substitution rule.** The resolver asks it for a run, with the
/// one member `$each` stands for; the validator asks it for a file, with
/// every member a `values:` set holds, so that a path composed around a
/// member is checked before anything runs. Two readings of one rule is how
/// `--validate` came to call clean a file the run refused.
///
/// `$all` as a whole word is every member of [all]; a word ending in `$each`
/// is that word with a member of [each] on the end, once per member.
List<String> substituted(
  Iterable<String> written, {
  required List<String> all,
  required List<String> each,
}) => [
  for (final word in written)
    if (word == allMarker)
      ...all
    else if (word.endsWith(eachMarker) && each.isNotEmpty)
      for (final member in each) withMember(word, member)
    else
      word,
];

/// Every key the document may carry at the top level (the top level).
const topLevelKeys = <String>{'version', 'gates', 'sets', 'tasks'};

/// Every key a glob set may carry (sets).
///
/// Here rather than beside the parser for the reason above: `--emit-schema`
/// projects it into a JSON Schema, and a second spelling of `include` is a
/// second spelling that an editor would accept and the engine would refuse.
const globSetKeys = <String>{'include', 'exclude', 'produced-by'};

/// Every key a value set may carry (sets).
const valueSetKeys = <String>{'values'};

/// The keys that name a task's body. Exactly one, or none (a task's keys).
const bodyKeys = <String>{'run', 'do'};

/// The only `version:` this engine reads. An unknown one is a hard refusal,
/// never a best-effort read (the top level).
const supportedVersion = 1;

/// Something read out of the file, which therefore has a place in it.
///
/// **The span travels with the value, and that is the whole point.** A
/// refusal says which line to look at, but a refusal is not
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
  /// Declared, because a gate set that came into existence by being mentioned
  /// could not be misspelled: `gate: [chekc]` would simply be a different gate
  /// set. One declared list is what makes a name in `gate:` checkable.
  ///
  /// The order is the author's, and is the order a report groups by. No
  /// description: a gate set is not a task, it is the name of who runs a
  /// list.
  final Map<String, SourceSpan?> gates;

  /// Named sets, in declaration order. Unmodifiable — see [tasks].
  final Map<String, NamedSet> sets;

  /// Named tasks, **in declaration order**, which is load-bearing: a gate set
  /// runs in the order its tasks appear, so cheap gates come before
  /// slow ones. Dart's map preserves insertion order and the parser inserts in
  /// document order; the YAML specification does not promise it, so a test
  /// pins it.
  ///
  /// Unmodifiable, because an order that is load-bearing and a map anybody can
  /// reorder do not go together. The same holds for every collection on
  /// [Task].
  final Map<String, Task> tasks;
}

/// A set is either a plain list or a glob with exclusions (sets).
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

/// Members that are not paths: flavours, platform names, SDK versions.
///
/// **Declared, because the engine cannot tell.** Every other kind of set holds
/// paths, and the engine treats them as paths — it refuses one that leaves the
/// repository, and it can say a glob matched nothing. Neither question means
/// anything about `dev` or `stable`, and asking the first of them refused
/// `a:b` for looking like a Windows drive. A set that says what it holds is
/// asked the right questions, and `in: packages/$each` composes a path around
/// a member that was never one.
final class ValueSet extends NamedSet {
  const ValueSet(this.values, {super.span});

  final List<String> values;
}

/// Members found on disk. Expansion — and the rule that an expansion matching
/// nothing is an error — belongs to the `sets` slice, not here.
final class GlobSet extends NamedSet {
  const GlobSet({
    required this.include,
    required this.exclude,
    this.producedBy,
    super.span,
  });

  final List<String> include;
  final List<String> exclude;

  /// The task that makes this set's members, or null when they are simply
  /// there.
  ///
  /// A name rather than a flag, so that the edge can be checked: `--validate`
  /// asks that every task reading the set reaches its producer through
  /// `needs:`, which is what keeps the order under `-j` as well as in the
  /// file. It buys exactly one thing beyond that: the emptiness of THIS set
  /// is not judged before its producer has run. Everything else about it
  /// still is, and the run still refuses it empty.
  final String? producedBy;
}

/// What a task does. Absent means a pure composite (a task's keys).
sealed class Body {
  const Body();
}

/// An external process, as argv. The first element is the executable, the rest
/// are arguments, and none of it is ever passed to a shell (the run).
final class RunBody extends Body {
  const RunBody(this.argv);

  final List<String> argv;
}

/// A verb: a built-in primitive, or one the project registered.
final class DoBody extends Body {
  const DoBody(this.verb);

  final String verb;
}

/// One node of the task graph (a task's keys).
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
    this.serial = false,
    this.interruptible = false,
    this.exclusive = const [],
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

  /// A set whose members the body runs once per, one at a time unless `-j`
  /// says otherwise.
  final String? each;

  /// `in:` — a path, or the literal `$each`. The substitution is execution's
  /// business; the model keeps what was written.
  final String? workingDirectory;

  /// Environment for this task only. A key rather than syntax, because
  /// `FOO=bar cmd` is shell on POSIX and something else on Windows .
  final Map<String, String> env;

  /// Variables that must already be set. Checked before the body runs; the
  /// engine installs nothing (one invocation per job).
  final List<String> envRequired;

  /// Direct requirements only — transitive is the graph's business (a task's
  /// keys).
  final List<String> needs;

  /// Continuations: run after this task's body, not a dependency (a task's
  /// keys).
  final List<String> then;

  /// Whether the members of this task's `each:` must not overlap.
  ///
  /// A fact about the task rather than a number for the machine: `-j` says how
  /// much may happen at once, this says whether these members may happen
  /// together at all. `dart pub get` over six packages contends on one
  /// `~/.pub-cache` and `git add` fails outright on `index.lock`. Getting it
  /// wrong makes a run flaky on every machine, so it lives in the file.
  final bool serial;

  /// Whether a failure elsewhere may kill this task where it stands.
  ///
  /// The author saying there is no half-written state to leave behind.
  /// Killing a build leaves whatever it was half-way through; `dart format
  /// --output=none`, `dart analyze` and `dart test` leave nothing. The engine
  /// cannot tell the two apart.
  ///
  /// It buys back what `-j` costs: sequentially a format failure at 0.4s stops
  /// analyze and test from running at all, and in parallel they run to the end
  /// anyway.
  final bool interruptible;

  /// Tokens this task holds alone for as long as it runs.
  ///
  /// The same fact across tasks rather than within one: two suites that both
  /// bind `:8080`, or both drive one browser, cannot overlap however
  /// independent the graph says they are. Named rather than counted, because a
  /// name is something `--validate` can cross-check and a count is one
  /// machine's width written into a file every other machine reads.
  final List<String> exclusive;

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

/// Why [task] would hand a member its glob FOUND to [program] as an option,
/// or null.
///
/// Found, not written: a repository may hold a file called `-n.dart`, and a
/// glob handing it over bare gives the program `-n`. A `values:` or list set
/// is the opposite — `--enable-asserts` is there because somebody wrote it —
/// so this asks where the member came from, not what it looks like.
///
/// And it asks about the ARGUMENT: `--flavor=$each` is one word the author
/// composed, so only a marker standing alone becomes a word this engine chose.
///
/// Refused rather than fixed, because inserting `--` would change the argv a
/// task wrote.
///
/// **Here rather than on the resolver**, because two readers ask it and only
/// one could: the run and `--dry-run` reached it, `--validate` did not, and it
/// already expands every set — so a file it called clean died at exit 2 the
/// moment anybody ran the task.
String? foundMemberReadAsOption({
  required Task task,
  required String program,
  required List<String> written,
  required List<String> members,
  required NamedSet? from,
}) {
  if (from is! GlobSet) {
    return null;
  }
  // **`args:` is argv too**, which the schema says in as many words:
  // `run: [dart, format]` with `args: [$all]` hands a repository file called
  // `-n.dart` to the child as an option, and this is where that is caught.
  final bare = written.indexWhere(
    (word) => word == allMarker || word == eachMarker,
  );
  if (bare == -1) {
    // The member reaches `in:` or `env:` and never argv. Saying it would be
    // read as an option would be false, and the advice — a `--` before a
    // marker that is not there — impossible to follow.
    return null;
  }
  if (written.take(bare).contains('--')) {
    return null;
  }
  final found = members.where((member) => member.startsWith('-'));
  if (found.isEmpty) {
    return null;
  }
  return 'task `${task.name}` would hand `${found.first}` to `$program` as '
      'an argument, and a word beginning with `-` is an option to almost every '
      'program. This one was matched by a glob rather than written, so write '
      '`--` before the marker, which is where a command line says its operands '
      'begin';
}
