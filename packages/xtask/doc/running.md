# Running, and reading a run

For anybody about to run a task, or reading one that has ended — what the
tool shows before, during and after a run, and what asking it to go faster
costs.

## Seeing what will happen

Three questions the tool answers without running anything. All are cheap,
and all are the fastest way to find out that a file says something other
than what you meant.

`--dry-run` shows what will actually happen, not what is written — sets
expanded, `$each` substituted, and the executable resolved on this machine.
The task names below are this repository's own, from its
[`xtask.yaml`](https://github.com/pro100andrey/xtask/blob/main/xtask.yaml):

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

`interruptible: true` gives back some of what `-j` costs. Not reaching into
what is already running is right for a build and wrong for a check: `dart format --output=none`, `dart analyze` and
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
| `code` | what the run answered, from the [exit code table](reference.md#exit-codes); only when `complete` |
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
