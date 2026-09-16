# Changelog

## 0.2.0

Written against 0.1.0: what a task file, a command line, a verb and a CI
workflow do differently.

### Breaking

- `gates: [check, release]` declares the gate sets; a task joins one with
  `gate: [check]`. `collects:` is gone, and a misspelled `gate:` is refused.
- `argv-from:` is `all:`, and `$all` goes where its members belong in the
  argument list rather than at the end.
- `--parallel` is `-j <n>`, with `-j auto` for the machine's processors capped
  at 8.
- A path a task names — `in:`, a set's member, a `remove` argument — is refused
  if absolute or climbing through `..`.
- A task, gate, set or environment-variable name containing a line break is
  refused.
- `remove` lists a path once and in sorted order.

### Added

- `values:` — a set of names rather than paths.
- `produced-by:` on a glob set, so `--validate` can ask that a task naming it
  `needs:` the producer.
- `$each` in a task's arguments; `exclusive: [token]`; `interruptible: true`;
  `serial: true`.
- For verbs: `context.member`, and `context.run(argv, workingDirectory:)`,
  which starts a program the way a `run:` body does.

### Fixed

- Seven paths ended the process at 255 instead of a code the table has.
- `do: remove` refuses an argument naming its own directory (`''`, `.`, `./`
  deleted it whole), and deletes from where its task runs rather than the root.
- `x needs y`, `y then z`, `z needs x` was refused as a cycle.
- `--check-ci` asks whether a job enforces the gate set: a step under another
  `xtask.yaml` or under `continue-on-error: true` no longer counts. A step is
  judged by the command line's own parser rather than by guessing at a shell;
  a multi-line script, a `${{ … }}` expression and xtask outside command
  position are reported. `# xtask: not a gate — reason` requires the reason
  and excuses only what it names. `xtask.exe` and `.\xtask` are recognised.
- A brace alternative with nothing in it (`{lib,}`) is refused rather than
  crashing at match time.
- A closed stdout (`| head -1`, `>&-`) no longer ends the run.
- The exit code does not depend on scheduling: a plain failure answers ahead
  of a `then:` continuation, and the plan's order decides among failures.
- `--dry-run` prints the resolved argv, directory and `remove` paths, and stops
  where the run would. `--validate` refuses exactly what the run refuses.
- Every contradiction in a task is reported in one refusal.
- A repository-relative program is read from where the body runs.
- A set is read when its task is about to run, not at planning.
- A YAML alias, a merge key, and invisible whitespace in an indent are refused.
- A killed task does not leave the run hanging on a grandchild.

### Faster

Planning is no longer quadratic in a chain's length, a walk is pruned on the
include patterns, and a `remove` of several patterns reads the tree once.

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
