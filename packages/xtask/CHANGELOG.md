# Changelog

## Unreleased

### Changed

- `--list` marks a task whose `platforms:` leave this machine out
  `⊘ linux only`, as the summary and `--graph` do, so the list read before a
  run says what it will skip here.

## 0.5.0

### Added

- The installed `xtask` runs a project's verbs: in a repository with an entry
  point of its own, it hands the run to it and answers with its exit code. The
  run starts where you stand, a package never resolved gets `dart pub get`
  first — which Ctrl-C or `SIGTERM` stops, answering `130` or `143` — and
  `XTASK_HAND_OVERS` stops a loop at eight.
  [Your own entry point](doc/dart-verbs.md#your-own-entry-point).
- `entry:` names that entry point where it is not `bin/xtask.dart` — a tools
  package's `tools/bin/xtask.dart`, say. `--validate` says when the file is
  missing, and `--check-ci` reads a step running it as `xtask`.
- `--graph [<name>]` draws what a gate set or task pulls in, as a tree, without
  running anything; with no name, every gate set and then what none reaches.
- `--report <file>` writes the run as JSON, `version: 1`, as it goes: each
  task's result, seconds, code and why, and `complete: false` where the run was
  killed. [A run as JSON](doc/running.md#a-run-as-json).
- `unchanged: <set>` fails a task that changed the files a set reaches, naming
  each — compared byte for byte, not asked of git.
  [`unchanged`](doc/reference.md#unchanged).
- `containing: [paths]` on a glob set keeps the members that hold every path:
  `include: [packages/*]` with `containing: [test]` is the packages with a
  suite. [`containing`](doc/reference.md#containing).
- `platforms: [linux|macos|windows]`: on another machine the task is skipped,
  `linux only`, and what needs it runs as though it had passed.
  [`platforms`](doc/reference.md#platforms).
- `secret-env: [NAMES]` prints those variables' values as `***` in everything
  the engine writes, and on GitHub Actions hands each to `::add-mask::`. What a
  body prints itself is not filtered.
  [Secrets](doc/internals-and-platforms.md#secrets).
- `env-unset: [names]` takes variables away from a task's body, and
  `env-paths: {NAME: path}` sets them to paths from the root, absolute and in
  the machine's separators. [`env-unset`](doc/reference.md#env-unset),
  [`env-paths`](doc/reference.md#env-paths).
- On a terminal the summary, the task headings and `--graph` are coloured, by
  `TERM`, `NO_COLOR` and `FORCE_COLOR`; a pipe gets the bytes it got before. A
  Windows console without ANSI gets ASCII marks.
  [Colour, and ASCII](doc/running.md#colour-and-ascii).
- For an entry point: `findRoot` and `gateMembers`, which answer where
  `xtask.yaml` is and what a gate set holds without a second engine, and
  `XtaskFormatException`, which they throw where `--gate-members` refuses.

### Changed

- A run ends with one tree instead of two blocks: a row per task with its mark
  (`✓` `✗` `⊘` `⏹` `·`), its time and its code or reason, an `each:` task's
  members under it. `--report`, `--names`, `--gate-members` and the GitHub
  markers are unchanged.
- The package lives in `packages/xtask` of a workspace repository, and
  `repository:` points there.

### Fixed

- Ctrl-C or `SIGTERM` no longer leaves what the run started running: each
  process is sent `SIGTERM` and, after a grace, `SIGKILL`, and the run answers
  `130` or `143`. On Windows, Ctrl-C only.
  [Ctrl-C, and SIGTERM](doc/internals-and-platforms.md#ctrl-c-and-sigterm).

## 0.4.0

### Added

- `--only <set>=<pattern>,…` narrows a set for one run: every `each:` and
  `all:` in the plan that names it gets only the members a pattern matches,
  and `--dry-run` takes it too. A set the file has not got, a set nothing in
  the plan expands, and a pattern matching no member are each a `2`. The
  summary says `over 2 of 17 members`, and `--check-ci` reports a step that
  runs a gate set narrowed.
- `alone: true`: under `-j` the run waits for what it has started, runs the
  task, and starts nothing else until it has ended. `--validate` refuses it
  beside `exclusive:`, `serial:` or `interruptible:`, and on a task with no
  body.
- For verbs: `context.tee(argv, workingDirectory:, timeout:)`, which is
  `capture` with the output shown as it arrives. A hand-built `VerbContext`
  gives it through `relay:`.
- For verbs: `context.file(path)` and `context.directory(path)`, a path from
  the repository root written with `/`, ending the task with `2` when it
  climbs out of the root or leads out through a link.
- `--completion bash|zsh|fish` prints a completion script, which reads task,
  gate set and set names from `--names` when TAB is pressed.
- A name that is not a task is answered with the near ones — ``did you mean
  `check`?`` — or with `xtask --list`.

### Fixed

- An argument holding `%` is refused for a batch file, as `&` and `^` are:
  `cmd.exe` expands `%VAR%` on the command line before the file sees it.
- `context.out` hands on a line written with `\r\n` without its `\r`.

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
