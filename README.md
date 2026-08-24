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

tasks:
  lint:
    desc: check the style
    gate: [check]
    run: [ruff, check, .]

  test:
    desc: run the suite
    gate: [check]
    run: [pytest, -q]

  check:
    desc: everything that must pass before work is called done
    collects: check
```

Those two are a Python repository's tools; put in whatever your own repository
already runs. Naming a program that is not installed is not a silent pass —
the run stops and says which one:

```
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

Two keys in that file are doing the work, and they point in opposite
directions. `gate: [check]` is written on a check and means *I am a member of
the group called `check`*. `collects: check` is written on the task you type
and means *I run that whole group*, in the order the file writes it. A task
named `check` collecting a gate named `check` is the ordinary case and not a
cycle — [Gate sets](#gate-sets-and-what-they-are-for) says why, and why the
whole tool exists for those two keys.

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

The third step, and the only one that needs Dart code, is a **verb**: a
function of your own for a job with real logic in it. An engine somebody else
shipped cannot contain your function, so you hand it over from a file of yours:

```shell
dart run :xtask <task>
```

The colon is the whole difference between the last two, and it is easy to read
past: what is written to the left of it is which package the executable comes
from, and an empty left side means yours. Without a `bin/xtask.dart` of your
own the short spelling fails with `Could not find bin/xtask.dart in package
<yours>`, which is a truthful error and a baffling one if nobody said the file
was optional.

The rest of this README writes the short spelling, because this repository has
a `bin/xtask.dart`. If you installed the engine and wrote no Dart, read every
`dart run :xtask` below as plain `xtask`: the flags and the file are the same,
and only the way the program is reached differs.

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
    },
  );
}
```

A verb is ordinary Dart — testable, typed, debuggable:

```dart
Future<int> regen(VerbContext context) async {
  context.log('regenerating ${context.args.length} files');
  // context.args     the task's `args:` with its `argv-from` set expanded
  // context.env      the process environment, with this task's `env:` on top
  // context.workingDirectory
  return 0;
}
```

The engine ships **no** project verbs. `spec-check`, `regen`, `publish` are one
repository's business. Its only built-in is `remove`.

The file name *is* the declaration: `dart run :xtask` resolves to
`bin/xtask.dart` and nothing else, so no manifest entry names it.

### This repository's own file

Not quoted here, on purpose. It is [`xtask.yaml`](xtask.yaml) in this
repository, it has seven tasks and two gate sets, and it carries its reasoning
in comments that a copy would strip. A README that quoted it would be keeping
the same list twice, which is the defect this tool exists to remove — and the
copy that used to sit here had already drifted: it showed four tasks and one
gate, while the paragraph above it pointed at an `aot` task the copy did not
contain.

## The command

```shell
xtask <task>                 run a task and everything it needs
xtask <task> -- <args>       and pass those arguments to its body
xtask <task> --keep-going    report every failure, not just the first
xtask <task> --parallel      run independent tasks at once — which costs
                             seeing their output as it arrives
xtask --list                 every task, with its description
xtask --list --gate <name>   only the tasks in that gate set
xtask --gate-members <name>  that gate set's task names, one per line
xtask --why <task>           what puts that task in a plan, and by which
                             `needs:` or `then:`
xtask --validate             parse and check the file; run nothing
xtask --check-ci             does the CI file still run the gate sets?
xtask --dry-run <task>       print the resolved plan; run nothing
xtask --emit-schema          print the JSON Schema for this file format
xtask --version              print which engine this is
```

`xtask` above is whichever spelling you arrived at — the installed command, `dart run xtask:xtask`, or `dart run :xtask`. The flags are the same in all three. The file is looked for from
the current directory **upwards**, so the command works from a subdirectory and
every path inside the file stays relative to the repository root.

`dart install xtask` puts a real `xtask` on the PATH, compiled, and for a
repository whose tasks are all `run:` that is the pleasant way to work.

It stops working the moment a project registers a **verb**, and that is the
design rather than a limitation. What gets installed is this package's own
entry point, and it passes no verbs, because it cannot know yours: `do: notify`
then meets *"the engine ships no project verbs"*, correctly, since the `notify`
the file means is a Dart function in your repository and not in the tool. That
is why the entry point belongs to the project — a global install is the engine,
and `dart run :xtask` is the engine plus what you wrote. The second thing is
also pinned by your `pubspec.yaml`, where a globally installed tool is a version
of its own that no repository can see.

That shorthand pays the JIT's start-up — around half a second, every
invocation. It is nothing against a gate that spends seconds inside a test
runner, and it is the entire cost of `--gate-members`, `--why` or `--dry-run`, which
is where a shell loop or a file being written notices it. `dart compile exe
bin/xtask.dart` removes it. The binary still reads `xtask.yaml` at run time, so
tasks, gates and sets keep changing without recompiling; verbs are Dart, so a
binary holds the ones it was built with and wants rebuilding after one changes.
This repository keeps its own invocation as the `aot` task rather than a second
copy in this file — `xtask --dry-run aot` prints it.

Everything after `--` reaches the body of the **named** task, after its `args:`
and its expanded `argv-from`, and nothing else in the plan sees it — so
`xtask test -- -n "one test"` narrows the tests without also handing `-n` to
the formatter. A task with no body of its own is refused rather than
swallowing them.

`--dry-run` shows what will actually happen, not what is written — sets
expanded, `$each` substituted, and the executable resolved on this machine.
The task names below are this repository's own, from [`xtask.yaml`](xtask.yaml):

```shell
$ xtask --dry-run check
plan: format, analyze, test, check
format
  run  /opt/homebrew/bin/dart format --output=none --set-exit-if-changed .
  in   /Users/you/project
analyze
  run  /opt/homebrew/bin/dart analyze --fatal-infos
  in   /Users/you/project
...
```

Because it resolves them, `--dry-run` answers `3` when a program is not
installed yet, naming the one it could not find. That is the same answer a real
run would give, one step earlier — which is worth knowing before you read it as
a bug on a machine where the tools are not set up.

## Gate sets, and what they are for

A gate set is named after **who runs it** — one person's command, or one CI
job's. A task lists the sets it belongs to; a composite `collects:` a set and
therefore needs every task in it, in the order they appear in the file (cheap
gates before slow ones).

`collects:` names **one** set, not a list — a composite is the thing you type,
and one command gathering two unrelated sets is two commands wearing one name.
Naming the composite after the set it gathers is the ordinary case and not a
cycle: a task in gate `check` called `check` does not need itself, because
gathering a set does not mean gathering yourself. The engine drops it from its
own members rather than reporting the cycle that would otherwise be there.

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

```shell
format    0.4s
analyze   2.3s
test     11.7s
total    14.4s
```

`--check-ci` keeps that arrangement from rotting. It reads every file under
`.github/workflows` — GitHub Actions is the only host it knows, and a
repository without that directory is told so rather than passed — and compares
what it finds with the gate sets in both directions: a `run:` step that is not one
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

```shell
$ xtask --why lint
check
  check needs lint
```

`--keep-going` is for the local loop. A gate that stops at the first failure
makes you fix, rerun, fix, rerun — the same argument `--validate` is built on,
which is why it collects every problem rather than throwing at the first. With
the flag, independent tasks still run and the run ends with a summary:

```shell
failed   lint (exit 1)
failed   unit (exit 1)
skipped  check — needs `lint`, which did not pass
```

A task whose requirement failed does **not** run: its own failure would be a
consequence of the first one. It is named as skipped rather than dropped,
because a task that silently did not happen reads exactly like one that passed.

It is off by default, because a pipeline wants the earliest possible red
rather than a broken run read to the end.

`--parallel` runs tasks that do not depend on each other at once, up to the
number of processors or `--parallel=N`. It is **not** the default, and the
reason is a real cost rather than caution: normally a task's output passes
through as it arrives and each task is a section that folds, and two tasks
writing to one terminal at once break both — the transcript belongs to neither.
So a parallel run collects each task's output and prints it whole when that
task ends. You get the answer sooner and you watch it happen less — and it says
so on the first line, because a run that goes quiet for eight seconds without
explaining itself is indistinguishable from one that has hung.

The summary then says both numbers, because they answer different questions:

```shell
lint   1.0s
unit   1.0s
types  1.0s
total  3.1s spent, 1.1s taken
```

Declaration order still decides which of the ready tasks starts first — cheap
gates before slow ones — but nothing makes them finish in that order. A failure
stops what has not started; it does not reach into what is running, because
killing a task would leave whatever it was half-way through in whatever state
that half is. Whichever way it ran, the summary then names what did not run:

```shell
failed   format (exit 1)
skipped  analyze — the run stopped at an earlier failure
skipped  check — needs `format`, which did not pass
```

## Exit codes

An exit code is not a success flag; it is the shortest possible bug report.

| code | meaning |
| --- | --- |
| `0` | everything asked for ran and passed |
| `1` | a task ran and failed |
| `2` | the file was refused — a bad document, an unknown key, a cycle, a dangling reference, a set that expands to nothing |
| `3` | a task's executable was not found |
| `4` | a task's body succeeded and one of its `then:` continuations failed |

A `4` stops the run exactly as a `1` does: what has not started does not
start, what is running is left alone, and the summary names the rest. The code
says which of the three endings happened, not how much of the plan was
abandoned — those are different questions and `--keep-going` is the one that
answers the second.

With `--keep-going` and more than one failure, the code is the **first**
failure's. A code is a report about one failure, and a run with three cannot
honestly claim to be about all of them; the summary is where the others are.

`3` is separate because "Dart is not installed on this machine" and "the code is
broken" are repaired by different people, and one code sends both to the same
one.

A **verb**'s exit code is what the run answers with — it is your Dart, written
against this table, and the built-in `remove` answers `2` for a path outside the
repository because that means *the file is wrong*. A program started by `run:`
has never heard of this table, so its code goes in the message and the run
answers `1`.

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

The example at the top uses four keys because four is what that repository
needs. Here is one using the rest — a release, which is where `needs:`,
`then:` and a verb all earn their keep at once:

```yaml
version: 1

sets:
  packages:
    include: [packages/*]

tasks:
  build:
    desc: build every package
    each: packages
    in: $each
    run: [dart, run, build_runner, build, --delete-conflicting-outputs]

  publish:
    desc: publish, and announce it only if that worked
    needs: [build]
    then: [announce]
    env-required: [PUB_TOKEN]
    timeout: 600
    run: [dart, pub, publish, --force]

  announce:
    desc: post the release note
    do: notify
    argv-from: packages
```

`each:` runs the body once per member, sequentially, with `in: $each` putting
each run in that member's own directory. `needs:` is "before, and once however
many tasks ask for it"; `then:` is "after, and only if the body worked" —
which is the whole reason exit code `4` exists, because `publish` succeeding
and `announce` failing is a third ending and not a failure to publish.
`env-required:` is checked before that task's body runs — not at the start of
the run — so a missing token is a sentence rather than a broken upload. `do:` names a verb the project wrote in
Dart and handed to `runXtask`, and `argv-from:` hands it the expanded set as
arguments.

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

```shell
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
- **Not parallel by default.** Tasks run in order, one at a time, and
  parallelism belongs to the CI system, which already has it. `--parallel` is
  there for the local loop and costs watching the output arrive.
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

Windows has no `argv`. `CreateProcess` takes one string, and the runtime at the
other end splits it again — so an array is a promise somebody has to keep by
quoting. Dart's `Process` does that, by the rules `CommandLineToArgvW` reads
back, and a task written as a list arrives as that list: a path with a space in
it stays one argument and is not two. Where quoting is not enough the engine
refuses rather than hopes, and that is the batch shim above — `cmd.exe` parses
the line a second time, after the quoting, by rules of its own.

## License

MIT — see [LICENSE](LICENSE).
