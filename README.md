# xtask

A task runner whose tasks are **data**.

A project depends on `xtask`, writes an `xtask.yaml` describing its tasks, and
writes one small entry point handing the engine its own **verbs** — Dart
functions for the jobs that need real logic. `xtask <task>` resolves the
dependency graph, runs each task once, in declared order, **without a shell**.

The point is not convenience. It is that a repository stops keeping the same
list twice. A `Makefile` names the commands, the CI workflow names them again,
and a third copy usually lives in a contributing guide — and the copies drift
the first time somebody is in a hurry. Here CI stops naming commands at all: a
job runs one task, and what that task is made of lives in one file.

```
dart run :xtask check
```

## The shape

Two files in your repository.

**`xtask.yaml`**, at the repository root — this project's own, in full:

```yaml
version: 1

tasks:
  format:
    desc: fail if any Dart file is unformatted
    gate: [check]
    run: [dart, format, --output=none, --set-exit-if-changed, .]

  analyze:
    desc: refuse anything the analyzer or the house rules object to
    gate: [check]
    run: [dart, analyze, --fatal-infos]

  test:
    desc: run the suite
    gate: [check]
    run: [dart, test]

  check:
    desc: everything that must pass before work is called done
    collects: check
```

**`bin/xtask.dart`**, the entry point. The file name *is* the declaration:
`dart run :xtask` resolves to `bin/xtask.dart` and nothing else, so no manifest
entry names it.

```dart
import 'dart:io';

import 'package:xtask/xtask.dart';

Future<void> main(List<String> args) async {
  // Assigned, not discarded. `runXtask` answers with the exit code below, and
  // `=> runXtask(args)` throws it away — the process then reports success for
  // every outcome, including the two that mean the file is wrong.
  exitCode = await runXtask(
    args,
    verbs: {
      'regen': regen,
      'publish': publish,
    },
  );
}
```

A verb is ordinary Dart — testable, typed, debuggable:

```dart
Future<int> regen(VerbContext context) async {
  context.log('regenerating ${context.args.length} files');
  // context.args     the task's `args:` with its `argv-from` set expanded
  // context.env      the environment for this task only
  // context.workingDirectory
  return 0;
}
```

The engine ships **no** project verbs. `spec-check`, `regen`, `publish` are one
repository's business. Its only built-in is `remove`.

## The command

```
xtask <task>                run a task and everything it needs
xtask <task> -- <args>      and pass those arguments to its body
xtask <task> --keep-going   report every failure, not just the first
xtask --list                every task, with its description
xtask --list --gate <name>  only the tasks in that gate set
xtask --gates <name>        that gate set's task names, one per line
xtask --why <task>          what puts that task in a plan
xtask --check-ci            does the CI file still run the gate sets?
xtask --validate            parse and check the file; run nothing
xtask --dry-run <task>      print the resolved plan; run nothing
xtask --emit-schema         print the JSON Schema for this file format
xtask --version             print which engine this is
```

`xtask` above is shorthand for `dart run :xtask`. The file is looked for from
the current directory **upwards**, so the command works from a subdirectory and
every path inside the file stays relative to the repository root.

Everything after `--` reaches the body of the **named** task, after its `args:`
and its expanded `argv-from`, and nothing else in the plan sees it — so
`xtask test -- -n "one test"` narrows the tests without also handing `-n` to
the formatter. A task with no body of its own is refused rather than
swallowing them.

`--dry-run` shows what will actually happen, not what is written — sets
expanded, `$each` substituted, and the executable resolved on this machine:

```
$ dart run :xtask --dry-run check
plan: format, analyze, test, check
format
  run  /opt/homebrew/bin/dart format --output=none --set-exit-if-changed .
  in   /Users/you/project
analyze
  run  /opt/homebrew/bin/dart analyze --fatal-infos
  in   /Users/you/project
...
```

## Gate sets, and what they are for

A gate set is named after **who runs it** — one person's command, or one CI
job's. A task lists the sets it belongs to; a composite `collects:` a set and
therefore needs every task in it, in the order they appear in the file (cheap
gates before slow ones).

That is the whole mechanism for removing the duplicate list. A CI job runs
**one invocation**:

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart run :xtask check
```

Run-once still holds, because a job is one invocation. Parallelism is preserved,
because it comes from the jobs the CI system already schedules. And a failure is
still legible: on a host that folds output — GitHub Actions today — each task is
a collapsible section, and the failing one is annotated with the command and the
directory, so the line that says a task failed is also the line that reproduces
it.

A job that is one invocation has one duration, which answers nothing, so the run
prints what each task took at the end — after the last section, because a line
inside a fold is invisible in exactly the state somebody is in when they want a
number:

```
format    0.4s
analyze   2.3s
test     11.7s
total    14.4s
```

`--check-ci` keeps that arrangement from rotting. It reads the workflow and
compares it with the gate sets in both directions: a `run:` step that is not one
invocation of one gate set is refused, because that is exactly how the duplicate
list grows back — somebody writes `- run: dart analyze` instead of adding a task.
A gate set no job runs is reported rather than refused: gate sets are named after
who runs them, and that is the jobs *plus the people*, which nothing in the file
distinguishes.

It does not generate the workflow. Doing that would mean generating the
checkout, the toolchain and the artifact upload too, which needs a template
inside `xtask.yaml` — and templating is where an expression language starts.

The workflow file still owns what must **exist** before anything runs: the
checkout, the toolchain, a browser driver. `xtask` owns what runs. There is no
key that installs something; the one thing there is, is a precondition check:

```yaml
web-e2e:
  desc: browser e2e for the web binding
  gate: [ci-web]
  env-required: [CHROMEDRIVER]
  in: packages/lake
  run: [dart, test, test/web/web_e2e_test.dart]
```

which turns "a browser test failed somewhere inside" into "task `web-e2e`
requires `CHROMEDRIVER`, which is not set".

`--why` answers the other direction — not "what does this run" but "why does
this run at all". It names each entry point that reaches the task and spells
the route edge by edge, saying which kind each edge is, because "it runs before
this" and "it runs after this" are opposite answers:

```
$ dart run :xtask --why install
check
  check needs lint
  lint needs install
```

`--keep-going` is for the local loop. A gate that stops at the first failure
makes you fix, rerun, fix, rerun — the same argument `--validate` is built on,
which is why it collects every problem rather than throwing at the first. With
the flag, independent tasks still run and the run ends with a summary:

```
failed   lint (exit 1)
failed   unit (exit 1)
skipped  check (needs lint)
```

A task whose requirement failed does **not** run: its own failure would be a
consequence of the first one. It is named as skipped rather than dropped,
because a task that silently did not happen reads exactly like one that passed.

It is off by default. §5.2 promises a run stops at the first failure, and a
pipeline wants the earliest possible red rather than a broken run read to the
end.

## Exit codes

An exit code is not a success flag; it is the shortest possible bug report.

| code | meaning |
| --- | --- |
| `0` | everything asked for ran and passed |
| `1` | a task ran and failed |
| `2` | the file was refused — a bad document, an unknown key, a cycle, a dangling reference, a set that expands to nothing |
| `3` | a task's executable was not found |
| `4` | a task's body succeeded and one of its `then:` continuations failed |

With `--keep-going` and more than one failure, the code is the **first**
failure's. A code is a report about one failure, and a run with three cannot
honestly claim to be about all of them; the summary is where the others are.

`3` is separate because "Dart is not installed on this machine" and "the code is
broken" are repaired by different people, and one code sends both to the same
one.

`4` exists because a publish followed by a verification has **three** endings,
not two: nothing was published, everything passed, or the upload happened and
the check after it is red. Collapsing the third into `1` tells a pipeline the
publish failed, which is false and unrecoverable in the wrong direction — the
registry will not accept that version again.

## The keys

| key | meaning |
| --- | --- |
| `desc` | required, one line, what `--list` prints |
| `run` | an external program as **argv** — the program, then its arguments, each its own entry. Never a command line; nothing splits a string and no shell sees it |
| `do` | a verb: `remove`, or one this project registered |
| `args` | extra arguments appended to the body |
| `argv-from` | a set whose members are appended as arguments, already expanded |
| `each` | a set whose members the body runs once per, sequentially |
| `in` | where the body runs, relative to the root — or the literal `$each` |
| `env` | environment for this task only |
| `env-required` | variables that must already be set, checked before the body runs |
| `needs` | direct requirements, run before this task, once per invocation |
| `then` | continuations, run **after** this task's body |
| `gate` | the gate sets this task belongs to |
| `collects` | names a gate set this task is the composite of |
| `timeout` | seconds a `run:` body may take before it is killed — per member under `each:` |

`timeout:` is asked of the process, not waited out by the engine: the body is
sent SIGTERM, given a moment to write what it has, and then SIGKILL. What it
does **not** do is reach the process's own children — Windows has job objects,
POSIX has process groups, and neither is what Dart exposes — so a task that
spawns a server and hangs may leave the server behind. A `do:` cannot carry a
`timeout:` at all: a verb is a Dart function, nothing outside it can stop one,
and a limit that passed while the verb kept writing to disk would be worse than
none. That is refused when the file is read, not discovered at runtime.

A set is a list of members or a glob with exclusions, expanded by the engine
rather than by a shell, in a deterministic order:

```yaml
sets:
  packages: [packages/lake, packages/lake_cli]

  sources:
    include: ['{templates,packages}/**/*.lake']
    exclude: ['**/test_data/**']
```

A set that expands to nothing is an **error**: a task given no files checked
nothing, and a gate that examined nothing is worse than no gate.

## Editor support

`xtask --emit-schema` prints a JSON Schema for the file format. Generate it into
your repository and point at it with a relative path, so a fresh clone needs
neither the network nor a per-person editor setting:

```
dart run :xtask --emit-schema > xtask.schema.json
```

```yaml
# yaml-language-server: $schema=./xtask.schema.json
version: 1
```

The schema knows the **shape** of the file: it completes a task's keys, and
underlines `dsec:` or a `gate:` written as a string, while you type. Everything
that needs the graph or the filesystem — a cycle, a `needs:` pointing at
nothing, an orphan gate, a glob matching nothing, an unregistered verb — is what
`--validate` answers. A schema catches a mistyped **key**; `--validate` catches
a mistyped **name**.

The schema describes one version of the engine, which is why it is generated
into your repository rather than fetched from a URL.

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
- **Not parallel.** Tasks run in order, one at a time. Parallelism belongs to
  the CI system, which already has it.
- **No plugins, no dynamic loading, no expression language.** Verbs are code the
  project links; everything else is data.
- **No templating or interpolation** beyond `$each`. The moment a value can be
  computed in the file, R1 is gone.

## Prior art

| | what it is | why not this |
| --- | --- | --- |
| `make` | a task graph with shell bodies | the model is right and is what `xtask` keeps; the shell bodies and the absence of Windows are what it drops |
| `cargo xtask` | automation as a project-local binary in the project's own language | the closest relative and where the name comes from — but it puts the *composition* in code too, so "what does `check` run" means reading a program |
| `grinder` | a Dart task runner, tasks as annotated functions | tasks as code is right for jobs with logic and wrong for the two-thirds that are one line, and it makes the gate list uninspectable |
| `melos` | Dart/Flutter monorepo tool | complementary — but its script bodies are shell, so it does not solve portability |
| npm scripts | shell strings in a manifest | the cautionary tale: choosing shell forced a family of shim packages into existence |

**The one-line difference:** `make`'s model with argv bodies, project verbs, and
the gate list as data.

## Windows

`run:` is argv, and the engine resolves the program itself — walking `PATH`,
honouring `PATHEXT`, and knowing that `CreateProcess` cannot start a `.bat` or
a `.cmd` however it is asked. A shim goes through the shell because there is no
other way; an argument that the shell would reinterpret is **refused** with the
character named, rather than passed through to mean something else.
