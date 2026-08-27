import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'errors.dart';
import 'model.dart';

/// Reads `xtask.yaml` into the types of [XtaskFile].
///
/// Refuses anything that does not fit those types, at the line that did not
/// fit. It does **not** check that a name refers to something real, does not
/// look for cycles and does not touch the filesystem: those are `validate`,
/// `graph` and `sets`, and keeping them out of here is what stops this
/// function from quietly becoming the whole engine.
XtaskFile parseXtaskFile(String source, {Uri? sourceUrl}) {
  // Before the parser, because afterwards there is nothing left to see: by the
  // time an [XtaskFile] exists, `package:yaml` has already expanded every
  // alias into a copy and the evidence is gone. §8 specifies this as a scan of
  // the raw text for exactly that reason, and this is the only function that
  // ever holds the raw text.
  _refuseUnreadableSyntax(source, sourceUrl);

  final YamlNode document;
  try {
    document = loadYamlNode(source, sourceUrl: sourceUrl);
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
    if (name.isEmpty) {
      throw XtaskFormatException(
        'a gate set with no name. `--list` would print a heading with nothing '
        'after it, and nothing could name it in a `gate:`',
        item.span,
      );
    }
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
    timeout: _timeout(map, name, body),
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
    serial: _flag(map, 'serial', name),
    exclusive: _names(map, 'exclusive', name),
  );
  _checkAllMarker(name, task, keySpan);
  _checkEachMarker(name, task, keySpan);
  return task;
}

/// `\$all` as a word of its own, rather than the start of a longer name.
final _bareMarker = RegExp(r'\$all(?![A-Za-z0-9_])');

/// `$each` as a word of its own, rather than the start of a longer name.
final _bareEach = RegExp(r'\$each(?![A-Za-z0-9_])');

/// `each:` and its marker have to agree, and the marker has to END what it is
/// written in.
///
/// **The suffix is the line, and it is drawn once.** `$each` standing whole or
/// finishing a string is a value put where a value goes — `packages/$each`,
/// `--flavor=$each`. Text AFTER it is a derived path, `build/$each.dart`, and
/// that is where a substitution stops being a value and becomes a
/// computation. A computation wants a modifier, a modifier wants a language,
/// and R1 exists to say this file is not one. Deriving a path is a verb's job.
void _checkEachMarker(String name, Task task, SourceSpan keySpan) {
  final argv = switch (task.body) {
    RunBody(:final argv) => argv,
    _ => const <String>[],
  };

  if (argv.isNotEmpty && _bareEach.hasMatch(argv.first)) {
    throw XtaskFormatException(
      'task `$name` runs `${argv.first}`. The first entry of `run:` is the '
      'program, resolved on PATH before anything is substituted — a member '
      'does not name one',
      keySpan,
    );
  }

  final written = [
    ...argv.skip(1),
    ...task.args,
    ...task.env.values,
    ?task.workingDirectory,
  ];
  // **Every occurrence but a trailing one.** `endsWith` alone looked only at
  // the last, so `$each/$each` passed and the resolver — which substitutes the
  // trailing one — left the other in the argument as literal text.
  final badly = written.where(
    (word) =>
        _bareEach.hasMatch(word) &&
        (_bareEach.allMatches(word).length > 1 || !word.endsWith(eachMarker)),
  );
  if (badly.isNotEmpty) {
    throw XtaskFormatException(
      'task `$name` writes `${badly.first}`. `\$each` stands for one member '
      'and may end what it is written in, but nothing may follow it: '
      r'`packages/$each` is a path composed around a value, and '
      r'`$each.dart` is a path computed FROM one. Computing belongs in a '
      'verb, where this file cannot go',
      keySpan,
    );
  }

  final used = written.any((word) => word.endsWith(eachMarker));
  if (task.each != null && !used) {
    throw XtaskFormatException(
      'task `$name` has `each: ${task.each}` and never writes `\$each`, so '
      'the body runs once per member with no way to tell them apart',
      keySpan,
    );
  }
  if (task.each == null && used) {
    throw XtaskFormatException(
      'task `$name` writes `\$each` and has no `each:` to say which set its '
      'members come from',
      keySpan,
    );
  }

  // **The one pairing that is provably wrong.** `in: $each` says the member IS
  // the directory, so the member is a path from the repository root and the
  // body runs inside it; the same member in argv is then a path read from two
  // different places. A COMPOSED `in:` — `packages/$each` — says the opposite,
  // that the member is a name, and both halves are legitimate at once.
  if (task.workingDirectory == eachMarker &&
      [...argv.skip(1), ...task.args].any((w) => w.endsWith(eachMarker))) {
    throw XtaskFormatException(
      'task `$name` puts `\$each` in its arguments and also runs `in: '
      r'$each`. A member is a path from the repository root, and `in:` moves '
      'into it — the two would be relative to different places. Compose the '
      r'directory instead, `in: some/dir/$each`, so the member is a name',
      keySpan,
    );
  }
}

/// `all:` and its marker have to agree, and the marker has to be a whole
/// argument.
///
/// **Refused here rather than left to make a strange run.** A set named and
/// never used is a task that quietly does not check what its author thought;
/// a marker with no set is a program handed the literal text `$all`. Neither
/// fails — both succeed at the wrong thing, which is what §1 is about.
///
/// A marker inside a larger string is refused too, and that is the line R1
/// draws: `$all` stands for N arguments, and there is nothing for N arguments
/// to mean inside one. Splitting a string is a shell's job and this has no
/// shell.
void _checkAllMarker(String name, Task task, SourceSpan keySpan) {
  final argv = switch (task.body) {
    RunBody(:final argv) => argv,
    _ => const <String>[],
  };

  // **The program is not an argument.** `run:` names an executable first, and
  // §5.4 resolves it on PATH before anything is substituted — so `$all` there
  // is not a set expanded into position, it is a program by that name. It
  // counted as a marker here while the resolver substituted only over the
  // arguments, which let a file declare a set, satisfy every check below and
  // reach the command line with nothing: the run then answered 3, saying the
  // machine lacked a tool, about a file that was wrong.
  if (argv.isNotEmpty && _bareMarker.hasMatch(argv.first)) {
    throw XtaskFormatException(
      'task `$name` runs `${argv.first}`. `\$all` stands for arguments, and '
      'the first entry of `run:` is the program — there is nothing for a set '
      'to expand into there',
      keySpan,
    );
  }

  final oneThing = [?task.workingDirectory, ...task.env.values].where(
    _bareMarker.hasMatch,
  );
  if (oneThing.isNotEmpty) {
    final where = oneThing.first;
    // Neither refused nor substituted before, so the body ran in a directory
    // literally called `$all` and failed much later as "could not be started".
    throw XtaskFormatException(
      'task `$name` writes `\$all` in `$where`. It stands for every member of '
      'a set, and a directory and an environment value are each one thing — '
      'there is nothing for a list to be there',
      keySpan,
    );
  }

  final written = [...argv.skip(1), ...task.args];
  final markers = written.where((word) => word == allMarker).length;
  // A delimited token, so that `--allow=\$allowlist` — a literal argument for
  // a tool that does its own expansion — is text and not a mistake.
  final embedded = written.where(
    (word) => word != allMarker && _bareMarker.hasMatch(word),
  );

  if (embedded.isNotEmpty) {
    throw XtaskFormatException(
      'task `$name` writes `${embedded.first}`. `\$all` stands for every '
      'member of a set, so it is a whole argument or nothing — there is no '
      'meaning for several arguments inside one, and no shell here to split '
      'them',
      keySpan,
    );
  }
  if (task.all != null && markers == 0) {
    throw XtaskFormatException(
      'task `$name` has `all: ${task.all}` and never writes `\$all`, so the '
      r'set reaches nothing. Put `$all` where its members belong',
      keySpan,
    );
  }
  if (task.all == null && markers > 0) {
    throw XtaskFormatException(
      'task `$name` writes `\$all` and has no `all:` to say which set it '
      'stands for',
      keySpan,
    );
  }
  if (markers > 1) {
    throw XtaskFormatException(
      'task `$name` writes `\$all` $markers times. One set expanded twice into '
      'one command line is two answers to what the task is about',
      keySpan,
    );
  }
  if (task.all != null && task.each != null) {
    // The combination that used to be legal and meant nothing anybody wanted:
    // every member of the `each:` set received the WHOLE `all:` set.
    throw XtaskFormatException(
      'task `$name` has both `each:` and `all:`. One runs the body once per '
      'member and the other runs it once for all of them; a task is one or '
      'the other',
      keySpan,
    );
  }
}

/// A boolean key, refused rather than coerced.
///
/// `serial: yes` is a string in YAML 1.2 and would be truthy in a language
/// that guessed. This file does not guess.
bool _flag(YamlMap map, String key, String taskName) {
  final node = map.nodes[key];
  if (node == null) {
    return false;
  }
  final value = node.value;
  if (value is bool) {
    return value;
  }
  throw XtaskFormatException(
    '`$key:` of task `$taskName` is `$value`, and it is a yes or no — write '
    '`true` or `false`',
    node.span,
  );
}

/// `timeout:` in seconds, refused where it cannot be honoured.
///
/// **A `run:` body only, and refused rather than half-applied on a verb.** A
/// verb is a Dart function, and Dart cannot stop one from outside: a deadline
/// would report a timeout while the verb carried on writing to the disk. A
/// verb that wants a deadline is the place to implement one — R1 put the logic
/// there deliberately.
int? _timeout(YamlMap map, String taskName, Body? body) {
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
  if (body is DoBody) {
    throw XtaskFormatException(
      'task `$taskName` puts a `timeout:` on a `do:`, and the engine cannot '
      'honour it: a verb is a Dart function and nothing outside it can stop '
      'one, so the limit would pass while the verb kept running. Put the '
      'deadline inside the verb, which is where logic belongs',
      node.span,
    );
  }
  if (body == null) {
    throw XtaskFormatException(
      'task `$taskName` has a `timeout:` and no body to spend it, so there is '
      'nothing for the limit to be a limit on',
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

String _name(YamlNode key, String what) {
  final value = key.value;
  if (value is String) {
    return value;
  }
  throw XtaskFormatException('$what must be a string', key.span);
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

// ── the scan §8 asks for, before the parser ─────────────────────────────────

/// Characters that look like a space and are not one.
///
/// The motivating case is a non-breaking space pasted from a document, used as
/// indentation. YAML's own answer to it is a parse error about structure,
/// several lines away from the invisible character that caused it, which is
/// the "useless message" §8's last bullet is written against.
const _invisibleSpace = {
  0x00A0, // no-break space
  0x1680, // ogham space mark
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, // en/em quad and friends
  0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x200B, // thin, hair, zero-width
  0x2028, 0x2029, // line and paragraph separator
  0x202F, // narrow no-break space
  0x205F, // medium mathematical space
  0x3000, // ideographic space
  0xFEFF, // zero-width no-break space, i.e. a stray byte-order mark
};

/// Where a YAML node begins, and therefore where `&` and `*` are indicators
/// rather than ordinary characters.
// \n : - [ { ,
const _nodeStart = <int?>{null, 0x0A, 0x3A, 0x2D, 0x5B, 0x7B, 0x2C};

/// Refuses the syntax §8 names, reading [source] as text.
///
/// Two rules, and both are about a reader being able to trust a task:
///
/// **No anchors, aliases or merge keys.** `sets:` already exists to say a thing
/// once, so an anchor is a second mechanism for the same purpose — and in this
/// design two ways to say one thing have drifted everywhere they were allowed.
/// It also defeats R2 in practice if not in letter: the reader of a task that
/// says `*base` has to leave it and go find the declaration, which is the
/// property R2 was written to protect.
///
/// **No invisible whitespace.** See [_invisibleSpace].
///
/// The scan is exact rather than approximate. YAML treats `&` and `*` as
/// indicators only where a node begins, so `packages/*/coverage` is an
/// ordinary scalar and passes untouched — while `include: [**/x]` does not,
/// and should not: YAML would read that as an alias too, which is why the
/// examples in §12 quote their patterns.
void _refuseUnreadableSyntax(String source, Uri? sourceUrl) {
  final file = SourceFile.fromString(source, url: sourceUrl);
  Never refuse(int offset, String message) =>
      throw XtaskFormatException(message, file.location(offset).pointSpan());

  var inSingle = false;
  var inDouble = false;
  var inComment = false;
  int? previous; // last significant character outside quotes and comments

  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);

    if (_invisibleSpace.contains(c) && !inSingle && !inDouble) {
      refuse(
        i,
        'this is U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}, not a '
        'space — it was almost certainly pasted from a document. YAML would '
        'have complained about the structure several lines from here instead',
      );
    }
    if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) {
      refuse(i, 'a non-printable character has no meaning in this file');
    }

    if (inComment) {
      if (c == 0x0A) {
        inComment = false;
        previous = 0x0A;
      }
      continue;
    }
    if (inSingle) {
      if (c == 0x27) {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (c == 0x5C) {
        i++;
      } else if (c == 0x22) {
        inDouble = false;
      }
      continue;
    }

    switch (c) {
      case 0x23: // #
        inComment = true;
        continue;
      case 0x27: // '
        inSingle = true;
        previous = c;
        continue;
      case 0x22: // "
        inDouble = true;
        previous = c;
        continue;
      case 0x20:
      case 0x09:
      case 0x0D:
        continue;
      case 0x0A:
        previous = 0x0A;
        continue;
    }

    if ((c == 0x26 || c == 0x2A) && _nodeStart.contains(previous)) {
      final anchor = c == 0x26;
      refuse(
        i,
        anchor
            ? 'a YAML anchor (`&`) is refused. `sets:` already exists to say a '
                  'thing once, and a task has to be readable without leaving '
                  'it: what it does is read from its own keys, and an anchor '
                  'makes that untrue'
            : 'a YAML alias (`*`) is refused, for the reason an anchor is. If '
                  'this was meant as a glob, quote it: YAML reads a value '
                  'beginning with `*` as an alias, whatever you meant',
      );
    }
    final mergeKey =
        c == 0x3C && i + 1 < source.length && source.codeUnitAt(i + 1) == 0x3C;
    if (mergeKey) {
      refuse(
        i,
        'the YAML merge key `<<` is refused. It is inheritance with precedence '
        'rules, and a task is meant to be read completely from its own keys',
      );
    }

    previous = c;
  }
}
