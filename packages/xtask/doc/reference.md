# Reference

For looking something up once the [front page](../README.md) is behind you.
Every key and every flag has a section, and each section has the same shape:
what it does, a whole file that shows it, what is refused and with which exit
code, and, where it is not obvious, why. [A fuller example](#a-fuller-example)
at the end puts most of the keys into one file.

## The keys

Every key the file may hold. A name is a link to its section.

| key | where | what it is |
| --- | --- | --- |
| [`version`](#version) | top level | required; `1` |
| [`entry`](#entry) | top level | the project's entry point, where it is not `bin/xtask.dart` |
| [`gates`](#gates) | top level | the gate sets the file has |
| [`sets`](#sets) | top level | named lists of paths or values |
| [`secret-env`](#secret-env) | top level | variables whose values are printed as `***` |
| [`tasks`](#tasks) | top level | the tasks, in the order a gate set runs them |
| [a list](#a-list-of-paths) | a set | members written out |
| [`include`, `exclude`](#include-and-exclude) | a glob set | patterns the members are found by |
| [`containing`](#containing) | a glob set | keep only the members that hold these paths |
| [`produced-by`](#produced-by) | a glob set | the task that makes the members |
| [`values`](#values) | a value set | members that are not paths |
| [`desc`](#desc) | a task | required, one line, what `--list` prints |
| [`run`](#run) | a task | a program as argv |
| [`do`](#do) | a task | a verb: `remove`, or one the project registered |
| [`args`](#args) | a task | arguments appended to the body |
| [`all`](#all) | a task | a set whose members replace `$all`, in one invocation |
| [`each`](#each) | a task | a set the body runs once per member of, as `$each` |
| [`in`](#in) | a task | where the body runs, from the root |
| [`env`](#env) | a task | environment for this task only |
| [`env-required`](#env-required) | a task | variables that must be set before the body runs |
| [`env-unset`](#env-unset) | a task | variables the body must not see |
| [`env-paths`](#env-paths) | a task | variables whose values are paths from the root |
| [`needs`](#needs) | a task | tasks that run before this one |
| [`then`](#then) | a task | tasks that run after this one's body worked |
| [`gate`](#gate) | a task | the gate sets this task is in |
| [`serial`](#serial) | a task | its `each:` members must not overlap |
| [`exclusive`](#exclusive) | a task | tokens it holds alone while it runs |
| [`alone`](#alone) | a task | nothing else runs while it does |
| [`interruptible`](#interruptible) | a task | a failure elsewhere may stop it where it stands |
| [`platforms`](#platforms) | a task | the operating systems it is for |
| [`timeout`](#timeout) | a task | seconds a `run:` body may take |
| [`unchanged`](#unchanged) | a task | a set whose files it must leave as it found them |

Any other key is refused when the file is read, with `2`, and the refusal
lists the keys that would have been accepted. The flags are under
[The command](#the-command).

## When the file is checked

Every refusal answers `2`. What differs is when it is found:

- **When the file is read**, by every command, a run included: the shape of a
  key, an unknown key, and a task whose own keys contradict each other.
- **By `--validate`**: everything about the file as a whole — names that point
  at nothing, a cycle, an undeclared gate set, a key that does nothing. Some of
  these a run finds too, when it reaches them; some it does not stop for. Put
  `--validate` in the gate a person runs to have them all caught.
- **By the run**, before the body starts: a set that matches nothing, a path
  that leaves the repository through a link, a program that is not installed
  (that one is `3`).

Each section below says which of these refuses what.

## Paths

Every path the file writes is relative to the repository root, the directory
that holds `xtask.yaml`: a set's member, an `in:`, an `env-paths:` value,
`entry:`. A path is refused if it is absolute or climbs through `..`, even one
that would come back inside. Whether it comes back is a computation over the
string, and the file does not compute.

What a body is handed is read from where it runs. A `run:` program written with
a separator, and a `remove` argument, are looked for under the task's `in:`. A
verb is given both directories, absolute: `context.root`, and
`context.workingDirectory` for the `in:`.

## The top level

### `version`

Says which format the file is written in. Required, and the only value is `1`.

```yaml
version: 1

tasks:
  test:
    desc: run the suite
    run: [pytest, -q]
```

Refused when the file is read: a file without it, a value that is not a whole
number, and any number but `1`. It is checked before any other key, because a
key this engine does not know may be an ordinary key of the version the file
declares. An engine that guessed the dialect would read the next one wrong.

### `entry`

Names the project's entry point when it is not `bin/xtask.dart`. The installed
`xtask` hands a run to that file; [Dart verbs](dart-verbs.md#your-own-entry-point)
says how.

```yaml
version: 1
entry: tools/bin/xtask.dart

tasks:
  regen:
    desc: regenerate the protos
    do: regen
```

Refused when the file is read: an empty value, a path that leaves the root, a
path written with `\`, and a file that does not end in `.dart`. Refused by
`--validate`: a file that is not there, and one with no `pubspec.yaml` at or
above it inside the root.

### `gates`

Declares the gate sets, the groups a person or a CI job runs by name. A task
joins one with [`gate:`](#gate). `xtask check` runs the members of `check` in
the order the file writes them.

```yaml
version: 1

gates: [check, release]

tasks:
  test:
    desc: run the suite
    gate: [check]
    run: [pytest, -q]

  publish:
    desc: upload the package
    gate: [release]
    needs: [test]
    run: [uv, publish]
```

Refused when the file is read: a value that is not a list, an empty list, an
empty name, and a name written twice. Refused by `--validate`: a gate set no
task is in, and a gate set with the same name as a task. A gate set has no
description and no body; it is the name of whoever runs a list.
[Gate sets, and CI](ci-integration.md) says why the declaration exists: a gate
set that came into being by being mentioned could not be misspelled.

### `sets`

Names lists that tasks expand with [`all:`](#all), [`each:`](#each) or
[`unchanged:`](#unchanged). A set is one of three kinds, each described under
[What a set can be](#what-a-set-can-be).

```yaml
version: 1

sets:
  packages: [packages/core, packages/cli]

  sources:
    include: ['{templates,packages}/**/*.proto']
    exclude: ['**/test_data/**']

  flavours:
    values: [dev, staging, prod]

tasks:
  get:
    desc: resolve each package
    each: packages
    in: $each
    run: [dart, pub, get]
```

Refused when the file is read: anything that is not one of the three kinds,
and an empty name.

### `secret-env`

Names variables whose values the engine prints as `***`, in everything it
writes: `--dry-run`, a failure's reproduction line, `--report`, GitHub's
annotations.

```yaml
version: 1
secret-env: [GH_TOKEN]

tasks:
  upload:
    desc: attach the files after -- to a GitHub release
    env-required: [GH_TOKEN]
    run: [gh, release, upload]
```

Refused when the file is read: a value that is not a list, an empty name, and
a name with `=` in it. A secret's `env:` or `env-paths:` value made from
`$each` is refused too, because every line about a task prints its member. On
GitHub Actions each value is also handed to `::add-mask::`. What a body prints
itself is not filtered, and a value under four characters is not masked;
[Secrets](internals-and-platforms.md#secrets) says why.

### `tasks`

The tasks, each under its name. The order they are written in is the order a
gate set runs them, so cheap checks go first.

```yaml
version: 1

tasks:
  format:
    desc: fail if a file is unformatted
    run: [ruff, format, --check, .]

  test:
    desc: run the suite
    run: [pytest, -q]
```

Refused when the file is read: an empty name, and one that runs past a line.
Refused by `--validate`: a task with no body, no `needs:` and no `then:`,
since running it does nothing.

## What a set can be

### A list of paths

Members written out, in the order written.

```yaml
version: 1

sets:
  apps: [apps/web, apps/admin]

tasks:
  build:
    desc: build each app
    each: apps
    in: $each
    run: [npm, run, build]
```

Refused when the file is read: an empty list. Refused by the run, and by
`--validate` where it reads the disk: a member that leaves the root.

### `include` and `exclude`

A glob set: the files and directories that `include:` patterns match and no
`exclude:` pattern does, found by the engine and not by a shell, in a sorted
order that is the same on every machine.

```yaml
version: 1

sets:
  docs:
    include: ['docs/**/*.md']
    exclude: ['docs/drafts/**']

tasks:
  docs-format:
    desc: check the formatting of every page
    all: docs
    run: [prettier, --check, $all]
```

Patterns are read as POSIX on every host. `**/` means **none or more**
directories, as bash and git read it, so `packages/**/*.proto` finds
`packages/x.proto` too. A pattern with more than 32 such readings is refused
rather than matched, because each reading is compared against every file the
walk touches. A link is not followed.

Refused when the file is read: a glob set without `include:`, an empty
`include:`, and a key other than these four. Refused by the run, and by
`--validate` where it reads the disk: a pattern that leaves the root, a pattern
that is not a valid glob, and a directory the walk cannot list.

### `containing`

Keeps only the members of a glob set that hold every path listed. The paths
are read from inside each member.

```yaml
version: 1

sets:
  tested:
    include: [packages/*]
    containing: [test]

tasks:
  test:
    desc: run each package's suite
    each: tested
    in: $each
    run: [dart, test]
```

That is the packages with a suite: `dart test` in a package without `test/`
fails rather than finding nothing.

Refused when the file is read: an empty list. Refused by the run and by
`--validate`: a path that is absolute or climbs through `..`, and an empty path
or `.`, which every member holds. A set the filter leaves empty is refused like
any other empty set, and the refusal says the patterns matched and the filter
took them.

Why only existence: nothing asks what a `pubspec.yaml` says, because a query
over manifests is what a monorepo tool is (see
[what it deliberately is not](../README.md#what-it-deliberately-is-not)). A
link is not followed anywhere along the path.

### `produced-by`

Names the task that makes a glob set's members, so that the set is not judged
empty before that task has run.

```yaml
version: 1

sets:
  generated:
    include: ['build/gen/**/*.dart']
    produced-by: codegen

tasks:
  codegen:
    desc: generate the sources
    run: [dart, run, tool/gen.dart]

  analyze-generated:
    desc: analyze what codegen wrote
    needs: [codegen]
    all: generated
    run: [dart, analyze, $all]
```

`--validate` passes over the set's emptiness, and `--dry-run` prints `cannot be
resolved yet` with the reason under it. Everything else about the set is still
checked, and a run still refuses it if it is empty when it is read.

Refused when the file is read: an empty name. Refused by `--validate`: a
producer that is not a task, a task that reads the set and is its producer, and
a reader that does not reach the producer through `needs:`. A name rather than
a flag, so that the edge can be checked: under `-j` nothing but the edge makes
the producer run first.

### `values`

Members that are not paths: flavours, SDK versions, platform names.

```yaml
version: 1

sets:
  flavours:
    values: [dev, staging, prod]

tasks:
  build:
    desc: build the app once per flavour
    each: flavours
    run: [flutter, build, apk, --flavor=$each]
```

Refused when the file is read: an empty list, and any other key beside
`values:`. A value set is not asked whether its members stay in the
repository, or whether a glob matched them, because neither question means
anything about `dev`. Where a member is composed into a path — `in:
packages/$each`, an `env-paths:` value, a `remove` argument — the composed path
is checked by `--validate` and by the run.

### What every set is held to

**A set that expands to nothing is refused** with `2`, by the run and by
`--validate`. A task given no files checked nothing, and a gate that examined
nothing is worse than no gate.

**A set is read when the task that names it is about to run**, and at no other
time, except by [`unchanged:`](#unchanged), which reads its set twice.

**A member a glob found that begins with `-` is refused** where it would reach
a program's arguments, by the run and by `--validate`. A file called `-n.dart`
is a path to you and an option to almost every program. Write `--` before the
marker, where a command line says its operands begin. The engine will not add
it for you, because that would change the argv the task wrote. A member you
wrote out yourself is not refused: a `values:` set holding `-v` is somebody
passing a flag on purpose.

## Task keys

### `desc`

One line saying what the task is for. Required; it is what `--list` prints
beside the name.

```yaml
version: 1

tasks:
  lint:
    desc: check the style
    run: [ruff, check, .]
```

Refused when the file is read: a task without it, an empty one, and one that
runs past a line.

### `run`

The body as **argv**: the program, then each argument as its own entry. Nothing
splits a string and no shell sees it, so a path with a space in it stays one
argument.

```yaml
version: 1

tasks:
  test:
    desc: run the tests, one file at a time
    run: [dart, test, --concurrency=1]
```

The program is found on `PATH` (with `PATHEXT` on Windows). One written with a
separator, such as `tool/smoke`, is looked for under the task's `in:`. Its exit
code goes into the message and the run answers `1`.

Refused when the file is read: a value that is not a list, an empty list, an
empty program, `$all` or `$each` as the program, and a task with both `run:`
and `do:`. Refused by the run and by `--dry-run`, with `3`: a program that is
not installed.

### `do`

The body as a **verb**: `remove`, the one the engine ships, or a Dart function
the project registered in its [entry point](dart-verbs.md#your-own-entry-point).

```yaml
version: 1

tasks:
  clean:
    desc: delete what the build left
    do: remove
    args: [build, coverage, '**/*.tmp']
```

`remove` deletes each path it is given, directories recursively, and expands
globs among them itself. A path that is not there is not an error. It never
follows a link, and it refuses a path outside the repository with `2`. A verb's
exit code is the run's answer, so a verb can answer from the
[exit code table](#exit-codes) itself.

Refused when the file is read: an empty name, and `timeout:` or
`interruptible:` beside it, since nothing outside a Dart function can stop
one. Refused by `--validate` and by the run: a verb nobody registered. Refused
by every command, with `2`: a project verb registered as `remove`.

### `args`

Arguments appended to the body: after a `run:` argv, or as `context.args` for
a verb.

```yaml
version: 1

tasks:
  bump:
    desc: raise the minor version in every manifest
    do: bump-version
    args: [--minor]
```

Arguments typed after `--` come after these, for the named task only. `$all`
and `$each` may be written here, under the rules of [`all:`](#all) and
[`each:`](#each).

Refused when the file is read: a value that is not a list of strings.

### `all`

Names a set whose members replace `$all`, in one invocation. `$all` is a whole
argument, written once.

```yaml
version: 1

sets:
  scripts:
    include: ['tool/**/*.sh']

tasks:
  shellcheck:
    desc: lint every shell script at once
    all: scripts
    run: [shellcheck, $all]
```

Refused when the file is read: `all:` with no `$all` written, `$all` with no
`all:`, `$all` written twice, `$all` inside a longer argument such as
`--files=$all`, `$all` as the program, in `in:` or in an environment value,
and `all:` beside `each:`. Refused by `--validate` and by the run: a set the
file has not got.

Why a whole argument: `$all` stands for many arguments, and there is no
meaning for many arguments inside one. Splitting a string is a shell's job,
and there is no shell here.

### `each`

Names a set whose members the body runs once per, with `$each` standing for
the member.

```yaml
version: 1

sets:
  packages:
    include: [packages/*]

tasks:
  get:
    desc: resolve each package
    each: packages
    in: $each
    run: [dart, pub, get]
```

Members run in the set's order, one at a time unless `-j` says otherwise.
`$each` may be a whole argument or **end** one, as in `packages/$each` or
`--flavor=$each`, with nothing after it. It may be written in `run:`, `args:`,
`in:`, and the values of `env:` and `env-paths:`.

Refused when the file is read: `each:` with no `$each` written, `$each` with
no `each:`, text after `$each` (`build/$each.dart`), `$each` twice in one
string, `$each` as the program, `$each` in a name (`needs:`, `exclusive:`, an
`env:` key, and the like), and `in: $each` beside `$each` in the arguments.
Refused by `--validate` and by the run: a set the file has not got.

Why nothing may follow it: a prefix lets a set hold the part a path cannot be
derived from, the bare name, so one task can have both `in: packages/$each`
and `--name $each`. A suffix would derive a path from a value. That is a
computation, a computation wants a modifier, and a modifier wants a language.
Deriving belongs in a verb. And `in: $each` says the member is a path from the
root, so the same member in the arguments would be read from two places;
compose the directory instead, `in: packages/$each`, and the member is a name.

### `in`

Where the body runs, as a path from the root. Left out, the body runs at the
root.

```yaml
version: 1

tasks:
  web-test:
    desc: run the web package's suite in Chrome
    in: packages/web
    run: [dart, test, -p, chrome]
```

It may be `$each` or end with it (`packages/$each`). Refused when the file is
read: an empty value, and `$all` in it. Refused by `--validate` and by the run:
a path that is absolute, climbs through `..`, or leaves the root through a
link, including one composed from a `values:` member.

### `env`

Environment variables for this task's body only, on top of what the machine
has.

```yaml
version: 1

tasks:
  test:
    desc: run the suite with a fixed seed
    env:
      RANDOM_SEED: '42'
      LOG_LEVEL: warn
    run: [pytest, -q]
```

A value is text, and an unquoted `1.10` is the number 1.1 to YAML, so a value
that is not a string is refused: quote it. A key rather than syntax, because
`FOO=bar cmd` is shell.

Refused when the file is read: a value that is not a string, a name with `=`,
an empty name, `$all` in a value, one variable written in two cases (`Path` and
`PATH`), a name `env-unset:` removes, and a name `env-paths:` also sets. Names
are compared without case on every host, because Windows reads them that way
and the file is the same file there.

### `env-required`

Variables that must be set, and not empty, before the body runs.

```yaml
version: 1

tasks:
  web-e2e:
    desc: browser tests against the running driver
    env-required: [CHROMEDRIVER]
    run: [dart, test, test/e2e]
```

Checked when the task is reached, not at the start of the run, so a missing
token is a sentence rather than a broken upload: ``task `web-e2e` requires the
environment variable `CHROMEDRIVER`, which is not set``. The task answers `1`.
The engine installs nothing; whatever provides the variable has to run first.

Refused when the file is read: `$each` or `$all` in a name, and a name the same
task's `env-unset:` removes, since the check would pass and the body would get
nothing.

### `env-unset`

Variables the body must not see. They are removed, not emptied: `CI=` is still
set to a program that asks.

```yaml
version: 1

tasks:
  test:
    desc: run the suite as it runs on a laptop
    env-unset: [CI, PUB_HOSTED_URL]
    run: [dart, test]
```

The body, a verb and every program it starts included, gets the environment
without them. `--dry-run` prints each as `env  unset CI`. On Windows a name is
matched whatever its case, so `env-unset: [Path]` removes `PATH`.

Refused when the file is read: a value that is not a list, a name with `=`, a
name written twice or in two cases, and a name the same task's `env:` or
`env-paths:` sets, or its `env-required:` demands.

### `env-paths`

Variables whose values are paths from the root. The body gets each one
absolute, normalised and in this machine's separators.

```yaml
version: 1

tasks:
  hooks:
    desc: run the hook suite against the built tool
    in: packages/hooks
    env-paths:
      TOOL_BIN: packages/cli/build/bundle/bin/tool
      PUB_CACHE: .dart_tool/pub-cache
    run: [bash, hooks/run.sh]
```

Written in `env:`, `packages/cli/build/…` is text, and the program reads it
from wherever it runs: `packages/hooks` here, or wherever a script `cd`s next.
In `env-paths:` it is the root joined to it, so on Windows it is
`C:\repo\packages\cli\…`. `--dry-run` prints the value the body gets. A value
may end with `$each`, as `in:` may. A name in [`secret-env:`](#secret-env) is
masked in the absolute form.

Refused when the file is read: a path that leaves the root, a value that is
not a string, a name `env:` also sets, a name `env-unset:` removes, and one
name in two cases. Refused by `--validate` and by the run: a path composed from
a `values:` member that leaves the root.

Why its own key: guessing which `env:` values look like paths would be the
guessing this file exists to remove, and a `${root}` inside a string would be
interpolation. A value is a path from the root, or it is text.

### `needs`

Tasks that run before this one, once per invocation however many tasks ask for
them.

```yaml
version: 1

tasks:
  build:
    desc: compile the binary
    run: [dart, compile, exe, bin/app.dart, -o, build/app]

  smoke:
    desc: start the binary once
    needs: [build]
    run: [build/app, --version]
```

If a requirement fails, this task does not run, and it is reported as skipped.

Refused when the file is read: an empty name, and a marker in a name. Refused
by `--validate`, and by a run whose plan reaches it: a name that is not a task,
a gate set's name, a cycle, and a chain too deep to walk.

### `then`

Tasks that run **after** this one, and only if its body worked.

```yaml
version: 1

tasks:
  publish:
    desc: publish, then check that the registry serves it
    then: [verify]
    run: [dart, pub, publish, --force]

  verify:
    desc: wait until pub.dev serves the new version
    run: [dart, run, tool/wait_for_release.dart]
```

When the body succeeded and a continuation failed, the run answers `4`, which
means "`publish` finished, and `verify` failing after it does not undo that".

Refused as `needs:` is refused. Why a separate key and a separate code: a
publish followed by a check has three endings, and the third, published but
red, is not a failure to publish. See [Exit codes](#exit-codes).

### `gate`

The gate sets this task is in. Each must be declared in [`gates:`](#gates).

```yaml
version: 1

gates: [check]

tasks:
  lint:
    desc: check the style
    gate: [check]
    run: [ruff, check, .]
```

Refused when the file is read: an empty name, and a marker in a name. Refused
by `--validate`: a gate set `gates:` does not declare, and any `gate:` in a
file that declares none.

### `serial`

Says that this task's `each:` members must not overlap, whatever `-j` says.

```yaml
version: 1

sets:
  packages:
    include: [packages/*]

tasks:
  get:
    desc: resolve each package, one at a time
    each: packages
    in: $each
    serial: true
    run: [dart, pub, get]
```

For members that share one thing: six packages and one `~/.pub-cache`, or one
git index, where `git add` fails outright rather than waiting.

Refused when the file is read: anything but `true` or `false`. Refused by
`--validate`: `serial:` without `each:`, and beside `alone:`. A run does not
stop for either. Why `-j` and this are apart:
[Reading a run](running.md#reading-a-run).

### `exclusive`

Tokens this task holds alone while it runs. Two tasks that name one token never
run at once.

```yaml
version: 1

tasks:
  web-e2e:
    desc: drive the web app in the browser
    exclusive: [chromedriver]
    run: [dart, test, test/web]

  admin-e2e:
    desc: drive the admin app in the browser
    exclusive: [chromedriver]
    run: [dart, test, test/admin]
```

A task that holds a token also runs its own `each:` members one at a time.
Naming a browser and then driving it from four members at once would be the
guarantee said and not kept.

Refused when the file is read: an empty name, and a marker in a name. Refused
by `--validate`: a token one task holds, with no `each:` and no other task
asking for it, which keeps nothing apart; and a token beside `alone:`. A run
does not stop for either.

### `alone`

Says that nothing else runs while this task does, whatever `-j` says.

```yaml
version: 1

tasks:
  bench:
    desc: measure the parser with nothing else on the CPU
    alone: true
    run: [dart, run, benchmark/parse.dart]
```

Under `-j` the run waits for what it has started, runs this task with its
output shown as it arrives, and starts nothing else until it ends. Its `each:`
members run one at a time.

Refused when the file is read: anything but `true` or `false`. Refused by
`--validate`: `alone:` on a task with no body, and beside `exclusive:`,
`serial:` or `interruptible:`, each of which says something running alone
already says. A run does not stop for these.

### `interruptible`

Says a failure elsewhere may stop this task where it stands, under `-j`.

```yaml
version: 1

gates: [check]

tasks:
  format:
    desc: fail if a file is unformatted
    gate: [check]
    interruptible: true
    run: [dart, format, --output=none, --set-exit-if-changed, .]

  test:
    desc: run the suite
    gate: [check]
    interruptible: true
    run: [dart, test]
```

For a check that leaves nothing half-written behind. Without it, a format
failure at 0.4s under `-j` still waits for the tests to finish. The engine
cannot tell a check from a build; the person who wrote the task can.

Refused when the file is read: anything but `true` or `false`, and the key on a
`do:` or on a task with no body. Refused by `--validate`: beside `alone:`.

### `platforms`

The operating systems this task is for: `linux`, `macos`, `windows`. Elsewhere
it is skipped, and what needs it goes on.

```yaml
version: 1

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

On another machine the summary prints `⊘ install-desktop  linux only`,
`--report` writes it as `skipped` with that `why`, and `--dry-run` prints the
same line without resolving its body. **What needs it, or follows it by
`then:`, runs as though it had passed**, so `smoke` runs on macOS too. The skip
is decided where the task would have begun: what it needs still runs first,
and a failure there skips it as any failure would. `--check-ci` counts the task
as reached whatever OS the job runs on.

Refused when the file is read: any other name, an empty list, and a name
written twice. Each would be a task no machine runs, with every run green
about it.

Why a key: being for another platform is the project's decision, not a
failure, and a dependent is not to be stopped for it. A verb that decided it
inside would either report a green that is not about this machine or turn the
gate red on a machine the step was never for.

### `timeout`

Seconds a `run:` body may take. Under `each:` the limit is per member.

```yaml
version: 1

tasks:
  e2e:
    desc: the end-to-end suite, killed if it hangs
    timeout: 600
    run: [dart, test, test/e2e]
```

At the limit the body is sent `SIGTERM`, given a moment to write what it has,
and then `SIGKILL`. The task fails with `1`, and the message says it was
killed. Its own children are not reached: Windows has job objects and POSIX has
process groups, and Dart exposes neither. A task that starts a server and hangs
may leave the server behind.

Refused when the file is read: a value that is not a whole number, zero or
less, and the key on a `do:` or on a task with no body. A verb is a Dart
function, nothing outside it can stop one, and a limit that passed while the
verb kept writing would be worse than none.

### `unchanged`

Names a set whose files this task must leave as the run found them, compared
byte for byte. It is how a gate checks that generated code is committed.

```yaml
version: 1

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

The task fails with `1` for a file whose bytes changed, a file that appeared,
and a file that went away, and names them: twenty at most, and how many more.
A member that is a directory is every file beneath it. The files are left as
the task wrote them, because the regenerated ones are the fix. It is not `git
status`, so it answers the same in a dirty tree, in one whose fresh output is
not committed yet, and outside any repository.

Refused by `--validate`, by `--dry-run`, and by the run before any task starts:
a set the file has not got, and a `values:` set. Refused by `--dry-run` and the
run, with the same sentence: a set that leaves the root or has a broken
pattern, and an empty set with no `produced-by:` to fill it. A `produced-by:`
set that still holds nothing at the end is refused as an empty set is.
`--only` does not narrow it, and a run that has already given up does not
compare.

**The first reading is when the run begins**, not when the task is reached.
A generation is often several steps, and a `needs:` runs once, for whichever
branch reaches it first. In a gate where `test` needs `build` and comes before
`codegen`, `build` has regenerated everything before `codegen` is reached, and
a set read then would compare the new files with themselves and pass stale
code. The cost: any task in the run that writes the set before this one ends
counts against it. That is the question being asked, whether the committed
files are what this run leaves behind, so a task meant to rewrite them is not
one to hold them unchanged.

**Keep the set narrow.** Every file it reaches is held in memory, whole, from
the first reading to the comparison, and is read again when the task ends,
so a set over a large tree costs that tree's size twice. A member that is a
directory is walked to the bottom with nothing left out: a `.dart_tool`, a
`.git` or a `build` directory that the set reaches is compared like any
other file, and what a tool writes there fails the task. Name the generated
files themselves, as `generated` above does, and leave out what is not
yours with [`exclude:`](#include-and-exclude).

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

That is what `xtask` prints with no arguments, and each line has a section
below: [a run](#xtask-task), [`--`](#arguments-after---),
[`--keep-going`](#--keep-going), [`-j`](#-j), [`--only`](#--only),
[`--report`](#--report), [`--list`](#--list-and---gate),
[`--gate-members`](#--gate-members), [`--why`](#--why), [`--graph`](#--graph),
[`--validate`](#--validate), [`--check-ci`](#--check-ci),
[`--dry-run`](#--dry-run), [`--emit-schema`](#--emit-schema-and---check-schema),
[`--names`](#--names-and---completion), [`--version`](#--version-and---help).

`xtask` is whichever spelling you arrived at: the installed command, `dart run
xtask:xtask`, or `dart run :xtask`. The flags are the same in all three. A
mode that takes a name takes it as the next word or after `=`: `--why test` and
`--why=test` are one request. Two modes at once, an option `xtask` has not got,
and a mode given a name it does not take are refused with `2`, and the usage is
printed after the problem.

### `xtask <task>`

Runs the task and everything it needs, each once, in plan order. A gate set's
name runs its members.

```shell
xtask check
```

The file is looked for from the current directory **upwards**, so the command
works from a subdirectory, and every path in the file stays relative to the
root. Refused with `2`: no name, two names, and a name that is neither a task
nor a gate set, with the nearest names where one is a likely typo.

### Arguments after `--`

Everything after `--` reaches the body of the **named** task, after its `args:`
and its expanded `all:`. Nothing else in the plan sees it.

```shell
xtask test -- -n "one test"
```

That narrows the tests without also handing `-n` to the formatter. Refused with
`2`: `--` on a task with no body of its own, on a gate set, with no task named,
and beside a mode other than `--dry-run`.

### `--keep-going`

Reports every failure instead of stopping at the first, across tasks and
across the members of an `each:`.

```shell
xtask check --keep-going
```

Independent tasks still run; a task whose requirement failed is skipped and
said to be. With more than one failure the code is the first failure's. It is
off by default, because a pipeline wants the earliest possible red. Refused
with `2` beside a mode. [Reading a run](running.md#reading-a-run) shows the
summary it ends with.

### `-j`

Runs tasks that do not depend on each other at once, and the members of one
`each:`. `-j auto` is this machine's processors, at most 8.

```shell
xtask check -j auto
```

Also written `-j4`, `--jobs 4` and `--jobs=4`. Each task's output is collected
and printed whole when it ends, which is the cost. Refused with `2`: no number,
a number under 1, anything that is not a number or `auto`, and `-j` beside a
mode. What it costs and what the file can say back, with
[`serial:`](#serial), [`exclusive:`](#exclusive), [`alone:`](#alone) and
[`interruptible:`](#interruptible), is in
[Reading a run](running.md#reading-a-run).

### `--only`

Narrows a set for one run, without editing the file: two packages of seventeen
while working on those two.

```shell
xtask pkg-test --only packages=packages/ui,packages/ui_kit
```

Every `each:` and `all:` in the plan that names the set gets only the members
a pattern matches, in the set's order. A pattern is a glob, read against the
member as text: `packages/ui` keeps that one and not `packages/ui_kit`, and
`packages/ui*` keeps both, as does `packages/{ui,ui_kit}`, where the comma is
the pattern's and not a separator. Written again for the same set, the patterns
add up. `--dry-run` prints the narrowed plan, and the summary says how much of
the set ran: `2 of 17 members` on the task's row.

Refused with `2`: no `=`, no set name, an empty pattern, a pattern that is not
a glob, a set the file has not got, a set nothing in the plan expands, a
pattern that matches no member (found when the set is read), and `--only`
beside a mode other than `--dry-run`. `--check-ci` reports a step that narrows
a gate set: the job reads as the gate, and runs part of it.

### `--report`

Writes the run as JSON to a file, as it goes and on a failure.

```shell
xtask publish --report out/run.json
```

Refused with `2`: no path, a file that cannot be written, and `--report`
beside a mode, `--dry-run` included. A refused command line still writes the
report it asked for, saying why. The fields are in
[A run as JSON](running.md#a-run-as-json).

### `--list` and `--gate`

Prints every task with its description, grouped under its gate set in the
order `gates:` declares, and then the tasks no gate set holds under `ungated`.
`--gate <name>` narrows it to one gate set.

```shell
xtask --list --gate check
```

Refused with `2`: a task name after `--list`, and `--gate` without `--list`.

### `--gate-members`

Prints the tasks of one gate set, one per line, in run order: for a shell loop
or a script.

```shell
xtask --gate-members check
```

Refused with `2`: no name, and a gate set the file does not declare. An entry
point can ask the same in-process with `gateMembers`; see
[Dart verbs](dart-verbs.md#your-own-entry-point).

### `--why`

Names each entry point that reaches a task, and the route there, edge by edge.

```shell
xtask --why test
```

Refused with `2`: no name, more than one, a gate set's name, and a task that is
not there. [Seeing what will happen](running.md#seeing-what-will-happen) shows
the answer.

### `--graph`

Draws what a gate set or task pulls in, as a tree, without resolving a body.
With no name, every gate set, and then the tasks none of them reaches.

```shell
xtask --graph publish
```

Refused with `2`: more than one name, and a name a run would refuse.
[Seeing what will happen](running.md#seeing-what-will-happen) explains the
drawing.

### `--validate`

Parses the file and checks everything a refusal can find without running
anything, and reports every problem rather than the first.

```shell
xtask --validate
```

Answers `0` or `2`. It takes no name. The checks are listed key by key above,
and [When the file is checked](#when-the-file-is-checked) says which are its
own. Put it in the gate a person runs.

### `--check-ci`

Checks that every `run:` step under `.github/workflows` is one invocation of
one gate set, and says which gate sets and tasks no job runs.

```shell
xtask --check-ci
```

Answers `0`, or `2` for a step that runs anything else. It takes no name.
[Gate sets, and CI](ci-integration.md) is the whole of it, the exemption marker
included.

### `--dry-run`

Prints the resolved plan and runs nothing: sets expanded, `$each`
substituted, programs found on this machine, and what `do: remove` would
delete.

```shell
xtask --dry-run check
```

It stops where a run would stop, with the same message and code: `3` for a
program that is not installed, `2` for a refused set. It takes `--` and
`--only`, and refuses `-j`, `--keep-going` and `--report` with `2`.
[Seeing what will happen](running.md#seeing-what-will-happen) shows one.

### `--emit-schema` and `--check-schema`

`--emit-schema` prints the JSON Schema of the file format. `--check-schema
<path>` answers `0` when that file is the schema this engine emits, and `2`
when it is not, is missing, or cannot be read.

```shell
xtask --emit-schema > xtask.schema.json
xtask --check-schema xtask.schema.json
```

Neither reads `xtask.yaml`. The path is read from where the command runs, and
line endings and a trailing newline are not differences.
[Editor support](#editor-support) says how to use them.

### `--names` and `--completion`

`--names` prints every gate set, task and set, one per line and tab-separated:
what a completion script reads. `--completion <shell>` prints a completion
script for `bash`, `zsh` or `fish`.

```shell
source <(xtask --completion bash)    # in ~/.bashrc
source <(xtask --completion zsh)     # in ~/.zshrc, after compinit
xtask --completion fish | source     # or save it under completions/
```

The script reads names from the file each time TAB is pressed, so nothing is
regenerated after the file changes. It completes the command `xtask`, and each
TAB starts it, so it is the installed or compiled one that makes this
pleasant: `dart run` spends half a second starting. Refused with `2`: a shell
it does not write for.

### `--version` and `--help`

`--version` prints `xtask` and the engine's version. `--help` and `-h` print
the usage and answer `0`.

```shell
xtask --version
```

## A fuller example

One file using most of the keys: a workspace whose gate formats, analyzes,
tests and checks generated code, and whose release builds each flavour,
publishes each package and announces it.

```yaml
version: 1

gates: [check, release]

secret-env: [PUB_TOKEN]

sets:
  packages:
    include: [packages/*]

  tested:
    include: [packages/*]
    containing: [test]

  generated:
    include: ['packages/models/lib/**.g.dart']

  flavours:
    values: [dev, prod]

tasks:
  format:
    desc: fail if a Dart file is unformatted
    gate: [check]
    interruptible: true
    run: [dart, format, --output=none, --set-exit-if-changed, .]

  analyze:
    desc: analyze the workspace
    gate: [check]
    interruptible: true
    run: [dart, analyze, --fatal-infos]

  test:
    desc: run each package's suite, as it runs on a laptop
    gate: [check]
    each: tested
    in: $each
    env-unset: [CI]
    run: [dart, test]

  codegen:
    desc: regenerate the models, and fail if that changed a committed file
    gate: [check]
    in: packages/models
    unchanged: generated
    run: [dart, run, build_runner, build, --delete-conflicting-outputs]

  build:
    desc: build the app once per flavour
    each: flavours
    in: app
    env-paths:
      PUB_CACHE: .dart_tool/pub-cache
    timeout: 900
    run: [flutter, build, apk, --flavor=$each]

  publish:
    desc: publish each package in order, then announce it
    gate: [release]
    needs: [test, build]
    then: [announce]
    each: packages
    in: $each
    serial: true
    env-required: [PUB_TOKEN]
    run: [dart, pub, publish, --force]

  announce:
    desc: post the release note
    platforms: [linux]
    do: notify
    all: packages
    args: [$all]
```

`xtask check` runs `format`, `analyze`, `test` and `codegen`, in that order.
`xtask release` runs `test` and `build` first, then `publish` once per package,
one at a time, then `announce` on Linux with every package as its arguments.
If `announce` fails after `publish` worked, the run answers `4`.

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

A `4` stops the run exactly as a `1` does: what has not started does not
start, what is running is left alone, and the summary names the rest. The code
says which ending happened, not how much of the plan was abandoned; that is
what `--keep-going` answers. What a `4` prints names the two tasks, ``
`publish` finished, and `announce` failing after it does not undo that ``, and
nothing about what they were, since that is the project's to say.

With `--keep-going` and more than one failure, the code is the **first**
failure's. A code is a report about one failure; the summary is where the
others are.

A **verb**'s exit code is what the run answers with. It is your Dart, written
against this table, whose constants the package exports as `ExitCode` so a
verb can name the reason rather than the digit. The built-in `remove` answers
`2` for a path outside the repository, because that means *the file is
wrong*. A verb may answer `4` itself, when its own body has an irreversible
half and a check after it. Alone it is the run's answer, and beside an
ordinary failure the ordinary failure wins.
A program started by `run:` has never heard of this table, so its code goes in
the message and the run answers `1`.

A run handed to the project's own entry point answers with that run's code.
Before it starts, the installed `xtask` adds two of its own: `1` where the
`dart pub get` it runs to resolve the entry point's package fails, and `2` for
a hand-over loop or a command line a batch-file `dart` cannot carry. After it
starts, an entry point that does not compile answers what `dart run` does,
`254` or `255`, passed through as it is.

Why `3` is separate: "Dart is not installed on this machine" and "the code is
broken" are repaired by different people, and one code sends both to the same
one. Why `4` exists: a publish followed by a verification has **three**
endings, not two: nothing was published, everything passed, or the upload
happened and the check after it is red. Collapsing the third into `1` tells a
pipeline the publish failed, which is false and unrecoverable in the wrong
direction: the registry will not accept that version again.

## Editor support

Generate the schema into your repository and point at it with a relative path,
so a fresh clone needs neither the network nor a per-person editor setting:

```shell
xtask --emit-schema > xtask.schema.json
```

```yaml
# yaml-language-server: $schema=./xtask.schema.json
version: 1
```

The schema knows the **shape** of the file: it completes a task's keys, and
underlines `dsec:` or a `gate:` written as a string, while you type. What needs
the graph or the filesystem — a cycle, a `needs:` pointing at nothing, an
undeclared or empty gate set, a glob matching nothing, an unregistered verb,
an `in:` that leaves the repository — is what `--validate` answers. A schema
catches a mistyped **key**; `--validate` catches a mistyped **name**.

A committed copy falls behind the day the engine is upgraded. Writing it stays
a person's act, because a redirect is shell; checking it is a gate's:

```yaml
version: 1

gates: [check]

tasks:
  schema-check:
    desc: fail if xtask.schema.json is not the schema this engine emits
    gate: [check]
    run: [dart, run, ':xtask', --check-schema, xtask.schema.json]
```
