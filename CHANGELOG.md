# Changelog

## Unreleased

Three failures that a committed file could reach with nothing said about it.

- **The repository boundary is one check, and it reads both notations.** A
  set's written members and a task's `in:` never met it at all, so
  `sets: {x: ['/etc']}` expanded to real paths and `in: ../..` ran a body two
  levels above the root. It also asked POSIX only, while every caller joins the
  answer with the platform's own `p.join`: on Windows `..\..`, `\foo` and
  `\\server\share` all walked through a gate written to stop them, the last
  one landing a recursive delete on a file server. `--validate` reports the
  `in:` case now, since the set half of the same fence was already reachable
  from there.
- **A body that cannot start, or that throws, is a task failure.**
  `Process.start` throws rather than answering when the working directory is
  not there, and nothing caught it: exit 255, a number the table does not have,
  with the task's `::group::` left open so the rest of a CI job folded into a
  task that had already died. Any other escaping exception — a project verb's
  own, or a fault in the engine — is now named by type with its trace inside
  the fold.
- **`**/` means the same thing everywhere.** `sets:` corrected
  `package:glob`'s reading of it to "none or more directories" and `do: remove`
  did not, so one pattern matched two different sets of paths depending on
  which key it was written under. The correction also missed a globstar that
  began a brace alternative, so `{**/*.dart,**/*.yaml}` silently examined every
  nested file and no root one.

  **Behaviour change in a verb that deletes:** `remove: ['**/build']` now also
  removes a root-level `build`, which it previously left alone.

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
