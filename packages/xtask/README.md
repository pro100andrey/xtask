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
is not a task and needs none. [Gate sets](#gate-sets-and-ci) says why the whole
tool exists for those two lines, and [The keys](#the-keys) is every key a task
can have.

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
shipped cannot contain your function, so you hand it over from a file of yours:

```shell
dart run :xtask <task>
```

That file is `bin/xtask.dart`, and it is the whole of what a project writes:

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
  // context.member   which member of `each:` this run is for, or null
  // context.run(...)  a program, started the way a `run:` body is —
  //                   PATH, PATHEXT, the batch rule, the exit codes.
  //                   `workingDirectory:` is a path from the repository
  //                   root, and stays inside it; left out, it is the task's
  // context.capture(...)
  //                   the same start, run to the end with its output kept:
  //                   `(exitCode:, stdout:, stderr:)`, each stream whole.
  //                   For a verb that has to read what a program said —
  //                   not `Process.run`, which loses everything above.
  //                   `timeout:` stops one that outlives it, with 124
  // context.tee(...)
  //                   `capture`, with the output shown as it arrives,
  //                   the way `run` shows it — for a program the verb
  //                   waits minutes on and then reads
  // context.which('code')
  //                   the file a start would find, or null — to decide
  //                   before starting anything. Takes the same
  //                   `workingDirectory:` `run` would be given
  // context.out      `log` as a StringSink, for a library that writes to
  //                  one; a last line without a newline is flushed for you
  // context.args     `args:` with `$all` expanded, then anything
  //                  the command line passed after `--`
  // context.env      this machine's environment, without `env-unset:`,
  //                  with `env:` and `env-paths:` winning a clash
  // context.root     the repository root, absolute — what a set's members
  //                  and `in:` are relative to
  // context.file('packages/a/x.dart'), context.directory(...)
  //                  a path from the root, written with `/` — a member as it
  //                  is — and a 2 for one that climbs or links out of it
  // context.workingDirectory
  //                  where the task runs: the root, or its `in:` under it —
  //                  what a `remove` argument is read from. A set's member
  //                  is `context.file(member)`, never joined onto this
  return 0;
}
```

The engine ships **no** project verbs — `regen` above is one repository's
business, not the tool's. Its only built-in is `remove`.

The file name *is* the declaration: `dart run :xtask` resolves to
`bin/xtask.dart` and nothing else, so nothing has to name it to make that work.
(`pubspec.yaml` does carry an `executables:` entry, and it is there for
`dart install` — which fails outright without one — not for `dart run`.)

The colon in `dart run :xtask` is the whole difference from
`dart run xtask:xtask`, and it is easy to read past: what is written to the
left of it is which package the executable comes from, and an empty left side
means yours. Without a `bin/xtask.dart` of your
own the short spelling fails with `Could not find bin/xtask.dart in package
<yours>`, which is a truthful error and a baffling one if nobody said the file
was optional.

`dart install xtask` puts a real `xtask` on the PATH, compiled, and for a
repository whose tasks are all `run:` that is the pleasant way to work.

A project that registers a **verb** has its own `bin/xtask.dart`, and that is
where the verb is: what gets installed is this package's entry point, which
cannot contain a Dart function of your repository. So the installed `xtask`
looks for one. Where the directory holding `xtask.yaml` has a `bin/xtask.dart`,
it hands the whole run to it and answers with its exit code — `xtask install`
then means exactly what `dart run :xtask install` means, verbs, pinned version
and all.

An entry point kept anywhere else is named in the file, from the root:

```yaml
version: 1
entry: tools/bin/xtask.dart   # a tools package of its own
```

Its package is the nearest `pubspec.yaml` at or above it — `tools/` here, not
the root — and `--validate` says so when the file is not there or is in no
package. The project's entry is started where you are standing, so relative
paths on the command line keep meaning what they meant:

- `dart run <package>:xtask`, when the entry point is its package's
  `bin/xtask.dart` and the package resolution nearest to you is that
  package's own — from the package, or from any package of its workspace
  where it says `resolution: workspace`. It costs what `dart run :xtask`
  costs, about a third of a second, on top of the installed binary's start.
- `dart run <path>/<entry>`, otherwise: from outside that resolution, or for
  an entry point that is any other file. Correct, and slower: a file is
  compiled every time. A resolution that only depends on the package — an
  `example/` beside a library, a root depending on its tools package — gets
  this form too: it has the package but not the package's
  `dev_dependencies`, which is where `xtask` usually is.
- When the package has never been resolved, or its `pubspec.yaml`,
  `pubspec.lock` or `pubspec_overrides.yaml` is newer than its resolution
  (or it has no lock), as after a pull that brought a dependency:
  `dart pub get` in it, then the file, still from where you stand. The name
  form needs none of this, since `dart run` does the same check itself.
  `dart run :xtask` in the package would resolve it too, but only by moving
  the run there, and every relative path you typed (`--report`,
  `--check-schema`, …) would be read from the wrong directory.

A workflow step running that file — `dart run tools/bin/xtask.dart check`, or
an entry point with a name of its own — is a gate set's invocation to
`--check-ci`, as `xtask check` is. A file named in `entry:` is matched by its
whole path, `./` or a directory before it allowed: with `entry:
tool/main.dart`, `dart run bin/main.dart serve` is the application, not a
gate set.

`--completion` is not handed over, and neither is `--names`, which a
completion script asks on every TAB, while the installed engine can read the
file — only a file written for a newer `xtask` sends it to the project.
Arguments after `--` are a task's and decide nothing here. A task that runs
`xtask` hands over again, as the person typing it would; a run handed over
eight times deep is taken for a loop (`XTASK_HAND_OVERS` counts) and refused
with `2`. Without `dart` on `PATH` the installed `xtask` says so and answers
`3`; a `dart pub get` that fails is shown and answered `1`; otherwise the code
is the project's, and an entry point that does not compile is `dart run`'s
`254` or `255`. Where `dart` is a batch file (`dart.bat`, as Flutter puts on
`PATH`), a command line carrying a character `cmd.exe` would read — `&`, `|`,
`%`, … — is refused with `2` before anything runs; the SDK's `dart.exe`
ahead of it on `PATH` has no such limit. In this package itself there is
nothing to hand over to: its `bin/xtask.dart` is the installed one. Each of
those refusals writes the `--report` the command line asked for, as the
engine's own refusals do: the run that would have written it never starts.

On Linux and macOS an interrupt the installed `xtask` receives is passed on
to the run as a `SIGTERM`, and a `SIGTERM` as it is. On Windows nothing is
passed on: `Process.kill` there does not deliver a signal, it ends the
process, as the Dart SDK documents it — which would end the project's engine
before it had stopped its run, printed its summary or written its report. A
Ctrl-C at a console reaches every process attached to it, the project's
engine among them, which stops its run itself; the installed `xtask` only
hears it, so as not to end first, and waits for the run to end. This is
read from the SDK's documentation and decided by a test that names the
platform, not measured on a Windows console. An interrupt sent to the
installed `xtask` alone, from outside the console, does not reach the run on
Windows.

`dart run` pays the JIT's start-up — around half a second, every invocation. It
is nothing against a gate that spends seconds inside a test runner, and it is
the entire cost of `--gate-members`, `--why` or `--dry-run`, which is where a
shell loop or a file being written notices it. `dart compile exe
bin/xtask.dart` removes it. The binary still reads `xtask.yaml` at run time, so
tasks, gates and sets keep changing without recompiling; verbs are Dart, so a
binary holds the ones it was built with and wants rebuilding after one changes.
This repository keeps its own invocation as the `aot` task rather than a second
copy in this file — `xtask --dry-run aot` prints it.

An entry point that has to ask the file something before it hands the run
over — which tasks a gate set holds, to choose among them — need not start a
second engine for the answer and pay that half second again. Two functions
read it in-process, from the code the command line answers from:

```dart
final root = findRoot(Directory.current.path);   // the directory holding
                                                 // xtask.yaml, or null
final members = gateMembers('check');            // what --gate-members prints
```

`gateMembers` looks for the file from `workingDirectory:` upwards (left out,
from where the process runs) and answers the gate set's tasks in run order. It
is the code `--gate-members` itself runs, so where that command refuses —
no `xtask.yaml` here or above, one that cannot be read or does not parse, a
gate set the file does not declare — the function throws
`XtaskFormatException` carrying the same message. A declared gate set with no
members is `[]`. Neither function runs a task or reads anything but the file.

### Testing a verb

A verb is a function of a `VerbContext`, so a test builds one and calls it —
no engine, no file, no process:

```dart
final logged = <String>[];
final code = await regen(
  VerbContext(
    args: ['schema/a.lake'],
    env: const {},
    root: repo.path,
    workingDirectory: repo.path,
    log: logged.add,
    start: (argv, {workingDirectory}) async => 0,
  ),
);
expect(code, ExitCode.success);
```

`start` is how `context.run` starts a program, so a fake one records what the
verb asked for. `locate` and `collect` stand behind `which` and `capture` the
same way, as `relay` stands behind `tee`, and are needed only by a verb that
calls them — one that does and
was not given them is told so, rather than answered "not found". `out` is a
sink over `log` unless one is given; call `context.out.flush()` before
reading `logged` if the verb's last line may lack a newline.

## The command

```shell
xtask <task>                 run a task and everything it needs
xtask <task> -- <args>       and pass those arguments to its body
xtask <task> --keep-going    report every failure, not just the first —
                             across tasks and across an `each:`
xtask <task> -j <n>          run n at once — which costs seeing their
                             output as it arrives. `-j auto` picks one
xtask <task> --only <set>=<pattern>,…
                             only the members of that set a pattern
                             matches, wherever an `each:` or `all:`
                             names it; with --dry-run too
xtask <task> --report <file> write what each task came to there, as
                             JSON — as it goes, and on a failure
xtask --list                 every task, grouped under its gate set,
                             in the order `gates:` declares
xtask --list --gate <name>   only the tasks in that gate set
xtask --gate-members <name>  the tasks in that gate set, one per line
xtask --why <task>           what puts that task in a plan, and by which
                             `needs:` or `then:`
xtask --graph [<name>]       what that gate set or task pulls in, as
                             a tree; with no name, every gate set
xtask --validate             parse and check the file; run nothing
xtask --check-ci             does the CI file still run the gate sets?
xtask --dry-run <task>       print the resolved plan; run nothing
xtask --emit-schema          print the JSON Schema for this file format
xtask --check-schema <path>  does that file match --emit-schema?
xtask --names                every gate set, task and set, one per line
                             and tab-separated — what completion reads
xtask --completion <shell>   a completion script for bash, zsh or fish
xtask --version              print which engine this is
```

`xtask` above is whichever spelling you arrived at — the installed command,
`dart run xtask:xtask`, or `dart run :xtask`. The flags are the same in all
three. The file is looked for from the current directory **upwards**, so the
command works from a subdirectory and every path inside the file stays relative
to the repository root.

A shell completes task, gate set and set names from the file, read when TAB
is pressed, so nothing is regenerated after the file changes:

```shell
source <(xtask --completion bash)    # in ~/.bashrc
source <(xtask --completion zsh)     # in ~/.zshrc, after compinit
xtask --completion fish | source     # or save it under completions/
```

The script completes the command `xtask`, and each TAB starts it — so it is
the installed or compiled one that makes this pleasant: `dart run` spends
half a second starting before it can answer.

Everything after `--` reaches the body of the **named** task, after its `args:`
and its expanded `all:`, and nothing else in the plan sees it — so
`xtask test -- -n "one test"` narrows the tests without also handing `-n` to
the formatter. A task with no body of its own is refused rather than
swallowing them.

`--only` narrows a set for one run, without editing the file — two packages
of seventeen while working on those two:

```shell
xtask pkg-test --only packages=packages/twk,packages/twk_rich
```

Every `each:` and `all:` in the plan that names the set gets only the members
a pattern matches, in the set's order. A pattern is a glob, read against the
member as text: `packages/twk` keeps that one and not `packages/twk_rich`, and
`packages/twk*` keeps both, as does `packages/{twk,twk_rich}`: a comma inside
braces is the pattern's, not a separator. Written again for the same set, the patterns add
up. `--dry-run` prints the narrowed plan, and the summary says how much of the
set ran — `2 of 17 members` on the task's row. Each of these is a `2` rather than a smaller
run: a set the file has not got, a set nothing in the plan expands, a pattern
that is not one, and a pattern that matches no member — the last when the set
is read, since that is when its members are known. `--check-ci` reports a step
that narrows a gate set: the job reads as the gate, and runs part of it.

## Seeing what will happen

Three questions the tool answers without running anything. All are cheap,
and all are the fastest way to find out that a file says something other
than what you meant.

`--dry-run` shows what will actually happen, not what is written — sets
expanded, `$each` substituted, and the executable resolved on this machine.
The task names below are this repository's own, from [`xtask.yaml`](xtask.yaml):

```shell
$ xtask --dry-run check
plan: format, analyze, test
format
  run  /opt/homebrew/bin/dart format --output=none --set-exit-if-changed .
  in   /Users/you/xtask
analyze
  run  /opt/homebrew/bin/dart analyze --fatal-infos
  in   /Users/you/xtask
...
```

The plan names the tasks, not the gate set: `check` is what you asked for, and
what a run does is its members.

A `do: remove` block goes further and says what it would delete. The one verb
this engine ships is the one that deletes recursively, and a plan showing only
the pattern told you least about the operation you most need to check. In a
project whose file has a `clean` task built on the `remove` verb:

```shell
$ xtask --dry-run clean
plan: clean
clean
  do   remove build coverage **/*.tmp
  in   /home/you/that-project
  del  build
  del  coverage
  del  src/a.tmp
```

Nothing is run to work that out — it is the reading the verb itself does — and
a tree that is already clean says so rather than printing nothing.

Because it resolves them, `--dry-run` answers `3` when a program is not
installed yet, naming the one it could not find. That is the same answer a real
run would give, one step earlier — which is worth knowing before you read it as
a bug on a machine where the tools are not set up.

`--why` answers the other direction — not "what does this run" but "why does
this run at all". It names each entry point that reaches the task and spells
the route edge by edge, saying which kind each edge is, because "it runs before
this" and "it runs after this" are opposite answers:

```shell
$ xtask --why test
gate check
  gate check runs test
test
  nothing else names it: `test` is where a run starts
```

Two routes, because there are two: the gate set reaches it, and so does
somebody typing its name.

`--graph` looks the other way from `--why`: down from what somebody types,
to everything it pulls in. `--why test` asks who brings `test` into a run;
`--graph publish` asks what `publish` brings. It draws a tree from the file
and resolves no body, so it says nothing a program on this machine would
change — that is `--dry-run`'s to say. In a project that builds two
flavours over five packages:

```shell
$ xtask --graph publish
publish
├─ needs build ×2       dev, prod
│  └─ needs pub-get ×5  packages/a, packages/b, packages/c and 2 more
├─ needs analyze
│  └─ needs pub-get     (see above)
└─ then  announce
   └─ needs build       (see above)
```

- **A task is drawn once.** Every later edge to it says `(see above)`, as
  cargo tree's `(*)` does: the run reaches it once too, and a shared need
  drawn again under everything that needs it reads as two runs of it.
- **`then:` is its own word**, never a `needs`: one runs before the task
  and the other after it.
- **An `each:` task says how many members it runs for, and names them** —
  three, and then how many more; a fourth is named rather than counted,
  since "and 1 more" is no shorter. Its set is expanded as a run would
  expand it now. One whose `produced-by:` task has not run yet says it
  `cannot be resolved yet`, as `--dry-run` does. Any other empty set is
  refused with `2` where a name was given, as the run would refuse it; with
  no name it is said on the task's own row — set `art` is empty — since a
  picture of the whole file is not one task's to withhold.
- **A task for another OS is marked** `⊘ linux only`, the summary's mark
  for it, and its set is not expanded: the run would not expand it here.

A gate set is drawn with its members under it. With no name, `--graph` draws
every gate set in the order `gates:` declares, then — under `ungated`, as
`--list` groups them — the tasks no gate set reaches, each one nothing else
names at the top of its own branch. A name a run would refuse — unknown,
both a gate set and a task, a gate set with nothing in it, a ring — is
refused here with the run's own sentence and `2`.

## Gate sets, and CI

A gate set is named after **who runs it** — one person's command, or one CI
job's. Every set the file has is declared once, at the top:

```yaml
gates: [check, release]
```

Names only — a gate set is not a task and has nothing to describe. Declaring
them is what makes a misspelling a refusal: a gate that came into existence by
being mentioned could not be misspelled, because the misspelling was a new
gate. The order is the author's, and is the order `--list` groups by.

A task lists the sets it belongs to, and `xtask check` runs every task in
`check`, in the order they appear in the file (cheap gates before slow ones) —
except where a `needs:` or a `then:` between two of them says otherwise, since
"it runs before this" is an order too, and the one the file states outright.
A declared set nothing is in is refused, for the reason the empty-set rule
exists: a gate that examined nothing reports the same green as one that passed.

There is no composite task, and nothing to keep in step with the declaration. A
gate set and a task may not share a name — a person types one word — and
`needs:` may not name a gate set, because an edge runs between tasks and a gate
set is a list rather than a step.

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

A repository that installs the engine rather than depending on it has one
step that is not a gate — the install — and says so on the step, with the
marker described below:

```yaml
      - uses: dart-lang/setup-dart@v1
      - run: dart install xtask # xtask: not a gate — the engine itself, which no action installs
      - run: xtask check
```

Run-once still holds, because a job is one invocation. Parallelism is preserved,
because it comes from the jobs the CI system already schedules. And a failure is
still legible: on a host that folds output — GitHub Actions today — each task is
a collapsible section, and the failing one is annotated with the command and the
directory, so the line that says a task failed is also the line that reproduces
it.

`--check-ci` keeps that arrangement from rotting. It reads every file under
`.github/workflows` — GitHub Actions is the only host it knows, and a
repository without that directory is told so rather than passed — and compares
what it finds with the gate sets in both directions: a `run:` step that is not
one invocation of one gate set is refused, because that is exactly how the
duplicate list grows back — somebody writes `- run: dart analyze` instead of
adding a task. A gate set no job runs is reported rather than refused: gate
sets are named after who runs them, and that is the jobs *plus the people*,
which nothing in the file distinguishes. The same goes one level down: a task
that is in some gate set and that no job's run reaches — through `needs:` and
`then:` included — is named too, grouped by the gate sets it is in, because a
people's set is always on the first list and the task added to it without a
job's label would otherwise be on none. A step that asks xtask a question —
`--validate`, `--check-ci` itself — is reported the same way: it names no
command that could drift, so there is nothing to move into the file.

Run it where drift is caught before it is pushed: as a task in the gate set a
person runs, and so in the job that runs that gate too.

```yaml
  workflows-check:
    desc: fail if a CI step runs anything but one gate set
    gate: [check]
    run: [dart, run, ':xtask', --check-ci]
```

A step names a gate set and is still not counted as running it in two cases,
both reported as findings. **Its result may not fail the job**:
`continue-on-error:` on the step or on its job, `true` or an expression that
may be. **It may read another file**: a `working-directory:` — on the step, or
as `defaults: run:` on its job or its workflow — that holds an `xtask.yaml` of
its own runs that file's gate set of the same name, and one that is an
expression could be any directory. A directory without a file of its own still
reaches this one, because the file is looked for upwards; for the root, write
`.` rather than `${{ github.workspace }}`.

The rule is blanket, and the exception is written where the exception is: on
the step's own `run:` line, after the command.

```yaml
- run: dart run :xtask check
- run: npx playwright install --with-deps # xtask: not a gate — the browser driver, which no action installs
```

That is the one place the marker is read. A step is judged **as written**: the
whole of its `run:` is one command line, and it either is one invocation of
one gate set or it is not. Nothing here reads shell — no quotes, no `&&`, no
`cd` — because every reading of shell a checker attempts is a way for a job
that runs nothing to be counted as running something. So a `run: |` block of
more than one line is a script, and a script is reported rather than read; a
step with `${{ … }}` in it is reported rather than guessed at; and a mention
of xtask anywhere but in command position — `echo run xtask check`,
`timeout 600 ./xtask check` — is a command like any other. Put the marker
after the `|` to excuse a whole script, use `working-directory:` rather than
`cd`, and put a `timeout:` on the task rather than around the invocation. A
step with an `if:` is reported with its condition beside the gate it runs,
since whether the condition holds is not something this file can say.

**The reason is required.** A marker with nothing after it is refused, because
a marker with nothing after it is what this becomes when it is reached for to
make a red gate green.

**And it only excuses a step that is not this file's gate**, which is the one
thing it claims: a step reported as a command, or one of the two cases above —
another file's gate set, or a result that may not fail the job. On any other
step that reaches xtask it is refused, whatever it says — one that runs a gate
set here, one that names a gate set under a mode, one that asks a question, one
the command line itself turns away, one that names a gate set with a typo in
it. Otherwise the marker is a way of making a job that runs nothing pass,
which is the failure this whole mode exists to catch.

Every exemption is printed with its reason next to the jobs that passed, so a
workflow that has quietly exempted its way to green says so in the same
breath. And when every `run:` step under `.github/workflows` is exempted,
nothing there invokes xtask, which is refused as it was before: the marker
cannot stand in for the invocation. The count is over the directory, not the
file, so a workflow with no gate in it at all can sit beside one that runs
them.

The rule stays blanket rather than growing a sense of which steps are
"infrastructure" because no tool anywhere has one: the axis does not exist, and
a checker inventing it would be classifying shell — the second grammar this
mode is written not to keep.

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

## Reading a run

What a run tells you while it happens and when it ends — and what changes
about that when you ask it to go faster.

A run has one duration, which answers nothing on its own, and a CI job that is
one invocation has only that one. So the run ends with one row per task — how
it ended and what it took — after the last section, because a line inside a
fold is invisible in exactly the state somebody is in when they want a number:

```shell
✓ format    0.4s
✓ analyze   2.3s
✓ test     11.7s
  total    14.4s
```

A row's mark is the result `--report` writes for the task: `✓` passed, `✗`
failed — with the code it failed with — `⊘` skipped, and for one that did not
run because the run stopped, `⏹` where it had begun and `·` where it had not.
Every task gets its row, a lone failure too: the row is also its time.

`--keep-going` is for the local loop. A gate that stops at the first failure
makes you fix, rerun, fix, rerun — the same argument `--validate` is built on,
which is why it collects every problem rather than throwing at the first. With
the flag, independent tasks still run, and the rows say what broke and what
did not run because of it — the members of an `each:` under their task, where
there is more than one:

```shell
✓ format                 0.4s
✓ analyze                2.3s
✗ test                  11.9s
  ✓ packages/xtask       9.6s
  ✗ packages/xtask_kit   2.3s  exit 1
⊘ publishable                  needs `test`, which did not pass
  total                 14.6s
```

A task whose requirement failed does **not** run: its own failure would be a
consequence of the first one. It is named as skipped rather than dropped,
because a task that silently did not happen reads exactly like one that passed.

It is off by default, because a pipeline wants the earliest possible red
rather than a broken run read to the end.

`-j <n>` runs tasks that do not depend on each other at once — and the members
of one `each:` at once. `-j auto` is this machine's processors, capped at 8,
because one unit here is a whole `dart test` or `dart analyze` rather than a
thread; `-j N` is the number you write. It is **not** the default, and the
reason is a real cost rather than caution: normally a task's output passes
through as it arrives and each task is a section that folds, and two tasks
writing to one terminal at once break both — the transcript belongs to neither.
So a parallel run collects each task's output and prints it whole when that
task ends. You get the answer sooner and you watch it happen less — and it says
so on the first line, because a run that goes quiet for eight seconds without
explaining itself is indistinguishable from one that has hung.

The summary then says both numbers, because they answer different questions:

```shell
✓ lint   1.0s
✓ unit   1.0s
✓ types  1.0s
  total  3.1s spent, 1.1s taken
```

A fanned-out task's row says the same of its members: how long you waited,
then `9.0s over 4 members` — the work they added up to.

Declaration order still decides which of the ready tasks starts first — cheap
gates before slow ones — but nothing makes them finish in that order. A failure
stops what has not started; it does not reach into what is running, because
killing a task would leave whatever it was half-way through in whatever state
that half is. Whichever way it ran, the summary then names what did not run:

```shell
✗ format       0.4s  exit 1
· analyze            the run stopped at an earlier failure
⊘ publishable        needs `format`, which did not pass
```

`interruptible: true` gives back some of what `-j` costs. A run does not reach
into what is already running, because a build killed half-way leaves whatever
it was doing in whatever state that half is. That is right for a build and
wrong for a check: `dart format --output=none`, `dart analyze` and
`dart test` write nothing a half-run would
leave behind, and the engine cannot tell the two apart while the person who
wrote the task can. Sequentially a format failure at 0.4s means the rest never
run; in parallel they run to the end anyway and the machine spends the whole
budget to learn what it knew in a tenth of a second. With the key, the fast
answer arrives at the fast answer's price. `--keep-going` stops nothing at all,
which is the whole of what that flag says.

`-j` says **how many**; the file says **whether**. `serial: true` is one task
whose members must not overlap — six packages sharing one `~/.pub-cache`, or
one git index, where `git add` fails outright rather than waiting.
`exclusive: [chromedriver]` is the same fact between tasks: two suites the
graph calls independent may still drive the one browser on the machine — and
because the token is held by the task, a task that holds one runs its own
`each:` members one at a time as well. Naming a browser and then driving it
from four members at once would be the guarantee said and not kept. Both
can only ever make a run slower, never change its result, which is the right
property for something every machine reads — and getting them wrong makes a
run **flaky**, which is a different kind of wrong from making it slow. A number
would be one machine's width written into a file the rest of them share, so
there is no key for it.

`alone: true` is the same fact about the whole machine. A benchmark shares
nothing nameable with what it must not overlap — it shares the CPU — and the
way to say that with tokens was to list every task of the gate in its
`needs:`, so the next task added to the gate ran beside it. Under `-j` the run
waits for what it has started to end, runs the task, and starts nothing else
until it has ended; its `each:` members run one at a time, and its output is
shown as it arrives, because nothing can write beside it. Once it is ready and
waiting, nothing else starts — not a task behind it in the plan, and not one
ahead of it that becomes ready later — or a steady supply of them would keep it
waiting.

### Colour, and ASCII

On a terminal the lines a person reads are drawn in colour: in the summary
`✓` green, `✗` and the code a task failed with red, `⊘` and `⏹` yellow, `·`,
the times and the reasons faint; a task's heading `── name ──` bold, because a
body's own output is never coloured and the heading is the line that says
where the next task begins; `--graph`'s `⊘` yellow and what it says beside a
task faint. Names are never coloured — they are what you copy into the next
command.

Whether there is colour is decided once, about stdout, in this order:

1. The legacy Windows console below: no colour, whatever is set — it would
   print each escape as text.
2. `NO_COLOR` set to anything but the empty string: no colour.
3. `FORCE_COLOR` set to `0` or `false`: no colour, on a terminal too. Set to
   anything else but the empty string: colour, into a pipe or a file too — a
   CI log that renders escapes, or `less -R`. This is how Node's tools read
   it; empty is unset.
4. Otherwise colour exactly when stdout is a terminal that draws ANSI escapes:
   on Linux and macOS, a terminal whose `TERM` is set and is not `dumb`; on
   Windows, a console with virtual terminal processing, Windows Terminal
   among them.

So **a pipe or a file gets, byte for byte, what it always got**. And what a
program reads is never coloured, whatever the variables say: `--report`,
`--names`, `--gate-members`, `--check-ci`, `--emit-schema`, and GitHub's
`::group::`, `::error::` and `::add-mask::` lines. A `secret-env:` value is
masked in a coloured line as in a plain one: colour goes around a whole
fragment, never through one.

On a Windows console that draws no ANSI escapes — the legacy console, whose
fonts have no `✓` or `├` — the glyphs are ASCII instead, marks and branches
together: `ok`, `FAIL`, `skip`, `stop` and `-` for the marks, `+-`, `` `- ``
and `|` for the tree, `--` around a heading and `x` before a member count,
and a member's row still begins under its task's name. Nowhere else: a POSIX terminal with no escapes (`TERM=dumb`) still draws
UTF-8, and a pipe on any platform is a file, whose bytes do not change.

### A run as JSON

What a person reads at the end of a run, a program has had to parse — and a
column laid out for eyes is a format nobody promised to keep.
`--report <file>` writes the run as JSON instead, beside the output and not in
place of it:

```shell
xtask publish --keep-going --report out/run.json
```

```json
{
  "version": 1,
  "task": "publish",
  "complete": true,
  "code": 1,
  "seconds": 0.127,
  "tasks": [
    {
      "task": "test",
      "result": "failed",
      "seconds": 0.118,
      "code": 1,
      "why": "task `test` at `packages/cli` failed with exit code 1\n  run  …",
      "members": [
        {"member": "packages/cli", "result": "failed", "seconds": 0.041, "code": 1, "why": "…"},
        {"member": "packages/core", "result": "passed", "seconds": 0.015},
        {"member": "packages/web", "result": "passed", "seconds": 0.014}
      ]
    },
    {"task": "publish", "result": "skipped", "why": "needs `test`, which did not pass"}
  ]
}
```

| field | what it says |
| --- | --- |
| `version` | the shape, `1`. Raised when a field changes meaning or goes away, not when one is added — pass over a field you do not know |
| `task` | the task or gate set the run was asked for; absent where a refused command line named none |
| `complete` | whether the run got to its end. `false` in a report written while it runs, and in one a run cut off left behind |
| `code` | what the run answered, from the [exit code table](#exit-codes); only when `complete` |
| `seconds` | how long the run took, to the millisecond; absent when it never began |
| `why` | what refused the run, as it was printed — a file that would not parse, a task that is not there, a file found wrong part-way |
| `tasks` | every task of the plan, in the plan's order; empty when the run was refused before it had one |

Each task, and under `members` each member of an `each:` in the set's order:

| field | what it says |
| --- | --- |
| `task`, `member` | the task's name, or the member's |
| `result` | `passed`, `failed`, `skipped` — it never started, because what it needs or follows did not pass, or because its `platforms:` leave this machine out — or `not-run`: the run stopped before it, or part-way through it |
| `seconds` | how long it ran; absent where it never started, and for the member of an `each:` of one |
| `code` | for a failure, the code the table gives it: a `run:` body is `1` whatever its program exited with, and that number is in `why` |
| `why` | where it did not pass, what the run said: the failure as printed, or why it did not run |
| `members` | for an `each:` task, its members — the ones never begun too, as `not-run` |

A task that changed its `unchanged:` set is `failed` with every member
`passed`: its body did its job, and what it left is what failed.

The path is read against where you run the command, as `--check-schema`'s is,
and its directory is made. It is written before anything else is looked at —
so a run refused before a task began still leaves one, saying why — then each
time a task begins or ends, and last with the code. A command line refused
outright — `-j 0`, an option `xtask` has not got, `--report` beside a mode
that runs nothing — still writes the report it asked for, `complete` with the
`2` and the problem as `why`: left alone, the file would be the last run's,
read as this one's answer. A `--report` after `--` is a task's argument and
is not looked for. A file that cannot be
written there is a `2` before anything runs: a report asked for and missing
reads, to whatever waits for it, as a run that never happened. Each write
replaces the file whole, so it is never read half-written.

**On Ctrl-C or a `SIGTERM`** the run stops what it started and then ends, so
its last report is a whole one: `complete` is `true`, `code` is `130` or
`143`, and the task that was running says `stopped part-way: the run received
SIGINT`. A run that cannot do that — killed with `SIGKILL`, or on a machine
going down — leaves the last report it wrote: `complete` is `false`, and the
task running says `the run ended while it was running`.

## Exit codes

An exit code is not a success flag; it is the shortest possible bug report.

| code | meaning |
| --- | --- |
| `0` | everything asked for ran and passed |
| `1` | a task ran and failed |
| `2` | the request was refused — a bad document, an unknown key, a cycle, a dangling reference, a set that expands to nothing; and a command line the parser turns down, or a `--check-ci` that found something |
| `3` | a task's executable was not found — or, for a run handed to the project's entry point, `dart` |
| `4` | a task's body succeeded and one of its `then:` continuations failed |
| `128`+N | the run was stopped by signal N — `130` for Ctrl-C, `143` for `SIGTERM` |

A run handed to the project's own entry point answers with that run's code.
Before it starts, the installed `xtask` adds two of its own: `1` where the
`dart pub get` it runs to resolve the entry point's package fails, and `2`
for a hand-over loop or a command line a batch-file `dart` cannot carry.
After it starts, an entry point that does not compile answers what `dart run`
does — `254` or `255` — passed through as it is.

A `4` stops the run exactly as a `1` does: what has not started does not
start, what is running is left alone, and the summary names the rest. The code
says which of the three endings happened, not how much of the plan was
abandoned — those are different questions and `--keep-going` is the one that
answers the second.

What a `4` prints names the two tasks — `` `publish` finished, and `announce`
failing after it does not undo that `` — and nothing about what they were. The
engine knows which body finished and which `then:` failed after it; whether
the first was an upload, a deploy or a build is the project's to say.

A verb may answer `4` itself, when its own body has an irreversible half and a
check after it — an upload, then a wait until the registry serves what was
uploaded. The engine reduces that `4` as it does a continuation's: alone it is
the run's answer, and beside an ordinary failure the ordinary failure wins.

With `--keep-going` and more than one failure, the code is the **first**
failure's. A code is a report about one failure, and a run with three cannot
honestly claim to be about all of them; the summary is where the others are.

`3` is separate because "Dart is not installed on this machine" and "the code is
broken" are repaired by different people, and one code sends both to the same
one.

A **verb**'s exit code is what the run answers with — it is your Dart, written
against this table, whose constants the package exports as `ExitCode` so a
verb can name the reason rather than the digit; and the built-in `remove`
answers `2` for a path outside the repository because that means *the file is
wrong*. A program started by `run:`
has never heard of this table, so its code goes in the message and the run
answers `1`.

`4` exists because a publish followed by a verification has **three** endings,
not two: nothing was published, everything passed, or the upload happened and
the check after it is red. Collapsing the third into `1` tells a pipeline the
publish failed, which is false and unrecoverable in the wrong direction — the
registry will not accept that version again.

### Ctrl-C, and SIGTERM

A run that is told to stop stops what it started before it stops itself. It
used not to: a `SIGTERM` from CI cancelling a job, or a Ctrl-C, ended the
engine where it stood, and the `dart test` it had started — and the
`flutter_tester` under that — went on running with nobody waiting for them,
holding the machine and its ports until somebody found them by hand.

So the engine catches `SIGINT` and `SIGTERM` for as long as a run lasts. It
starts nothing more; every process it started — a `run:` body, each member of
an `each:` running under `-j`, a program a verb started — is sent `SIGTERM`,
given the same moment as a `timeout:` to write what it has, and then
`SIGKILL`. A body that ends on the Ctrl-C itself, which the terminal sends to
it as well, is reported as stopped and not as failed. The run then answers
`128` and the signal, the number a shell gives a command killed by one, and
writes its summary and its last `--report` on the way out.

A `do:` verb is the exception, as it is for `timeout:`: it is Dart, and
nothing outside it can stop it. It is waited for. A program it started is
stopped under it, and one it asks for after the signal is not started at all
— `run` answers `130` without starting it, and so do `capture` and `tee` — so
a verb that hands those codes back ends promptly. One that ignores them and
goes on working delays the run's end by as long as it works.

What none of this reaches is a process's own children, for `timeout:`'s
reason: the engine stops what it started, and a body that starts a server is
the body's to stop. On Windows there is no `SIGTERM` to catch; Ctrl-C is
handled the same way, and a process is ended at once rather than asked.

## The keys

| key | meaning |
| --- | --- |
| `desc` | required, one line, what `--list` prints |
| `run` | an external program as **argv** — the program, then its arguments, each its own entry. Never a command line; nothing splits a string and no shell sees it |
| `do` | a verb: `remove`, or one this project registered |
| `args` | extra arguments appended to the body |
| `all` | a set whose members replace the `$all` marker, in one invocation — a whole argument, written once |
| `each` | a set whose members the body runs once per, with `$each` standing for the member |
| `in` | where the body runs, relative to the root — may end with `$each` |
| `env` | environment for this task only |
| `env-required` | variables that must already be set, checked before the body runs |
| `env-unset` | variables the body must not see — removed, not emptied |
| `env-paths` | variables whose values are paths from the root — the body gets them absolute |
| `needs` | direct requirements, run before this task, once per invocation |
| `then` | continuations, run **after** this task's body |
| `gate` | the gate sets this task belongs to |
| `serial` | this task's `each:` members must not overlap, whatever `-j` says |
| `exclusive` | tokens this task holds alone while it runs — which makes its own `each:` members serial too |
| `alone` | nothing else runs while this task does, whatever `-j` says |
| `interruptible` | a failure elsewhere may stop this task where it stands |
| `platforms` | the operating systems this task is for — `linux`, `macos`, `windows`; elsewhere it is skipped, and what needs it goes on |
| `timeout` | seconds a `run:` body may take before it is killed — per member under `each:` |
| `unchanged` | a set of paths whose files this task must leave as the run found them — compared byte for byte |

`timeout:` is asked of the process, not waited out by the engine: the body is
sent SIGTERM, given a moment to write what it has, and then SIGKILL. What it
does **not** do is reach the process's own children — Windows has job objects,
POSIX has process groups, and neither is what Dart exposes — so a task that
spawns a server and hangs may leave the server behind. A `do:` cannot carry a
`timeout:` at all: a verb is a Dart function, nothing outside it can stop one,
and a limit that passed while the verb kept writing to disk would be worse than
none. That is refused when the file is read, not discovered at runtime.

### Paths

Every path the file writes — a set's member, an `in:` — is relative to the
repository root, the directory holding `xtask.yaml`. What a body is handed is
read from where it runs: a `run:` program written with a separator, and a
`remove` argument, are looked for under the task's `in:`. A verb is given both
directories, absolute: `context.root`, and `context.workingDirectory` for the
`in:`. A path is refused if it is absolute or climbs through `..` — even one
that would come back inside, because whether it does is a computation over the
string, and the file does not compute.

### What else is refused

Beyond each key's own shape, two kinds of task are refused whenever the file
is read — by every command, a run included — because the task contradicts
itself: `all:` with `each:`, and `timeout:` or `interruptible: true` without a
`run:` body.

More are `--validate`'s, since they are about the file as a whole rather
than one task's keys, and a run does not stop for them: `serial:` without
`each:`, which leaves nothing to keep in order; an `exclusive:` token that one
task without an `each:` holds and no other asks for, which keeps nothing apart;
a task with no body, no `needs:` and no `then:`, which does nothing when
run; and `alone:` beside `exclusive:`, `serial:` or `interruptible:`, or on a
task with no body — each of those keys keeps apart, orders or stops what
running alone already leaves out. Put `--validate` in the gate a person runs
to have them caught.

`unchanged:` naming a set the file has not got, or a `values:` set — whose
members are not files there is anything to compare — is refused by `--validate`
and by `--dry-run`, and by a run before any of its tasks starts, the task's own
`needs:` included: a gate that cannot compare must not run the generator and
say nothing.

### Platforms

Some steps make sense on one operating system only — installing a Linux
desktop entry, signing a macOS bundle. `platforms:` says which:

```yaml
tasks:
  install-desktop:
    desc: install the .desktop file and the icon
    platforms: [linux]
    do: linux-app-install
  smoke:
    desc: start the installed app once
    needs: [install-desktop]
    run: [tool/smoke]
```

On any other machine the task does not run, and is not said to have passed:
the summary prints `⊘ install-desktop  linux only`, `--report` writes
it as `skipped` with that `why`, and `--dry-run` prints the same line in its
place without resolving its body — a program or a variable the run would not
look for is not missing. The names are exactly `linux`, `macos` and `windows`;
any other, an empty list, or one written twice is refused when the file is
read, because each would be a task no machine runs and every run green about
it.

**What needs it, or follows it by `then:`, runs as though it had passed.**
`smoke` above runs on macOS too. Being for another platform is the project's
decision about the task, not something that went wrong, and a dependent is not
to be stopped for a decision that was made on purpose. That is why the key is
in the file: a verb deciding it inside, silently succeeding elsewhere or
refusing elsewhere, either reports a green that is not about this machine or
turns the gate red on a machine the step was never for.

The skip is decided where the task would have begun, and not before: what it
needs still runs first, and if that fails, the task — and what needs it — is
skipped for that failure, as any other would be. A task being for Linux says
nothing about the ones it needs.

`--check-ci` counts a task as reached by the plan, whatever OS the job runs
on: which machine a job is on is the host's to decide, and a task skipped
there is one the file chose to skip, not one a job forgot.

### Secrets

The engine prints values. `--dry-run` prints each task's argv and its `env:`,
a failure prints the line that reproduces it, an annotation on GitHub carries
that line, a refusal quotes what was typed, and `--report` writes all of it
to a file. A signing key handed to a release through `env:` or after `--`
would be in every one of those places, so the file can name the variables
whose values must not be:

```yaml
version: 1
secret-env: [SIGNING_KEY, PUB_TOKEN]
```

Their values are printed as `***` in everything the engine itself writes.
The values are the ones this run has: what the machine holds under the name,
and what any task's `env:` or `env-paths:` sets it to — the latter as the
absolute path the body is given. The key is at the top level and not on
a task, because the output is one stream: a token one task declared and
another printed is printed all the same, and a list per task would hide it in
the lines of the task that remembered to say so. A task's `env-unset:` keeps
the variable from that body, and the value stays a secret wherever else it
turns up. A secret's `env:` or `env-paths:` value cannot be made from `$each`, because a
member is a name every line about the task prints.

On GitHub Actions, a run or a dry run first writes `::add-mask::` for each
value, before any other line, so that GitHub hides them in the rest of the
job's log as well. Not ahead of `--gate-members` or `--names`: those are
answers a program reads, and they print names, not values.

A value shorter than four characters is not masked, here or on GitHub. A
mask replaces every occurrence, and a secret of one to three characters is a
word, a number or a flag; masking it would put `***` into counts, paths and
sentences across the whole log, while hiding nothing that could not be
guessed anyway.

**What a body prints is not filtered.** A program started by a task writes to
the terminal itself unless something collects its output, so the engine never
sees most of what a body says. Filtering the part it does see — output
collected under `-j`, what a verb logs — would make what is hidden depend on
how many tasks ran at once, which is worse than a rule that is easy to state.
On GitHub the `::add-mask::` lines cover a body's output, because GitHub
masks the log and not the engine. Anywhere else, a body that prints its own
secret has printed it.

### A fuller example

The example at the top uses three keys because three is what that repository
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
    all: packages
    args: [$all]
```

`each:` runs the body once per member — in the order the set gives them, and
one at a time unless `-j` says otherwise. `$each` is that member,
and it may stand as a whole argument or **end** one — `packages/$each`,
`--flavor=$each` — with nothing after it. That line is the same line twice: a
prefix lets a set hold the part a path cannot be derived from, the bare name,
so one task can have both `in: packages/$each` and `--name $each`; and no
suffix is what keeps `build/$each.dart` out, because deriving a path from a
value is a computation, a computation wants a modifier, and a modifier wants a
language. Deriving belongs in a verb. `needs:` is "before, and once however
many tasks ask for it"; `then:` is "after, and only if the body worked" —
which is the whole reason exit code `4` exists, because `publish` succeeding
and `announce` failing is a third ending and not a failure to publish.
`env-required:` is checked before that task's body runs — not at the start of
the run — so a missing token is a sentence rather than a broken upload.
`env-unset:` is the other direction: variables this machine has that the body
must not, such as the `CI` a test runner changes its behaviour for, or a
`PUB_HOSTED_URL` that points `dart pub` somewhere else. They are removed, not
emptied — `CI=` is still set to a program that asks — and the body is handed
the environment without them, a verb and every program it starts included;
`--dry-run` prints each as `env  unset CI`. On Windows a name is matched
whatever its case, as Windows matches it, so `env-unset: [Path]` removes the
`PATH` the machine has. A name the same task's `env:` sets, or its
`env-required:` demands, is refused when the file is read — the file says both,
and a required variable the body is then kept from passes the check and
reaches nothing. Names are compared without case on every host, because a file
that validated here and contradicted itself on the Windows runner would be the
one checked in; for that reason one variable written in two cases within one
`env:` or `env-unset:` — `Path` and `PATH` — is refused too, which Windows
would hand the body as two.

`env-paths:` is for the value that is a path in the repository — a cache, a
config, a binary a task built:

```yaml
tasks:
  hooks:
    desc: Run the hook suite against the built tool
    in: packages/hooks
    env-paths:
      TOOL_BIN: packages/cli/build/bundle/bin/tool
      PUB_CACHE: .dart_tool/pub-cache
    run: [bash, hooks/run.sh]
```

Written in `env:`, `packages/cli/build/…` is text, and the program reads it
from wherever it runs: from `packages/hooks` here, from wherever a script
`cd`s next. In `env-paths:` it is a path from the root, as `in:` is, and the
body is handed the root joined to it — absolute, normalised (`./a//b/` is
`a/b`), and in this machine's separators, so on Windows it is
`C:\repo\packages\cli\…`. `--dry-run` prints the value the body gets,
`env  TOOL_BIN=/home/you/repo/packages/…`. Its own key rather than a guess about
which `env:` values look like paths, and no `${root}` to write inside a
string: a value is a path from the root or it is text. Nothing absolute and no
`..` — a path that leaves the root is refused when the file is read, as `in:`
is. `$each` may end one, as it ends `in:` — `build/$each` — and a member of a
`values:` set that takes it out of the root is refused by `--validate` and by
the run. A name the same task's `env:` sets, or its `env-unset:` removes, is
refused, compared without case; so is one name written in two cases within
`env-paths:`, as within `env:`. A name in `secret-env:` is masked in the form
the body gets it. `do:`
names a verb the project wrote in Dart and handed to `runXtask`, and
`all:` hands it the expanded set, wherever `$all` is written.

A set is a list of paths, a glob with exclusions, or `values:` for members that
are not paths at all. The first two are expanded by the engine rather than by a
shell, in a deterministic order:

```yaml
sets:
  packages: [packages/lake, packages/lake_cli]

  sources:
    include: ['{templates,packages}/**/*.lake']
    exclude: ['**/test_data/**']

  flavours:
    values: [dev, staging, prod]
```

`**/` means **none or more** directories, as bash and git read it — so
`packages/**/*.lake` finds `packages/x.lake` too. That is two readings of one
pattern: it with the `**/` kept, and it with the `**/` dropped. A pattern
carrying more than a handful of them is refused rather than matched, because
every reading becomes a glob compared against every file the walk touches. The
readings are counted rather than estimated as `2ⁿ` — they collapse, and
`a/**/**/b` has three and not four — so the limit turns away what is actually
expensive and nothing else.

A glob set can keep only the members that hold something. `containing:` is
a list of paths, read from inside each member the patterns found, and a member
stays only if every one of them is there:

```yaml
sets:
  tested:
    include: [packages/*]
    containing: [test]
```

That is a package with a suite, which is where `dart test` can run — in one
without `test/` it fails rather than finding nothing. The paths are paths, not
patterns, and existence is the whole question: nothing asks what a
`pubspec.yaml` says, because a query over manifests is what a monorepo tool is
(see [what it deliberately is not](#what-it-deliberately-is-not)). A path is
refused if it is absolute or climbs through `..`, since it is about the member
and not its siblings. A link is not followed anywhere along the path, as the
set walk follows none: `link/test` through a link to another tree is not this
member holding it. A set the filter leaves empty is refused like any other,
and the refusal says the patterns matched and the filter took them.

`values:` is a declaration, not decoration. Every other kind of set holds
paths, and the engine treats them as paths — it refuses one that reaches
outside the repository, and it can say a glob matched nothing. Neither
question means anything about `dev`, and asking the first refused `a:b` for
looking like a Windows drive. It is also what lets a set hold the bare name a
path cannot be derived from, with `in: packages/$each` composing the path
around it.

A member a **glob** found that begins with `-` is refused where it would reach
a program's arguments: a file called `-n.dart` is a path to you and an option to
almost everything else. Write `--` before the marker, where a command line says
its operands begin — the engine will not add it for you, because that would
change the argv the task wrote. A member you wrote out yourself is not refused:
you can see it, and a `values:` set holding `-v` is somebody passing a flag on
purpose.

**A set is read when the task that names it is about to run**, and at no other
time — except by `unchanged:`, below, which reads its set twice and says why. `--validate` and `--dry-run` happen before that, so a set the run itself
produces says so:

```yaml
sets:
  generated:
    include: ['build/**/*.dart']
    produced-by: codegen
```

That buys exactly one thing: the **emptiness** of this set is not judged before
`codegen` has run. `--validate` passes over it and `--dry-run` prints `cannot
be resolved yet` with the reason under it, instead of calling a working file
broken. Everything else about the set is still checked by both — a pattern that
leaves the repository, a pattern that is not a pattern — and a run still
refuses it empty, whatever was hoped for it.

The producer is named rather than flagged, because a name is something the
file can be checked against: every task that reads the set has to reach
`codegen` through `needs:`, or `--validate` says so. In the file's order the
producer may well come first anyway; under `-j` nothing but the edge says so,
and a reader that does not need its producer reads a set that is not there
yet.

A set that expands to nothing is an **error**: a task given no files checked
nothing, and a gate that examined nothing is worse than no gate.

A task can say that it leaves a set's files as it found them, which is what a
freshness gate over committed generated code asks:

```yaml
sets:
  generated:
    include: ['lib/l10n/gen/**', 'packages/*/lib/**.g.dart']

tasks:
  codegen:
    desc: regenerate l10n and drift code; fail if that changed a file
    needs: [l10n, build]
    unchanged: generated

  l10n:
    desc: generate the localizations
    run: [flutter, gen-l10n]

  build:
    desc: run the models package's build_runner
    in: packages/models
    run: [dart, run, build_runner, build, --delete-conflicting-outputs]
```

`unchanged:` reads every file the set reaches, byte for byte, and again when
the task has ended; a file whose bytes changed, a file that appeared and a file
that went away each fail the task, which names them — twenty at most, and how
many more. A member that is a directory is every file beneath it, so a set can
name generated trees as well as files. It is not `git status`: it answers the
same in a dirty tree, in one whose fresh output is not committed yet, and in a
directory that is no repository at all. The files are left as the task wrote
them, because the regenerated ones are the fix.

**The first reading is when the run begins**, not when the task is reached and
not when its `needs:` begin. A generation is often several steps, so the task
that holds the set is the one over them; and a `needs:` runs once per
invocation, for whichever branch of the graph reaches it first. In a gate where
`test` needs `build` and comes before `codegen`, `build` has regenerated
everything before `codegen`'s steps would start, and a set read then would
compare the regenerated files with themselves and pass stale code. Before the
run is the one moment before every step of every branch. What that costs: any
task in the run that writes the set before this one ends counts against it —
which is the question being asked, whether the committed files are what this
run leaves behind. A task meant to rewrite them is not one to hold them
unchanged.

`--only` does not narrow it: a generator run for one member can rewrite
another's files. A run that has already given up does not compare, since what
it stopped part-way is not the question; a body that failed has its own
answer. A set that cannot be compared is refused before anything in the run
starts — by `--dry-run` with the same `2` and sentence: one the file has not
got, a `values:` set, one reaching outside the root or written with a pattern
that is no pattern, and one that is empty with no `produced-by:` task to fill
it. A `produced-by:` set may be empty when the run begins; if it still holds
nothing at the end, nothing was compared, and it is refused as an empty set
is. `--dry-run` says
which set a task holds, and when it is read.

## Editor support

`xtask --emit-schema` prints a JSON Schema for the file format. Generate it into
your repository and point at it with a relative path, so a fresh clone needs
neither the network nor a per-person editor setting:

```shell
xtask --emit-schema > xtask.schema.json
```

```yaml
# yaml-language-server: $schema=./xtask.schema.json
version: 1
```

The schema knows the **shape** of the file: it completes a task's keys, and
underlines `dsec:` or a `gate:` written as a string, while you type. Everything
that needs the graph or the filesystem — a cycle, a `needs:` pointing at
nothing, an undeclared or empty gate set, an orphan gate, a glob matching
nothing, an unregistered verb, an `in:` that reaches outside the repository —
is what `--validate` answers. A schema catches a mistyped **key**;
`--validate` catches a mistyped **name**.

The schema describes one version of the engine, which is why it is generated
into your repository rather than fetched from a URL — and why a committed copy
falls behind the day the engine is upgraded. Writing it stays a person's act,
because a redirect is shell; checking it is a gate's:

```yaml
  schema-check:
    desc: fail if xtask.schema.json is not the schema this engine emits
    gate: [check]
    run: [dart, run, ':xtask', --check-schema, xtask.schema.json]
```

The path is read from where the command runs — the root, for a task without
`in:`. Line endings and a trailing newline are not differences.

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
a recipe runs (see what it deliberately is not), and one target's output
captured into another's command line (R1).

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

## Windows

`timeout:` ends a process outright here. There is no signal to ask with first,
so the moment a POSIX process is given to write what it has is not given on
Windows.

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
