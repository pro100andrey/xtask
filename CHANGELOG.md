# Changelog

## 0.3.0

### Breaking

- `VerbContext` requires `root:` and is no longer `const`. Only code that
  builds a context itself — a verb's tests — is affected.
- `ExitCode.continuationNotice` is replaced by the top-level
  `continuationNotice(body:, continuation:)`.

### Added

- `--check-schema <path>` answers 2 when a committed schema is not the one
  this engine emits.
- `--check-ci` names the tasks in a gate set that no job reaches.
- For verbs: `context.root`; `context.capture(argv, workingDirectory:,
  timeout:)`, which starts a program as `context.run` does and returns its
  exit code and output; `context.which(name, workingDirectory:)`; and
  `context.out`, a `StringSink` over `log`.

### Changed

- A failed `then:` names the task that finished and the continuation that
  failed, instead of always saying "the upload took place".

### Fixed

- `--check-ci` reads `defaults: run: working-directory:` on the job and the
  workflow. It reports a `${{ … }}` working directory instead of reading it
  as the root, and a `${{ … }}` `continue-on-error:` instead of reading it as
  false.
- A blank name (`"  "`) is refused like an empty one.
- The schema refuses what the parser refuses: `all:` with `each:`,
  `timeout:` or `interruptible: true` without `run:`, a blank entry in
  `needs:`, `then:`, `gate:` or `exclusive:`, and a blank `do:`.
- The README described `context.workingDirectory` as the repository root.
  It is where the task runs; a set's members are relative to `context.root`.

## 0.2.0

### Breaking

- Gate sets are declared with `gates: [...]` and joined with `gate: [...]`.
  `collects:` is gone.
- `argv-from:` is `all:`, and `$all` goes where it is written.
- `--parallel` is `-j <n>`; `-j auto` is the processor count, at most 8.
- An absolute path, or one through `..`, is refused in `in:`, a set member
  and a `remove` argument.
- A name containing a line break is refused.
- `remove` lists each path once, sorted.

### Added

- `values:` sets, `produced-by:` on glob sets, `$each` in arguments,
  `exclusive:`, `interruptible:` and `serial:`.
- For verbs: `context.member` and `context.run(argv, workingDirectory:)`.

### Fixed

- Seven paths that ended the process at 255 answer a documented code.
- `do: remove` refuses its own directory (`''`, `.`, `./`) and deletes
  relative to where the task runs, not the root.
- `x needs y`, `y then z`, `z needs x` is no longer refused as a cycle.
- `--check-ci` reads a step with the command line's own parser instead of
  guessing at shell. A step under another `xtask.yaml` or with
  `continue-on-error: true` does not count; a multi-line script, a `${{ … }}`
  expression and xtask outside command position are reported; the
  `# xtask: not a gate — reason` marker requires the reason; `xtask.exe` and
  `.\xtask` are recognised.
- `{lib,}` is refused instead of crashing at match time.
- A closed stdout (`| head -1`) no longer ends the run.
- The exit code no longer depends on scheduling.
- `--dry-run` prints the resolved argv, directory and `remove` paths.
  `--validate` refuses everything a run would.
- Every contradiction in a task is reported in one refusal.
- A repository-relative program is resolved from where the body runs.
- A set is read when its task is about to run, not at planning.
- YAML aliases, merge keys and invisible whitespace in an indent are refused.
- A killed task no longer leaves the run waiting on a grandchild.

### Performance

- Planning is linear in a chain's length, a glob prunes the walk, and a
  `remove` of several patterns reads the tree once.

## 0.1.0

First release.

- `xtask.yaml` and `--validate`, with errors that name the line.
- The graph: `needs`, `then`, cycle detection, run-once, declared order, and
  five exit codes.
- Bodies: `run` as argv, `do` for a verb the project registers, `args`,
  `argv-from`, `each`, `in`, `env`. Executables are resolved through `PATH`
  and `PATHEXT`, and Windows batch shims are handled.
- `env-required`, checked before a body runs.
- Sets: lists and globs with exclusions, in a deterministic order. A set that
  expands to nothing is an error.
- Gate sets through `collects:`, `--list`, `--gate-members`, and folded log
  sections on a host that supports them.
- The built-in `remove` verb.
- `--dry-run`, `--emit-schema`, `--why`, `--check-ci`, `--keep-going` and
  `--parallel`.
- Per-task timings, printed after the last section.
