/// The JSON Schema an editor reads — `--emit-schema` of §7.
///
/// **What this is for.** `--validate` answers when it is called; a schema
/// answers while somebody types. An editor with this loaded completes the keys
/// of a task, underlines `dsec:` and underlines `gate: check` where a list
/// belongs, before anything is run. What it cannot do is anything needing the
/// graph or the filesystem — a cycle, a `needs:` pointing at nothing, an
/// orphan gate, a glob matching nothing, an unregistered verb. Those stay with
/// §8 and do not move. A schema catches a mistyped KEY; `--validate` catches a
/// mistyped NAME.
///
/// **It is a projection of `model.dart`, checked against it.** The names of
/// the keys are not written here — they are read from [taskKeys],
/// [topLevelKeys], [globSetKeys], [valueSetKeys] and [bodyKeys], which §4
/// makes the only list of them. The two set tables were named in this sentence
/// and never actually read: they went out unguarded, and the emitted order
/// proved it — `include, produced, exclude`, which is this file's table order
/// rather than the model's.
///
/// What IS written here is one shape and one sentence per key, and
/// [checkedProperties] refuses to emit anything if that table has drifted
/// from the set it describes. So there are not two lists: there is one list,
/// and a projection that cannot survive disagreeing with it.
library;

import 'dart:convert';

import 'model.dart';

/// The schema for this engine's file format, as text, ending in a newline.
///
/// Printed by `xtask --emit-schema`, and meant to be redirected:
///
/// ```
/// dart run :xtask --emit-schema > xtask.schema.json
/// ```
///
/// **That redirect is a person's shell, and it has to be.** A task cannot do
/// it: `>` is shell, and §5.2 says a task's description contains none. So the
/// generated file is committed and a gate compares it against this — writing
/// is somebody's deliberate act, checking is the gate's.
String xtaskJsonSchema() =>
    '${const JsonEncoder.withIndent('  ').convert(_document)}\n';

/// Draft 07, because it is what the editors that read this actually implement.
const _draft = 'http://json-schema.org/draft-07/schema#';

Map<String, Object?> get _document => {
  r'$schema': _draft,
  'title': 'xtask.yaml',
  'description':
      'A task runner whose tasks are data. This schema describes the SHAPE of '
      'the file. Whether it is coherent — no cycle, no name pointing at '
      'nothing, no set matching nothing — is what `xtask --validate` answers, '
      'and it is not answerable here.',
  'type': 'object',
  'additionalProperties': false,
  // `version:` alone. The parser accepts a file with no `tasks:` and no
  // `sets:`, and a schema stricter than the engine underlines a file that
  // runs.
  'required': ['version'],
  'properties': checkedProperties(topLevelKeys, _topLevel, 'top-level key'),
};

/// The top level, §4.1.
Map<String, Map<String, Object?>> get _topLevel => {
  'version': {
    'type': 'integer',
    // From the engine's own constant. An unknown version is a hard refusal,
    // never a best-effort read, so the schema says the same thing.
    'const': supportedVersion,
    'description':
        'Required. The only version this engine reads; an unknown one is '
        'refused rather than read as best it can.',
  },
  'gates': {
    'type': 'array',
    'items': {'type': 'string', 'minLength': 1},
    'minItems': 1,
    'uniqueItems': true,
    'description':
        'Every gate set this file has, in the order a report groups by. Names '
        'only — a gate set is not a task and has nothing to describe. '
        'A gate set is run by being named — `xtask check`. Declaring them '
        'is what makes a misspelled `gate:` a refusal rather than a new gate '
        'set nobody runs.',
  },
  'sets': {
    'type': 'object',
    'description':
        "Named lists and globs, referenced by a task's `each:` or `all:`. A "
        'set that expands to nothing is an error: a task given no files '
        'checked nothing.',
    'additionalProperties': _set,
  },
  'tasks': {
    'type': 'object',
    'description':
        'The graph. Declaration order is meaningful: a gate set runs its tasks '
        'in the order they appear here.',
    'additionalProperties': _task,
  },
};

/// A named set, §4.2: a list of paths, a glob with exclusions, or values
/// that are not paths at all.
Map<String, Object?> get _set => {
  'oneOf': [
    {
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 1,
      'description': 'The members, written out.',
    },
    {
      'type': 'object',
      'additionalProperties': false,
      'required': ['include'],
      'properties': checkedProperties(globSetKeys, _globSet, 'glob set key'),
      'description':
          'Globs, expanded by the engine rather than by a shell, in a '
          'deterministic order.',
    },
    {
      'type': 'object',
      'additionalProperties': false,
      'required': ['values'],
      'properties': checkedProperties(valueSetKeys, _valueSet, 'value set key'),
      'description':
          'Members that are not paths — flavours, platforms, SDK versions. '
          'Not checked against the repository root and never matched on disk.',
    },
  ],
};

const _valueSet = <String, Map<String, Object?>>{
  'values': {
    'type': 'array',
    'items': {'type': 'string'},
    'minItems': 1,
    'description':
        'The members, written out. Whatever they name, it is not a path.',
  },
};

const _globSet = <String, Map<String, Object?>>{
  'include': {
    'type': 'array',
    'items': {'type': 'string'},
    'minItems': 1,
    'description':
        'Patterns, relative to the repository root. `**/` means NONE or more '
        'directories, as bash and git read it — so `packages/**/x` finds '
        '`packages/x` too.',
  },
  'produced': {
    'type': 'boolean',
    'description':
        "Whether this set's members are made by the run itself. A set is "
        'read when the task naming it is about to run, so `--validate` and '
        '`--dry-run` see a different moment; this says so, and buys exactly '
        'one thing — the emptiness of this set is not judged before then. '
        'Everything else about it still is, and a run still refuses it empty.',
  },
  'exclude': {
    'type': 'array',
    'items': {'type': 'string'},
    'description': 'Patterns removed from what `include:` matched.',
  },
};

/// A task, §4.3.
Map<String, Object?> get _task => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['desc'],
  // Both body keys present is refused by the parser, so the schema refuses it
  // too — spelled from [bodyKeys] rather than from a repetition of them.
  'not': {
    'required': bodyKeys.toList(),
    r'$comment': 'a task has one body or none, never two',
  },
  'properties': checkedProperties(taskKeys, _taskKeys, 'task key'),
};

const _strings = <String, Object?>{
  'type': 'array',
  'items': {'type': 'string'},
};

// **Alphabetical, and that is not cosmetic.** This table must not be what
// decides the order of the emitted file: `checkedProperties` imposes the
// engine's own order, and writing this one in the engine's order too would
// make the test that says so pass whether it did or not.
const _taskKeys = <String, Map<String, Object?>>{
  'all': {
    'type': 'string',
    'description':
        r'A set whose members replace the `$all` marker in `run:` or `args:`, '
        'in one invocation. The marker is a whole argument and appears once.',
  },
  'args': {
    ..._strings,
    'description': 'Extra arguments appended to the body.',
  },
  'desc': {
    'type': 'string',
    'minLength': 1,
    'description':
        'Required, one line, and what `--list` prints — so that a task cannot '
        'be added without saying what it is for.',
  },
  'do': {
    'type': 'string',
    'minLength': 1,
    'description':
        'A verb: `remove`, or one this project registered in its own '
        '`bin/xtask.dart`. The engine ships no project verbs.',
  },
  'each': {
    'type': 'string',
    'description':
        'A set whose members the body runs once per, with '
        r'`$each` standing for the member — a whole argument, or the end of '
        r'one: `packages/$each`. Nothing may follow it. A failure names the '
        'member; without `--keep-going` no further member is STARTED, so at '
        '`-j 1` it stops the rest and above that it stops what had not begun.',
  },
  'env': {
    'type': 'object',
    'additionalProperties': {'type': 'string'},
    'description':
        'Environment for this task only. A key rather than syntax, because '
        '`FOO=bar cmd` is shell on POSIX and something else on Windows.',
  },
  'env-required': {
    ..._strings,
    'description':
        'Variables that must already be set. Checked before the body runs; '
        'the engine installs nothing, it only says which one is missing.',
  },
  'exclusive': {
    ..._strings,
    'description':
        'Tokens this task holds alone while it runs. Two tasks the graph '
        'calls independent may still share a port or a browser; naming what '
        'they share is what keeps them apart.',
  },
  'gate': {
    ..._strings,
    'description':
        'The gate sets this task belongs to. A gate set is named after who '
        "runs it: one person's command, or one CI job's.",
  },
  'in': {
    'type': 'string',
    'description':
        'Where the body runs, relative to the repository root. May end with '
        r'`$each`, which stands for the current member of `each:` — as the '
        r'whole value, or composed: `packages/$each`.',
  },
  'interruptible': {
    'type': 'boolean',
    'description':
        'Whether a failure elsewhere may stop this task where it stands. A '
        'run does not reach into what is already running, because a build '
        'killed half-way leaves whatever it was doing in whatever state that '
        'half is — this is the author saying a read-only check leaves '
        'nothing. A `do:` cannot carry it: stopping a Dart function from '
        'outside is not something Dart can do.',
  },
  'needs': {
    ..._strings,
    'description':
        'Direct requirements, run before this task. Each runs once per '
        'invocation however many tasks need it.',
  },
  'run': {
    'type': 'array',
    'items': {'type': 'string'},
    'minItems': 1,
    'description':
        'An external program as argv: the program, then its arguments, each '
        'its own entry. Never a command line — nothing splits a string here, '
        'and no shell sees it.',
  },
  'serial': {
    'type': 'boolean',
    'description':
        "Whether this task's `each:` members must not overlap. `-j` says how "
        'much may happen at once; this says whether these particular members '
        'may happen together at all — one shared `pub` cache, one git index. '
        'Getting it wrong makes a run flaky rather than slow, which is why it '
        'is in the file and the number is not.',
  },
  'then': {
    ..._strings,
    'description':
        "Continuations, run after this task's body rather than before it. A "
        'body that succeeded and a continuation that failed is its own '
        'outcome, with its own exit code.',
  },
  'timeout': {
    'type': 'integer',
    'minimum': 1,
    'description':
        'Seconds a `run:` body may take before it is killed. A `do:` cannot '
        'carry one: a verb is a Dart function and nothing outside it can stop '
        'one, so the limit would pass while the verb kept running. Under '
        '`each:` it is a limit per member.',
  },
};

/// [table] as JSON Schema properties, in [keys]' order, or nothing at all.
///
/// Public so that the refusal itself can be tested. Reached only through a
/// drift that must never be committed, it is otherwise code that runs the day
/// it is needed and has never run before.
///
/// **The whole guard, in one function.** [keys] is the engine's list; [table]
/// is this file's description of it. A key added to one and forgotten in the
/// other is the drift §1 exists to remove, and the failure it would cause is
/// quiet in the worst way — an editor happily completing a key the parser
/// refuses, or underlining one it accepts. So the disagreement stops
/// `--emit-schema` rather than reaching a file, and the message names both
/// sides.
Map<String, Map<String, Object?>> checkedProperties(
  Set<String> keys,
  Map<String, Map<String, Object?>> table,
  String what,
) {
  final described = table.keys.toSet();
  final missing = keys.difference(described);
  final extra = described.difference(keys);
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw StateError(
      'the JSON Schema has drifted from the engine it describes: '
      '${missing.isEmpty ? '' : 'no $what ${missing.join(', ')} is described '
                'in lib/src/schema.dart'}'
      '${missing.isEmpty || extra.isEmpty ? '' : '; and '}'
      '${extra.isEmpty ? '' : 'lib/src/schema.dart describes '
                '${extra.join(', ')}, which is not a $what'}',
    );
  }
  // **Ordered by [keys], not by the table.** The tables below are written in
  // alphabetical order on purpose, which is NOT the order the engine declares
  // its keys in — so if this line ever stopped imposing an order, the emitted
  // file would change and a test would say so. A table written in the model's
  // order would make that test pass whatever this line did.
  return {for (final key in keys) key: table[key]!};
}
