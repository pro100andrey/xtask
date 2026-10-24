# xtask

A task runner whose tasks are **data**.

Write an `xtask.yaml`, and run `xtask <task>`. It resolves the dependency
graph, runs each task once, in declared order, **without a shell**.

That is the whole of it, and the repository does not have to be a Dart one:
the engine starts programs, so `[pytest, -q]` is as ordinary a task as
`[dart, test]`. Later you may want to pin the engine's version in a
`pubspec.yaml` instead of installing it, or to write a task in Dart rather than
name a program — [Using it from Dart](#using-it-from-dart) is those two steps,
and neither is needed to start.

The point is not convenience. It is that a repository stops keeping the same
list twice. A `Makefile` names the commands, the CI workflow names them again,
and a third copy usually lives in a contributing guide — and the copies drift
the first time somebody is in a hurry. Here CI stops naming commands at all: a
job runs one task, and what that task is made of lives in one file.

## Start here

Install the engine once. Your repository needs no `pubspec.yaml` and no Dart in
it at all — only the Dart SDK on the machine doing the installing:

```shell
dart install xtask
```

What lands on the PATH is a command called `xtask`.

Then write `xtask.yaml` at the repository root. This is a whole one:

```yaml
version: 1

gates: [check]

tasks:
  lint:
    desc: check the style
    gate: [check]
    run: [ruff, check, .]

  test:
    desc: run the suite
    gate: [check]
    run: [pytest, -q]

```

Those two are a Python repository's tools; put in whatever your own repository
already runs. Naming a program that is not installed is not a silent pass —
the run stops and says which one:

```log
error: task `lint`: `ruff` is not installed, or is not on PATH — nothing
runnable by that name in the 39 directories on PATH
```

And run it:

```shell
xtask check
```

That runs both, in the order they are written, and it is what a person types
before calling work done — and also the whole of the CI job, the same command,
because there is only one list and it is not in either of them. `xtask --list`
prints the tasks with their descriptions.

Two lines in that file are doing the work. `gates: [check]` at the top says
which groups this repository has; `gate: [check]` on a task says it is in one.
`xtask check` then runs the group, in the order the file writes it — a gate set
is not a task and needs none. [Gate sets](doc/ci-integration.md) says why the
whole tool exists for those two lines, and [The keys](doc/reference.md#the-keys)
is every key a task can have.

## Using it from Dart

Two steps, and a Dart repository is the only kind that can take them. Neither
is needed to start, and a repository that never takes either is using the tool
exactly as intended.

### Depending on it instead

A Dart repository can depend on `xtask` rather than installing it, and then the
version is written down in `pubspec.yaml` instead of being whatever that
machine happens to have. The command becomes:

```shell
dart run xtask:xtask <task>
```

### Your own entry point

The second, and the only thing here that needs Dart code, is a **verb**: a
function of your own for a job with real logic in it. An engine somebody else
shipped cannot contain your function, so you hand it over from a file of yours,
`bin/xtask.dart`, and run `dart run :xtask <task>`.
[Dart verbs](doc/dart-verbs.md) is that file, the verb, and how the installed
`xtask` hands a run to it.

## Guides

Each is one page, and each opens by saying who it is for:

- [Gate sets, and CI](doc/ci-integration.md) — the groups a person and a CI
  job run, and `--check-ci`, which keeps the workflow from growing its own
  list back.
- [Running, and reading a run](doc/running.md) — what a run will do before it
  does it (`--dry-run`, `--why`, `--graph`), the summary it ends with,
  `--keep-going`, `-j`, colour, and `--report` as JSON.
- [Reference](doc/reference.md) — every flag, every key, sets, the exit codes,
  and the schema for an editor.
- [Dart verbs](doc/dart-verbs.md) — your own entry point, a verb, how the
  installed `xtask` hands a run to it, and testing one.
- [Internals and platforms](doc/internals-and-platforms.md) — Ctrl-C and
  `SIGTERM`, what Windows changes, and where masking secrets stops.

## Coming from make

| a `Makefile` has | here it is |
| --- | --- |
| a target with a recipe | a task with `run:` — argv, one program per task |
| a recipe that branches, loops or pipes | a verb (`do:`) in `bin/xtask.dart` |
| prerequisites | `needs:` |
| `$(MAKE) next` at the end of a recipe | `then: [next]` |
| a phony target that only lists others | a gate set: `gates:` at the top, `gate:` on each task |
| `VAR=x` before a command | `env:` |
| `env -u VAR` before a command | `env-unset:` |
| a variable holding a file list | a set, named by `all:` or `each:` |
| `make help` | `xtask --list` |
| `make -j` | `xtask <task> -j <n>` |

Two things have no counterpart, on purpose: a file's timestamp deciding whether
a recipe runs (see [what it deliberately is not](#what-it-deliberately-is-not)),
and one target's output captured into another's command line (R1).

## Three rules

Not style. Each prevents a failure that has already happened somewhere.

**R1 — no control flow in the file.** No conditionals, no branching, no shell,
no capturing one command's output to feed another. A task that needs a condition
becomes a verb. The moment the file can ask "did that work?", it is a
programming language with no debugger and no types.

**R2 — no inheritance.** A task is read completely from its own keys. This costs
repetition and buys the property that what is written is what happens — and it
keeps the engine from growing precedence order and "where did this value come
from" tooling.

**R3 — a built-in primitive is total and argument-driven.** It takes paths or
values and performs an effect; it never branches on the result of anything.
`remove: [paths]` qualifies, `test -f X && Y` does not. This is what stops the
primitive list from becoming a portable shell — the failure the npm ecosystem
took, one package per utility (`rimraf`, `mkdirp`, `cross-env`, `shx`), all of
them existing only because `package.json` scripts are shell.

## What it deliberately is not

- **Not a build system.** No up-to-date checks, no artifact graph, no caching.
  An expensive task solves that inside its own verb.
- **Not a package manager and not a monorepo tool.** `melos` runs shell across
  packages; `xtask` runs a graph without one. They do not overlap.
- **Not parallel by default.** Tasks run in order, one at a time, and
  parallelism belongs to the CI system, which already has it. `-j` is
  there for the local loop and costs watching the output arrive.
- **No plugins, no dynamic loading, no expression language.** Verbs are code the
  project links; everything else is data.
- **No templating or interpolation** beyond `$each`. The moment a value can be
  computed in the file, R1 is gone.

## License

MIT — see [LICENSE](LICENSE).
