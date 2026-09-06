# Changelog

## 0.2.0

Written against 0.1.0: what a task file, a command line, a verb and a CI
workflow do differently. Changes made and unmade inside this version are not
here — a reader of 0.1.0 never saw them.

### Breaking

- **Gate sets are declared.** `gates: [check, release]` at the top of the file,
  names only; a task joins one with `gate: [check]`. `collects:` is gone, and
  with it the composite task that grouping used to need. Declaring the names is
  what makes a misspelled `gate:` a refusal rather than a new gate nobody runs.
- **`argv-from:` is `all:`,** and `$all` is written where its members belong in
  the argument list rather than appended to the end.
- **`--parallel` is `-j <n>`,** the spelling CI can actually write, with
  `-j auto` for the machine's processors capped at 8. The file says whether a
  task may be parallel; the flag says how many at once.
- **A path a task names stays inside the repository.** `in:`, a set's members
  and `do: remove`'s arguments are all refused if they are absolute or climb
  through `..`, in either platform's notation. A committed file that named
  `/etc` used to reach the filesystem.
- **A name is one line.** A task, gate, set or environment-variable name
  containing a line break is refused, as `desc:` already was.
- **`remove` lists a path once and in sorted order**, whether or not another of
  its arguments contains a glob character.

### Added to the file

- `values:` — a set that holds names rather than paths, so the boundary and the
  "expanded to nothing" rule are not asked of things that are not paths.
- `produced-by:` on a glob set — which task writes it, so a later task can
  name it, and so that `--validate` can ask that the later task `needs:` the
  earlier one.
- `$each` in a task's arguments, not only in its working directory, so per-file
  work can be written at all.
- `exclusive: [token]` — tasks holding the same token never run together, and
  neither do the members of one task's `each:`.
- `interruptible: true` — a task a failure elsewhere may stop where it stands.
- `serial: true` — a task whose `each:` members run one at a time.

### Added for a project's verbs

- `context.member` — which member of `each:` this invocation is for. A verb
  under `each:` used to run once per member with no way to tell which.
- `context.run(argv, workingDirectory:)` — a program started the way a `run:`
  body is, with §5.4's PATH walk, its `PATHEXT` rules, its refusal to hand
  `cmd.exe` a metacharacter through a batch shim, and its exit codes. "Make it
  a verb" was advice that could not be taken while a verb had to reach for
  `Process.start` and lose all of that. The directory is a path from the
  repository root and stays inside it.

### Fixed

- **A run answers a code the table has.** Seven paths could end the process at
  255 — an unreadable directory, a workflow that is not UTF-8, a byte that is
  not UTF-8 from a task, a pattern that will not compile, a `remove` that could
  not delete, a `needs:` chain deep enough to overflow the stack, and a body
  that threw anything at all.
- **A closed reader is an ordinary end.** `xtask check | head -1` and
  `xtask check >&-` both used to end the run — the first reporting a task
  failure having started nothing, the second at 255 from inside its own failure
  reporting. Neither stops a task now, and an ordering that cannot be delivered
  is not waited for.
- **A run's exit code does not depend on scheduling.** A plain failure answers
  for the run ahead of a `then:` continuation, and among failures of the same
  kind the plan's order decides rather than the order they finished in.
- **`--dry-run` resolves the plan rather than echoing it**: the argv each body
  will be handed, the directory it runs in, and for `do: remove` the paths it
  would delete — stopping where the run would stop instead of printing a plan
  below a step that will never be reached.
- **`--validate` accepts what the run accepts, and refuses what it refuses.**
  It checks `do: remove`'s arguments, substitutes a set's members before asking
  about a path, and no longer calls a task with only a `then:` an empty one.
- **Every contradiction in a task is one refusal.** `each:` without `$each`,
  `$all` inside a larger word, `all:` beside `each:`, a marker in `exclusive:`,
  a `timeout:` on a `do:` — a file with four of them cost four rounds of
  fix-and-rerun and now costs one.
- **`--check-ci` judges a step as written, and reads no shell.** The words
  after xtask are handed to the command line's own parser, so every spelling
  it accepts is one a workflow may use and every refusal is quoted in its own
  words; a mode is reported as a question rather than as a command. A script
  of more than one line, a `${{ … }}` expression, and a mention of xtask
  anywhere but in command position are each reported rather than guessed at,
  and a step's `if:` is printed beside the gate it runs. `xtask.exe` and
  `.\xtask` are recognised.
- **An exemption is answered.** `# xtask: not a gate — reason` on a step's
  `run:` line requires the reason, is reported when it excuses nothing, and
  does not silence a misspelled gate set or a command line the parser refuses.
- **A repository-relative program is read from where the body runs**, not from
  where the command was typed, and comes back in the separators the machine
  writes.
- **A set is read when its task is about to run**, so a task that produces
  files for a later one is not asked about them before it has written any.
- **A YAML alias and a merge key are refused**, because a task has to be
  readable from its own keys. Invisible whitespace where a line is indented is
  refused with the character named, rather than as a structure error several
  lines away.
- **A killed task does not leave the run hanging** on a grandchild that
  inherited its pipes, and a piped child's stdin is closed rather than left as
  a pipe nothing fills.

### Faster

Planning is no longer quadratic in a chain's length, a walk is pruned on the
include patterns as well as the exclusions, and a `remove` of several patterns
reads the tree once: 458ms to 188ms on four patterns, and about a seventh off
glob sets generally.

## 0.1.0

First release. Enough to replace one repository's `make`, and no more.

- `xtask.yaml` parsing with `--validate`, and errors that name the line rather
  than the file.
- The graph: `needs`, `then`, cycle detection with the cycle spelled out,
  run-once per invocation, declared order, and the five exit codes — `4`
  included, for a body that succeeded and a continuation that did not.
- Bodies: `run` as argv, `do` naming a verb the project registered, `args`,
  `argv-from`, `each`, `in`, `env`. Executable resolution honours `PATH`,
  `PATHEXT` and the fact that Windows cannot start a batch shim directly.
- `env-required`, checked before a body runs. The engine installs nothing.
- Sets: lists and globs with exclusions, expanded by the engine in a
  deterministic order. An expansion matching nothing is an error.
- Gate sets, the `collects:` derivation, `--list` and `--gate-members`, and
  log-grouping markers on a host that folds output.
- The `remove` primitive, which is the whole built-in list.
- `--dry-run`, printing what a run resolves to rather than what is written.
- `--emit-schema`, a JSON Schema for editors, generated from the same key lists
  the parser refuses unknown keys with.
- A mode that takes a name takes it either way — `--why build` and
  `--why=build` — because one flag taking both spellings and the rest taking
  one is a rule nobody can hold.
- `--why`, which names every entry point that reaches a task and spells the
  route edge by edge, saying whether each edge is a `needs:` or a `then:`.
- `--check-ci`, which reads the workflow files and reports a shell step that
  names a command instead of a gate set, and a gate set with no job to run it.
- `--keep-going`, and `--parallel`, which is the one place a promise is
  deliberately broken: output is collected per task and printed when that task
  ends, so the run says how wide it is and that the silence is expected.
- What each task took, printed after the last section rather than beside the
  task, because a line inside a fold is invisible to somebody who has expanded
  nothing.

Deliberately not here: `--emit-ci`, `--dry-run` output formats, a watch mode,
coloured output, shell completion. Each is a real convenience and each is a
place to hide a second list.
