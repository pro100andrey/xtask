import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'coherence.dart';
import 'errors.dart';
import 'model.dart';
import 'readable.dart';

/// Reads `xtask.yaml` into the types of [XtaskFile].
///
/// Refuses anything that does not fit those types, at the line that did not
/// fit. It does **not** check that a name refers to something real, does not
/// look for cycles and does not touch the filesystem: those are `validate`,
/// `graph` and `sets`, and keeping them out of here is what stops this
/// function from quietly becoming the whole engine.
XtaskFile parseXtaskFile(String source, {Uri? sourceUrl}) {
  // Ahead of both readers, so that the scan and the parser are looking at the
  // same string — a mark left in for one of them is a span the other cannot
  // place.
  final text = withoutByteOrderMark(source);

  // Before the parser, because afterwards there is nothing left to see: by the
  // time an [XtaskFile] exists, `package:yaml` has already expanded every
  // alias into a copy and the evidence is gone. §8 specifies this as a scan of
  // the raw text for exactly that reason, and this is the only function that
  // ever holds the raw text.
  refuseUnreadableSyntax(text, sourceUrl);

  final YamlNode document;
  try {
    document = loadYamlNode(text, sourceUrl: sourceUrl);
  } on YamlException catch (e) {
    // The underlying parser's own complaint, kept with its span rather than
    // re-worded: it knows better than this layer what it could not read.
    throw XtaskFormatException(e.message, e.span);
  }

  if (document is YamlScalar && document.value == null) {
    throw XtaskFormatException('the file is empty');
  }

  final root = _asMap(document, 'the file');

  // Version first, and the order is not cosmetic. A key this engine does not
  // know may be a perfectly ordinary key of the version the file declares, so
  // refusing it before reading the version would answer the wrong question —
  // and would answer it in the terms of a dialect nobody claimed to be
  // writing. §4.1 makes an unknown version a hard refusal; it therefore has to
  // be the first refusal.
  final version = _version(root);
  _refuseUnknownKeys(root, topLevelKeys, 'top-level key');

  return XtaskFile(
    version: version,
    gates: Map.unmodifiable(_gates(root)),
    // Unmodifiable, and §4.3 is why for `tasks`: its ORDER is load-bearing —
    // a gate set runs its tasks in the order they appear — and
    // a map anybody downstream can reorder is an order nobody can rely on.
    sets: Map.unmodifiable(_sets(root)),
    tasks: Map.unmodifiable(_tasks(root)),
  );
}

// ── top level ───────────────────────────────────────────────────────────────

int _version(YamlMap root) {
  final node = root.nodes['version'];
  if (node == null) {
    throw XtaskFormatException(
      '`version:` is required — an engine that guesses which dialect it is '
      'reading is one that reads the next dialect wrong',
      // A point at the top of the file, not the file. `SourceSpan.message`
      // reprints everything its span covers, so handing it the root mapping
      // answers "which line?" with all of them — on §12's example, ninety.
      root.span.start.pointSpan(),
    );
  }
  final value = node.value;
  if (value is! int) {
    throw XtaskFormatException('`version:` must be an integer', node.span);
  }
  if (value != supportedVersion) {
    throw XtaskFormatException(
      'unknown `version: $value` — this engine reads version '
      '$supportedVersion, and an unknown version is refused rather than read '
      'as best it can be',
      node.span,
    );
  }
  return value;
}

/// The declared gate sets, in the order written, each with its own line.
///
/// **A list of names and nothing else.** A gate set is not a task: it has no
/// description, no body and nothing to run of its own — it is the name of who
/// runs a list, and the list is whichever tasks say they are in it. Giving it
/// a description here would invite a second one on the composite that gathers
/// it, and two descriptions of one thing is the defect §1 exists to remove.
Map<String, SourceSpan?> _gates(YamlMap root) {
  final node = root.nodes['gates'];
  if (node == null) {
    return const {};
  }
  if (node is! YamlList) {
    throw XtaskFormatException(
      '`gates:` is a list of names — `gates: [check, release]`. Names only: '
      'a gate set is not a task and has nothing to describe',
      node.span,
    );
  }
  if (node.nodes.isEmpty) {
    throw XtaskFormatException(
      '`gates:` is written with no names. Leave it out rather than declare '
      'nothing: an empty list says a file has gate sets and then names none',
      node.span,
    );
  }

  final gates = <String, SourceSpan?>{};
  for (final item in node.nodes) {
    final name = _name(item, 'a gate name');
    if (gates.containsKey(name)) {
      throw XtaskFormatException(
        'gate set `$name` is declared twice. The order of this list is the '
        'order a report groups by, and a name in it twice has two places',
        item.span,
      );
    }
    gates[name] = item.span;
  }
  return gates;
}

Map<String, NamedSet> _sets(YamlMap root) {
  final node = root.nodes['sets'];
  if (node == null) {
    return const {};
  }

  final map = _asMap(node, '`sets:`');
  final sets = <String, NamedSet>{};
  for (final key in _keyNodes(map)) {
    final name = _name(key, 'a set name');
    sets[name] = _namedSet(map.nodes[name]!, name, key.span);
  }
  return sets;
}

NamedSet _namedSet(YamlNode node, String name, SourceSpan keySpan) {
  if (node is YamlList) {
    return ListSet(_stringList(node, 'set `$name`'), span: keySpan);
  }
  if (node is YamlMap) {
    if (node.nodes.containsKey('values')) {
      _refuseUnknownKeys(node, valueSetKeys, 'key in value set `$name`');
      return ValueSet(
        _stringList(node.nodes['values']!, '`values:` of set `$name`'),
        span: keySpan,
      );
    }
    _refuseUnknownKeys(node, globSetKeys, 'key in glob set `$name`');
    final include = node.nodes['include'];
    if (include == null) {
      throw XtaskFormatException(
        'set `$name` is a glob and so needs `include:`',
        keySpan,
      );
    }
    final exclude = node.nodes['exclude'];
    return GlobSet(
      include: _stringList(include, '`include:` of set `$name`'),
      exclude: exclude == null
          ? const []
          : _stringList(exclude, '`exclude:` of set `$name`'),
      produced: _flag(node, 'produced', 'set `$name`'),
      span: keySpan,
    );
  }
  throw XtaskFormatException(
    'set `$name` must be a list of paths, a mapping with `include:` and '
    'optionally `exclude:`, or a mapping with `values:` for members that are '
    'not paths at all',
    keySpan,
  );
}

Map<String, Task> _tasks(YamlMap root) {
  final node = root.nodes['tasks'];
  if (node == null) {
    return const {};
  }

  final map = _asMap(node, '`tasks:`');
  // Insertion order is document order, and §4.3 leans on it: a gate set runs
  // its tasks in the order they appear, so that cheap gates come before slow
  // ones. A test pins this rather than trusting it — the
  // YAML specification does not promise a mapping keeps its order, every
  // implementation does, and the gap between those two sentences is exactly
  // where a gate would silently reorder.
  final tasks = <String, Task>{};
  for (final key in _keyNodes(map)) {
    final name = _name(key, 'a task name');
    tasks[name] = _task(map.nodes[name]!, name, key.span);
  }
  return tasks;
}

// ── one task ────────────────────────────────────────────────────────────────

Task _task(YamlNode node, String name, SourceSpan keySpan) {
  final map = _asMap(node, 'task `$name`');
  _refuseUnknownKeys(map, taskKeys, 'key in task `$name`');

  final desc = map.nodes['desc'];
  if (desc == null) {
    throw XtaskFormatException(
      'task `$name` has no `desc:` — every task says in one line what it is '
      'for, which is what makes `--list` worth reading',
      // The task's own key, not its whole block: pointing at `analyze:` is an
      // answer, reprinting everything under it is a shrug.
      keySpan,
    );
  }

  final body = _body(map, name);

  final task = Task(
    name: name,
    span: keySpan,
    desc: _description(desc, name),
    body: body,
    timeout: _timeout(map, name),
    args: List.unmodifiable(_optionalStringList(map, 'args', name)),
    all: _optionalString(map, 'all', name),
    each: _optionalString(map, 'each', name),
    workingDirectory: _optionalString(map, 'in', name),
    env: Map.unmodifiable(_env(map, name)),
    envRequired: List.unmodifiable(
      _optionalStringList(map, 'env-required', name),
    ),
    needs: _names(map, 'needs', name),
    then: _names(map, 'then', name),
    gate: _names(map, 'gate', name),
    serial: _flag(map, 'serial', 'task `$name`'),
    interruptible: _flag(map, 'interruptible', 'task `$name`'),
    exclusive: _names(map, 'exclusive', name),
  );
  // The document is here and nowhere else, so this is where a rule whose
  // subject is a key can be told where that key is written.
  _refuseIncoherent(task, (key) => map.nodes[key]?.span);
  return task;
}

/// Refuses a task whose keys contradict each other — **all of them at once**.
///
/// The rules are `coherence.dart`'s, and they answer with a list; the policy is
/// this module's, and it is to refuse. A file with three marker mistakes used
/// to cost three rounds of fix-and-rerun, because the first `throw` hid the
/// other two — the very loop `validate.dart` argues against.
///
/// This stays the only gate. A run does not validate first, and
/// `BodyResolver._withMember` throws a `StateError` on a member that is not
/// there, on the strength of the file having been refused here.
void _refuseIncoherent(Task task, SourceSpan? Function(String key) keySpan) {
  final wrong = incoherences(task, keySpan: keySpan);
  if (wrong.isEmpty) {
    return;
  }
  if (wrong.length == 1) {
    throw wrong.single;
  }
  // One caret, because every one of these is about the same task, and a span
  // per paragraph would reprint the block once per mistake.
  throw XtaskFormatException(
    wrong.map((problem) => problem.message).join('\n\n'),
    task.span,
  );
}

/// `interruptible:`, refused where it cannot be honoured.
///
/// **A `run:` body only, for `timeout:`'s reason.** Stopping a verb means
/// stopping a Dart function from outside, which Dart cannot do — the flag
/// would read as a promise and the verb would carry on writing to the disk.
/// A boolean key, refused rather than coerced.
///
/// `serial: yes` is a string in YAML 1.2 and would be truthy in a language
/// that guessed. This file does not guess.
bool _flag(YamlMap map, String key, String owner) {
  final node = map.nodes[key];
  if (node == null) {
    return false;
  }
  final value = node.value;
  if (value is bool) {
    return value;
  }
  throw XtaskFormatException(
    '`$key:` of $owner is `$value`, and it is a yes or no — write `true` or '
    '`false`',
    node.span,
  );
}

/// `timeout:` in seconds — the number itself.
///
/// Which body may carry one is `coherence.dart`'s question, asked with the
/// rest of them: it reads `timeout:` against `do:`, which is a key against a
/// key, and this module answers about types.
int? _timeout(YamlMap map, String taskName) {
  final node = map.nodes['timeout'];
  if (node == null) {
    return null;
  }
  final value = node.value;
  if (value is! int) {
    throw XtaskFormatException(
      '`timeout:` of task `$taskName` must be a whole number of seconds',
      node.span,
    );
  }
  if (value <= 0) {
    // Zero would mean "kill it before it starts", which nobody means; a
    // negative is a typo. Neither is a limit.
    throw XtaskFormatException(
      '`timeout:` of task `$taskName` is $value, which is not a length of '
      'time. Leave it out to run without a limit',
      node.span,
    );
  }
  return value;
}

Body? _body(YamlMap map, String taskName) {
  // In the order they appear in the FILE, not in the order `bodyKeys` happens
  // to list them: the message names them and the caret points at one of them,
  // and the two saying different things is a message that argues with itself.
  final declared = [
    for (final key in _keyNodes(map))
      if (key.value is String && bodyKeys.contains(key.value))
        key.value as String,
  ];
  if (declared.length > 1) {
    throw XtaskFormatException(
      'task `$taskName` declares two bodies, `${declared[0]}:` and '
      '`${declared[1]}:` — a task has exactly one, or none and is a composite',
      map.nodes[declared[1]]!.span,
    );
  }
  if (declared.isEmpty) {
    return null;
  }

  final key = declared.single;
  final node = map.nodes[key]!;
  if (key == 'do') {
    return DoBody(
      _nonEmpty(
        _string(node, '`do:` of task `$taskName`'),
        node,
        'a verb name',
      ),
    );
  }

  final argv = _stringList(node, '`run:` of task `$taskName`');
  if (argv.isEmpty) {
    throw XtaskFormatException(
      '`run:` of task `$taskName` is empty — its first element is the '
      'executable, so there is nothing here to start',
      node.span,
    );
  }
  // Only the first. An empty ARGUMENT is ordinary — `dart test --name ''` —
  // but an empty executable resolves to nothing and would surface as a missing
  // tool (code 3) when the defect is in the file (code 2).
  _nonEmpty(argv.first, node, 'the executable of `run:`');
  return RunBody(List.unmodifiable(argv));
}

/// `desc:` — required, and one line (§4.3).
String _description(YamlNode node, String taskName) {
  final desc = _nonEmpty(
    _string(node, '`desc:` of task `$taskName`'),
    node,
    '`desc:` of task `$taskName`',
  );
  if (desc.contains('\n')) {
    throw XtaskFormatException(
      '`desc:` of task `$taskName` runs to more than one line. It is what '
      '`--list` prints beside the task name, so it is one line by contract, '
      'not by convention',
      node.span,
    );
  }
  return desc;
}

/// A list of names, each of which has to name something.
List<String> _names(YamlMap map, String key, String taskName) {
  final node = map.nodes[key];
  if (node == null) {
    return const [];
  }
  final values = _stringList(node, '`$key:` of task `$taskName`');
  for (final value in values) {
    _nonEmpty(value, node, 'an entry of `$key:` in task `$taskName`');
  }
  return List.unmodifiable(values);
}

/// [value], or a refusal naming [what].
///
/// An empty string parses fine and means nothing, so without this a file
/// defect travels on as a runtime one: an empty verb name reaches the registry
/// as "no such verb", an empty executable reaches §5.4 as a missing tool
/// (code 3) when the file was wrong (code 2).
String _nonEmpty(String value, YamlNode node, String what) {
  if (value.trim().isNotEmpty) {
    return value;
  }
  throw XtaskFormatException('$what is empty', node.span);
}

Map<String, String> _env(YamlMap map, String taskName) {
  final node = map.nodes['env'];
  if (node == null) {
    return const {};
  }

  final envMap = _asMap(node, '`env:` of task `$taskName`');
  final env = <String, String>{};
  for (final key in _keyNodes(envMap)) {
    final name = _name(key, 'an environment variable name');
    final valueNode = envMap.nodes[name]!;
    final value = valueNode.value;
    if (value is! String) {
      // Deliberately not coerced. An environment variable is text, and YAML
      // has already decided what an unquoted `1.10` means before this code
      // sees it — the double 1.1, which prints back as "1.1" with a digit
      // gone. Refusing costs a pair of quotes; coercing costs a wrong value
      // that looks right.
      throw XtaskFormatException(
        '`$name` in `env:` of task `$taskName` is not a string — quote it. '
        'An environment variable is text, and YAML reads an unquoted `1.10` '
        'as the number 1.1, which is not what was written',
        valueNode.span,
      );
    }
    env[name] = value;
  }
  return env;
}

// ── shapes ──────────────────────────────────────────────────────────────────

YamlMap _asMap(YamlNode node, String what) {
  if (node is YamlMap) {
    return node;
  }
  throw XtaskFormatException('$what must be a mapping', node.span);
}

String _string(YamlNode node, String what) {
  final value = node.value;
  if (value is String) {
    return value;
  }
  throw XtaskFormatException('$what must be a string', node.span);
}

List<String> _stringList(YamlNode node, String what) {
  if (node is! YamlList) {
    throw XtaskFormatException('$what must be a list', node.span);
  }
  return [
    for (final item in node.nodes) _string(item, 'every entry of $what'),
  ];
}

/// [key] read as a name, refusing anything that is not one.
///
/// **Including the empty one, and here rather than at one caller.** The gate
/// list refused `"":` with a sentence about `--list` printing a heading with
/// nothing after it; tasks, sets and environment variables took the same key
/// and kept it. A file with an empty task name validated clean and printed a
/// blank name column, and nothing could name it in a `needs:` — the argument
/// the gate refusal makes, applying verbatim to three keys that did not make
/// it.
String _name(YamlNode key, String what) {
  final value = key.value;
  if (value is! String) {
    throw XtaskFormatException('$what must be a string', key.span);
  }
  if (value.isEmpty) {
    throw XtaskFormatException(
      'the file has $what that is empty. A name is what a report prints and '
      'what something else writes to reach it, and neither works with nothing '
      'there',
      key.span,
    );
  }
  if (value.contains('\n') || value.contains('\r')) {
    // **The same rule `desc:` is held to, on the other half of the same
    // line.** A description is refused for running past one line because
    // `--list` prints it beside the name; the name was not, so
    // `"a\nb": {…}` parsed. `--gate-members` writes one name per line and
    // `--list` pads a column with it, and a `::group::` is a workflow command
    // GitHub reads to the end of ITS line — so §7.1's fold opened on `a` and
    // the runner printed `b` as a stray line of output.
    throw XtaskFormatException(
      'the file has $what that runs to more than one line. A name is printed '
      'on one and typed on one — `--list` pads a column with it and a CI host '
      'reads a section marker to the end of the line — so it is one line by '
      'contract, exactly as the `desc:` beside it is',
      key.span,
    );
  }
  return value;
}

String? _optionalString(YamlMap map, String key, String taskName) {
  final node = map.nodes[key];
  if (node == null) {
    return null;
  }
  return _string(node, '`$key:` of task `$taskName`');
}

List<String> _optionalStringList(YamlMap map, String key, String taskName) {
  final node = map.nodes[key];
  if (node == null) {
    return const [];
  }
  return _stringList(node, '`$key:` of task `$taskName`');
}

// ── keys ────────────────────────────────────────────────────────────────────

/// The key nodes of [map], typed.
///
/// `YamlMap.nodes` is a `Map<dynamic, YamlNode>` whose keys are in fact
/// [YamlNode]s carrying their own spans — the static type loses that, and the
/// spans are what let an unknown key be reported at the line it was written
/// on rather than at the top of the file.
Iterable<YamlNode> _keyNodes(YamlMap map) =>
    map.nodes.keys.whereType<YamlNode>();

void _refuseUnknownKeys(YamlMap map, Set<String> known, String what) {
  for (final key in _keyNodes(map)) {
    final name = key.value;
    if (name is String && known.contains(name)) {
      continue;
    }
    throw XtaskFormatException(
      'unknown $what: `$name`. Known: ${(known.toList()..sort()).join(', ')}',
      key.span,
    );
  }
}
