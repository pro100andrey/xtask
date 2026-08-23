import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'errors.dart';
import 'model.dart';

/// Reads `xtask.yaml` into the types of [XtaskFile] — §4 of `xtask.md`.
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
    sets: _sets(root),
    tasks: _tasks(root),
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
      'as best it can be (§4.1)',
      node.span,
    );
  }
  return value;
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
    const globKeys = {'include', 'exclude'};
    _refuseUnknownKeys(node, globKeys, 'key in glob set `$name`');
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
    'set `$name` must be a list of members, or a mapping with `include:` and '
    'optionally `exclude:`',
    keySpan,
  );
}

Map<String, Task> _tasks(YamlMap root) {
  final node = root.nodes['tasks'];
  if (node == null) {
    return const {};
  }

  final map = _asMap(node, '`tasks:`');
  // Insertion order is document order, and §4.3 leans on it: a `collects:`
  // composite runs its members in the order they appear, so that cheap gates
  // come before slow ones. A test pins this rather than trusting it — the
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

  return Task(
    name: name,
    span: keySpan,
    desc: _string(desc, '`desc:` of task `$name`'),
    body: _body(map, name),
    args: _optionalStringList(map, 'args', name),
    argvFrom: _optionalString(map, 'argv-from', name),
    each: _optionalString(map, 'each', name),
    workingDirectory: _optionalString(map, 'in', name),
    env: _env(map, name),
    envRequired: _optionalStringList(map, 'env-required', name),
    needs: _optionalStringList(map, 'needs', name),
    then: _optionalStringList(map, 'then', name),
    gate: _optionalStringList(map, 'gate', name),
    collects: _optionalString(map, 'collects', name),
  );
}

Body? _body(YamlMap map, String taskName) {
  final declared = bodyKeys.where(map.nodes.containsKey).toList();
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
    return DoBody(_string(node, '`do:` of task `$taskName`'));
  }

  final argv = _stringList(node, '`run:` of task `$taskName`');
  if (argv.isEmpty) {
    throw XtaskFormatException(
      '`run:` of task `$taskName` is empty — its first element is the '
      'executable, so there is nothing here to start',
      node.span,
    );
  }
  return RunBody(argv);
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
                  'it — which is what R2 is for'
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
        'rules, which R2 exists to keep out of this file',
      );
    }

    previous = c;
  }
}
