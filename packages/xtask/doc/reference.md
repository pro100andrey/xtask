# Reference

For looking something up once the [front page](../README.md) is behind you:
every flag, every key, what a set can be, and what each exit code means.

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
xtask pkg-test --only packages=packages/ui,packages/ui_kit
```

Every `each:` and `all:` in the plan that names the set gets only the members
a pattern matches, in the set's order. A pattern is a glob, read against the
member as text: `packages/ui` keeps that one and not `packages/ui_kit`, and
`packages/ui*` keeps both, as does `packages/{ui,ui_kit}`: a comma inside
braces is the pattern's, not a separator. Written again for the same set, the patterns add
up. `--dry-run` prints the narrowed plan, and the summary says how much of the
set ran — `2 of 17 members` on the task's row. Each of these is a `2` rather than a smaller
run: a set the file has not got, a set nothing in the plan expands, a pattern
that is not one, and a pattern that matches no member — the last when the set
is read, since that is when its members are known. `--check-ci` reports a step
that narrows a gate set: the job reads as the gate, and runs part of it.

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

### A fuller example

The example on the [front page](../README.md#start-here) uses three keys
because three is what that repository needs. Here is one using the rest — a
release, which is where `needs:`, `then:` and a verb all earn their keep at
once:

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
`env-paths:`, as within `env:`. A name in
[`secret-env:`](internals-and-platforms.md#secrets) is masked in the form the
body gets it. `do:` names a verb the project wrote in Dart and handed to
`runXtask`, and `all:` hands it the expanded set, wherever `$all` is written.

A set is a list of paths, a glob with exclusions, or `values:` for members that
are not paths at all. The first two are expanded by the engine rather than by a
shell, in a deterministic order:

```yaml
sets:
  packages: [packages/core, packages/core_cli]

  sources:
    include: ['{templates,packages}/**/*.proto']
    exclude: ['**/test_data/**']

  flavours:
    values: [dev, staging, prod]
```

`**/` means **none or more** directories, as bash and git read it — so
`packages/**/*.proto` finds `packages/x.proto` too. That is two readings of one
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
(see [what it deliberately is not](../README.md#what-it-deliberately-is-not)).
A path is refused if it is absolute or climbs through `..`, since it is about
the member and not its siblings. A link is not followed anywhere along the path, as the
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
