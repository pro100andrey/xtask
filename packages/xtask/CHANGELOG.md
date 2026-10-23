# Changelog

## Unreleased

### Added

- On a terminal the summary, the task headings and `--graph` are drawn in
  colour: `✓` green, `✗` and a failure's code red, `⊘` and `⏹` yellow,
  times and reasons faint, a heading bold. `NO_COLOR` (anything but empty)
  turns it off; `FORCE_COLOR` (anything but empty or `0`) turns it on in a
  pipe too, and `NO_COLOR` wins. A pipe or a file without `FORCE_COLOR` gets
  exactly the bytes it got before, and `--report`, `--names`,
  `--gate-members`, `--check-ci`, `--emit-schema` and the GitHub markers
  are never coloured. On a Windows console without ANSI support, the marks
  and tree glyphs are ASCII: `ok`/`FAIL`/`skip`/`stop`/`-`, `+-`, `` `- ``,
  `|`.

- `xtask --graph [<name>]` draws what a gate set or task pulls in, as a
  tree, without running or resolving anything: `needs` and `then` edges
  each under the task that names them, a task reached twice drawn once and
  then `(see above)`, an `each:` task with its member count and its first
  three members (all four where there are four), a set whose `produced-by:`
  task has not run as `cannot be resolved yet`, and a task for another OS
  as `⊘ linux only`. With no name, every gate set and then, under
  `ungated`, the tasks none of them reaches. A name a run refuses is
  refused with the run's sentence and `2`. Shells complete a gate set or
  task after it; `--check-ci` reads it as a question, as it reads `--why`.

- `findRoot(from)` and `gateMembers(gate, {workingDirectory})` are exported
  from `package:xtask/xtask.dart`, so a project's own entry point can ask
  where `xtask.yaml` is and what a gate set holds without starting a second
  engine. `gateMembers` answers exactly what `--gate-members` prints — the
  command now runs it — and throws `XtaskFormatException`, also exported now,
  with the message that command prints where it refuses: no file, a file that
  cannot be read or does not parse, a gate set that is not declared.

- `env-paths: {NAME: path}` on a task sets variables whose values are paths
  from the repository root: the body — a `run:` or a `do:` — gets the root
  joined to each, absolute, normalised and in the machine's separators,
  whatever `in:` says, and `--dry-run` prints that value. A path that is
  absolute or climbs through `..` is refused when the file is read; `$each`
  may end one, and a `values:` member that takes it out of the root is
  refused by `--validate` and the run. A name the same task's `env:` sets or
  `env-unset:` removes is refused, compared without case. A name in
  `secret-env:` is masked as the absolute path, and its value cannot be made
  from `$each`.

- `platforms: [linux|macos|windows]` on a task: on any other machine it does
  not run and is reported as skipped with the reason — `linux only` — in the
  summary, in `--report` (`skipped`, with that `why`) and in `--dry-run`,
  which does not resolve its body. What needs it, or follows it by `then:`,
  runs as though it had passed. Any other name, an empty list or a name
  written twice is refused when the file is read. `--check-ci` still counts
  such a task as reached.

- `secret-env: [NAMES]`, at the top level, prints the values of those
  variables as `***` in everything the engine writes: `--dry-run`'s argv and
  `env` lines, the line a failure reproduces itself with, `::error::`
  annotations, refusals that quote the command line, the hand-over's own
  messages and the `--report` file. The values are the run's — what the
  machine holds under each name and what any task's `env:` sets it to. On
  GitHub Actions a run or a dry run writes `::add-mask::` for each before its
  first line. A value shorter than four characters is not masked, and a
  secret's `env:` value made from `$each` is refused. What a body prints
  itself is not filtered.

- The installed `xtask` runs a project's verbs: in a repository whose root has
  a `bin/xtask.dart` of its own, it hands the run to it — `dart run
  <package>:xtask` from where you stand, or the file itself from a package
  that resolves its own — and answers with its exit code. Every form starts
  the run where you stand, so relative paths on the command line mean what
  you meant: a package never resolved has `dart pub get` run in it first,
  once, and is then run as a file. `--completion` is
  still answered by the engine, and so is `--names` while it can read the
  file; a task's own `xtask` hands over again; `XTASK_HAND_OVERS` stops a loop
  at eight; no `dart` on `PATH` is a `3`.

- `entry:` names the project's entry point, from the root, where it is not
  `bin/xtask.dart` — `tools/bin/xtask.dart` in a tools package of its own, or
  `tool/xtask.dart`. The installed `xtask` hands runs to it, from its own
  package (the nearest `pubspec.yaml`), getting that package a resolution
  first where it has none; `--validate` says when the file is missing or in
  no package, and `--check-ci` reads a step running it as `xtask`. An
  absolute path, `..`, `\` or a file that is not `.dart` is refused.

- `containing: [paths]` on a glob set keeps only the members that hold every
  one of those paths — `include: [packages/*]` with `containing: [test]` is
  the packages with a suite. Paths, not patterns, and nothing reads what a
  file says. A path that is absolute or climbs through `..` is refused, by
  `--validate` too; a set the filter leaves empty is refused as any empty set
  is, saying that the patterns matched and the filter took them.

- `unchanged: <set>` fails a task that changed the files a set of paths
  reaches, naming each file changed, added or removed. Compared byte for byte,
  not asked of git, so it answers the same in a dirty tree and outside a
  repository; a directory member is every file beneath it. The set is first
  read when the run begins — before every `needs:`, including one another
  branch of the graph reaches first — and again when the task ends. A missing
  set or a `values:` set is refused by `--validate`, `--dry-run` and the run,
  before the body starts; `--dry-run` says which set a task holds.

- `--report <file>` writes a run as JSON, `version: 1`: the task asked for,
  whether the run got to its end, its code and seconds, and every task of the
  plan in order — `passed`, `failed`, `skipped` or `not-run`, with its
  seconds, its code and why — and under an `each:` every member the same way.
  Written before anything else, as tasks begin and end, and last with the
  code: a run refused before it began says why, and one killed where it
  stands leaves the last report with `complete: false`. The path is read from where
  the command was run; one that cannot be written is a `2` before anything
  runs.

- `env-unset: [names]` takes variables away from a task's body — a `run:` and
  a `do:` alike, and everything a verb starts — so `dart test` need not see
  `CI` or `PUB_HOSTED_URL`. Removed, not emptied. On Windows a name is matched
  whatever its case, so `[Path]` removes `PATH`; a name the same task's
  `env:` sets is refused when the file is read, compared without case on
  every host. `--dry-run` prints each as `env  unset CI`.

- A run stopped by Ctrl-C or `SIGTERM` stops what it started instead of
  leaving it running: nothing more starts, every process the run started — a
  `run:` body, each member of an `each:` under `-j`, a program a verb started
  — is sent `SIGTERM` and, after a grace, `SIGKILL`, and the run answers `128`
  and the signal (`130`, `143`). A body ending on the Ctrl-C itself is
  reported as stopped, not failed. A `do:` verb is waited for; what it asks
  to start after the signal is answered `130` and not started. Its last
  `--report` is written with `complete: true` and the signal's code, and the
  task running says it was stopped. On Windows, Ctrl-C only.

### Changed

- The package lives in `packages/xtask` of a workspace repository, and
  `repository:` points there. The repository's own tasks run through an entry
  point at its root, which the installed `xtask` now hands runs to like any
  other project's.

- A run ends with one tree instead of two blocks — what each task took, then
  what failed and was skipped. Each task in plan order has one row: a mark
  for the result `--report` writes (`✓` passed, `✗` failed, `⊘` skipped, and
  for a task the run stopped `⏹` where it had begun and `·` where it had
  not), its time, and the exit code or the reason it did not run. The members
  of an `each:` are rows under their task where there are more than one, the
  total is last, and a lone failure has its row like any other task. A
  fanned-out task's `over N members` is printed when its members could run
  together, and `N of M members` wherever `--only` narrowed its set. `--report`,
  `--names`, `--gate-members` and the GitHub `::group::`/`::error::` lines are
  unchanged.

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
