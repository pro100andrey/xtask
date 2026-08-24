# Changelog

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
