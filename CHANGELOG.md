# Changelog

## Unreleased

### The command line is parsed in one place

`--check-ci` exists so that a workflow and the task file cannot hold two lists
of what runs, and it did that job while keeping a second copy of the command
line's own grammar: which flags take a value, how one is joined to it, what a
second operand means. Both copies had already been wrong — `-j4` swallowed the
gate set after it, and a lone `-` raised a `RangeError` out of `--check-ci`.

A workflow step is now checked by being handed to the parser the command line
uses, and the answer is asked one question. Every spelling `xtask` accepts is
one a workflow may be written in, without the checker learning any of them; a
step the command line would refuse is reported in the command line's own words,
rather than as "what runs belongs in the task file" — which is the wrong
sentence about a step that names a gate set correctly and would still exit
before doing anything.

### Endings the exit code table does not have

Six paths could end the process at `255`, which is not a code §5.3 defines:
a directory a set's patterns reach that cannot be listed, a workflow that is
not UTF-8, a `.github/workflows` that cannot be listed, a task printing a byte
that is not UTF-8 while its output is piped, a pattern `do: remove` could not
compile, and a `remove` that could not delete. Each is now a sentence and a
code the table has.

A run that killed a task could also fail to end at all: the two subscriptions
collecting its output were never cancelled, so the process stayed alive after
the summary had printed and the exit code was set — until a grandchild let the
pipes go, which for a backgrounded server is never.

### `exclusive:` keeps a task's own members apart

A token is held from the moment a task is admitted, and the fan-out did not
consult it, so `exclusive: [chromedriver]` kept every other task away from the
browser and then drove it from four members at once. A task holding a token now
runs its own `each:` members one at a time.

**Behaviour change:** such a task is slower under `-j` than it was, and was
previously not keeping the promise the key makes.

### `--dry-run` says what `remove` would delete

Every other body is fully worked out by the time a plan describes it — a `run:`
shows the argv the child will be handed. The one verb this engine ships is the
one that deletes recursively, and its block showed the pattern. It now lists
what is on disk under the block, without running the verb, and says so out loud
when there is nothing there.

### Every contradiction in a task, in one refusal

`each:` without `$each`, `$all` inside a larger word, `all:` beside `each:` —
the rules that ask whether a task's keys agree with each other are their own
module now, and they answer with a list. A file with four such mistakes cost
four rounds of fix-and-rerun; it is one refusal naming all four. A marker
written in `exclusive:` is one of them, which was previously neither refused
nor substituted.

### `--validate` accepts a file the run accepts

A task whose whole content is `then:` is reached, runs nothing of its own, and
then runs what follows — which is something. The validator called it a name
with a description attached, so a file that ran green failed the gate the
README tells every project to adopt.

### Faster

Measured on a synthetic repository of 15,000 files and a task file of 4,000:

- `--validate` on a deep graph: **55s → 0.11s**. It plans every task, and the
  planner's open-task stack was a list whose membership test is a scan, so one
  plan of depth *d* cost *d*², and *n* of them cost *n*³. A plan that succeeded
  also covers everything it reached, so those are not planned again.
- `--dry-run` of a gate whose tasks share a glob set: **6× faster.** Nothing
  runs between two steps of a dry run, so the tree cannot have changed; a real
  run still re-reads, because a task before this one may have made the files.
- A set written `packages/{a,b}/**`: **4× faster.** Any brace switched pruning
  off entirely, so an ordinary monorepo shape read all of `node_modules` and
  `.git`. Only a brace group spanning a `/` does that now.
- `do: remove` with four patterns: **2× faster** — one walk of the tree rather
  than one per pattern.
- Glob sets generally: **14%**, from compiling each pattern's prune shape once
  per walk instead of once per directory, and from carrying each entry's
  relative path down the walk rather than deriving it from the absolute one.
- `do: remove` with a glob was not pruned at all and read the whole tree on
  every invocation.

### Also

- The engine answers `--why` about a name the file gives to both a gate set and
  a task by saying so, instead of "`x` is a gate set, not a task" — which was
  false about that file, and contradicted by every other mode.
- An unknown verb and a set that does not exist are reported in one sentence
  each, wherever they are found. The two copies had each learnt something the
  other had not.
- The timing total says how much work there was, which for a fanned-out task is
  its members and not its row.
- An empty set feeding `remove` is told what shape it wants: a list of literal
  patterns, which is never empty, rather than a glob that matches the build
  output once and nothing afterwards.
- A `run:` body's echo and the failure under it render argv the same way. One
  run said `ls no such dir` and then `ls 'no such dir' ''`.
- `interruptible:` is refused on a task with no body, as `timeout:` already was.
- `xtask --keep-going` with no task named says so, instead of ending a sentence
  mid-way.
- `--emit-schema` applies its own drift guard to the keys of a set, which it
  documented and did not do.
- `CONTEXT.md` and `docs/adr/` record the glossary and the eight decisions that
  were written only in code comments.

### Gate sets are declared

`gates: [check, release]` at the top of the file, names only. A gate set used
to exist by being mentioned, so a misspelling made a new one: on the `gate:`
side that was caught sideways, by nothing collecting it, but `collects: chekc`
gathered a set with no members, ran, did nothing and answered 0 — a green
result nobody checked, from one transposed letter. Both sides are now a
refusal that names the line, and so is a declared set no task is in.

The order declared is the author's, and `--list` groups by it — which the
implicit version could not do, having neither an order of its own nor a
complete list. `ungated` is a heading only a declaration makes trustworthy: a
task under it is one nothing runs, rather than one the report did not think of.

A gate set is now run by being named — `xtask check` — and `collects:` is
gone with the composite it created. The composite existed only to give a gate
set a name, a description and a way to be run; the declaration gives all three,
and removing it removes the rewrite that turned one into a task, the special
case where a composite in its own gate had to be dropped from its own members,
and the class of file where the two could disagree. A gate set and a task may
not share a name, and `needs:`/`then:` may not name a gate set: an edge runs
between tasks, and a list is not a step.

**Breaking:** a file that uses gate sets must declare them, and `collects:` is
no longer a key — delete the composite and run the gate set by name.

### A verb is given what it needs to be the escape hatch it is

`VerbContext` carries `member` — which member of `each:` this invocation is
for. A verb ran once per member with the same arguments and a different working
directory, and that was all it had: it could not name the member in a message
or derive anything from it.

And `context.run(argv)` starts a program the way a `run:` body is started. R1
puts logic in Dart and the README sends derived paths there — `x.proto` to
`x.pb.dart` is a verb's job — but a verb that wanted to run a program reached
for `Process.start` itself and lost the `PATH` walk, the `PATHEXT` rules, the
refusal to hand `cmd.exe` a metacharacter through a batch shim, and the exit
code that says a tool is missing rather than broken. Half an escape hatch is
not one.

`context.run` is refused a `cmd.exe` metacharacter through a batch shim, the
same as a `run:` body, and a relative `workingDirectory` is read from the
repository root — against the process's own it worked from the root and quietly
targeted somewhere else from a subdirectory.

**Breaking:** `VerbContext` takes a required `start`. Projects do not construct
one; the engine does.

### A closed pipe is an ordinary end, not a stack trace

`xtask --list | head -2` is an ordinary thing to type. `head` closes the pipe
as soon as it has what it wants, and the next write raised
`FileSystemException: Broken pipe` that nothing caught — so the run ended on a
stack trace and exit 255, a number the table does not have, for output that
arrived exactly as asked. Twenty-two runs in forty, before; none in forty,
after.

An `IOSink` is asynchronous, so the failure does not arrive at the `writeln`
that caused it and a `try` around one catches nothing. Claiming `done` is what
makes it ours to ignore — and only a closed pipe is claimed. Marking every sink
error handled would have swallowed the ones that matter: `xtask check >
report.txt` on a full disk writing a truncated report and answering 0, with
nothing on stderr, is the green result nobody checked that this is all against.

### The flags a run may carry are named once

The command line decides what it accepts and `--check-ci` decides what a
workflow step may carry, and they had a copy each: adding a flag to one meant
`--check-ci` calling a working workflow a step that does something other than
run a gate. That is the duplicate-list defect this tool exists to remove, grown
inside it.

### A fanned-out task says how much work there was, beside how long it took

```
test  1m 12s  4m 51s over 40 members
```

One row said how long you waited. Over forty packages at four at a time, how
much work there WAS is the other half — the number `-j` is for — and it was
nowhere, so a run that halved its wall clock looked exactly like one that had
less to do.

### A killed process is not waited out through a grandchild

Collecting a piped child's output ends when its stdout and stderr close, and a
grandchild that inherited them keeps them open. So `run: [sh, -c, 'sleep 12;
echo done']` under `interruptible:`, killed at 0.0s, still took twelve seconds
to report — the feature giving back nothing, and billing the wait as the task's
own work. The wait after a kill is bounded by the same grace period the kill
itself uses: a moment for what was already written, and no longer. `timeout:`
had the same hole.

### `--why` remembers what cannot reach its target

`seen` had to become the path rather than the visited set, or a dead branch
marked everything it touched unreachable. A path set alone re-walks every
shared subtree once per path, and `--why` asks once per gate member per gate.
A no is remembered now — except past a ring, where a branch cut short by the
path guard says nothing in general.

### The walk is pruned on the include patterns, not only on the exclusions

Include patterns were used to match and never to prune, so
`include: ['src/**/*.ts']` walked all of `node_modules` and all of `.git` — once
per set, per task, per run — to find nothing there by construction.

A directory is entered only when one of the include patterns could still match
something inside it, decided from the pattern's own shape at the depth reached
so far. Three shapes say keep going, so the walk is never narrower than the
patterns are: a segment CONTAINING `**` at or before that depth — `package:glob`
lets it cross `/` wherever it appears, and `lib/**.dart` is the shape this
repository's own example ships — a brace, which does not split reliably by path
segment, and a prefix that will not compile on its own, which tells us nothing.
Only the descent is pruned: a directory can be a member itself, which is how
`packages/*/coverage` reaches one to delete.

### A set is read when its task is about to run, and at no other time

A file whose `build/*.txt` is produced by an earlier task ran green while
`--validate` and `--dry-run` both called it invalid — one question with three
answers, and the gate the README calls the first one to adopt was the one
saying a working file is broken.

The moment is now part of the format, and a set that the run produces says so
with `produced: true`. It buys exactly one thing — the emptiness of that set is
not judged before its task runs — so `--validate` passes over it and
`--dry-run` prints `cannot be resolved yet` with the reason under it. Every
other check still applies to it, and a run still refuses it empty.

Said rather than inferred. Guessing from `needs:` exempted `analyze: {needs:
[pub-get], all: sources}` — the ordinary shape — and took a typo'd glob with
it; and skipping the whole expansion took the repository boundary too, so
`include: ['/etc/host*']` validated clean. `--dry-run` tells "not yet" from
"wrong" by the type of the refusal rather than by its exit code, having called
a boundary violation and an unknown verb premature and answered 0 for both.

### A member that looks like an option is refused

A repository may hold a file called `-n.dart`, and a glob will find it. Handed
over bare it is not a path to the program — it is `-n`, and almost every
program reads it that way. The engine knows every member and every position,
so it can see this and say so; the fix is the one every command line already
has:

```yaml
format:
  all: sources
  run: [dart, format, --, $all]
```

Refused rather than inserted for you: adding `--` would change the argv a task
wrote, which is the one thing `run:` promises it does not do, and there are
programs for which `--` means something else.

### `interruptible:` gives back what parallelism costs

A run does not reach into what is already running, because a build killed
half-way leaves whatever it was doing in whatever state that half is. Right for
a build, wrong for a check: `dart format --output=none`, `dart analyze` and
`dart test` write nothing a half-run would leave behind, and the engine cannot
tell the two apart while the person who wrote the task can.

Sequentially, a format failure at 0.4s means analyze and test never run at all.
In parallel they run to the end anyway, and the machine spends the whole budget
to learn what it knew in a tenth of a second. With `interruptible: true` the
fast answer arrives at the fast answer's price.

A stopped task is reported as stopped, not as a second failure beside the one
that actually broke. `--keep-going` stops nothing at all, which is the whole of
what that flag says. And a `do:` may not carry the key, for `timeout:`'s
reason: stopping a Dart function from outside is not something Dart can do.

### The file says whether, the flag says how many

```yaml
pub-get:
  each: packages
  in: packages/$each
  serial: true                  # one shared ~/.pub-cache
  run: [dart, pub, get]

e2e:
  exclusive: [chromedriver]     # so does the other browser suite
  run: [dart, test, test/web]
```

`-j` is a number about this machine at this moment; whether two things may
happen together at all is a fact about the project, the same on every machine.
Getting it wrong makes a run flaky rather than slow, which is a different kind
of wrong. Both keys can only ever make a run slower and never change its
result.

Named rather than counted: a name is something `--validate` can cross-check,
and it does — a token only one task holds keeps it apart from nobody, and a
`serial:` on a task with no `each:` has one body and nothing to order. There is
no `concurrency: N` key, because that is one machine's width written into a
file every other machine reads.

### `-j` reaches the members of an `each:`

The budget used to decide which **tasks** were admitted, so `-j 4` over one
fanned-out task admitted the one task and then ran its forty members in turn —
the flag doing nothing at all on the commonest shape it exists for.

A slot is now held by a **unit**: one member, or one body with no members. A
task's members share the budget with whatever else is running, and the task
gate stays where it was, because at one task in flight a failure is observed
before the next is admitted — which is what "a failure stops what has not
started" rests on.

Which member the run answers for is the earliest in the set, not the first to
finish: a `do:` verb's code is a deliberate decision, and an answer that
depends on scheduling is not an answer.

Members are still not plan steps, and must not be: a plan step is what
`needs:`, `then:` and one `::group::` are about, and a member is none of
those. Two members writing at once are buffered and flushed as each ends,
one level down from how tasks are; one member in flight keeps live output
exactly as it was.

### `--parallel` becomes `-j <n>`, and CI can finally write it

`--parallel` read as a boolean and behaved as a number: bare it meant "as
many as this machine has processors", so `--parallel 2` was a task called `2`
and needed a refusal explaining its own syntax. A flag that has to do that has
the wrong syntax. `-j 4`, `-j4`, `--jobs 4`, `--jobs=4` all work, as they do
in make, cargo and xargs; bare `-j` is refused, and `-j auto` picks a number
capped at 8 — a job here is a `dart test` or a `dart analyze`, each already
multi-threaded, so one per core on a 32-core machine is 32 analysis servers.

`--check-ci` accepts flags after the gate set's name. It required exactly one
word and refused anything starting with `-`, which made `xtask check -j 4`
impossible to write in a workflow — while §7.1 sends all parallelism to CI. A
step doing two *things* is still refused, which is what that rule was for.

**Breaking:** `--parallel` and `--parallel=N` are gone; write `-j N`.

### `--keep-going` reaches the members of an `each:`

The first bad member abandoned the rest, with or without the flag, and the
summary said nothing about them — so `format` over forty packages reported one
unformatted file per run and a person fixed, reran, fixed, reran, which is the
loop `--keep-going` exists to end. A member that never ran also read exactly
like one that passed.

With the flag every member runs and the failures are named. Without it the
task still stops at the first, and the summary says how many were not tried.
The exit code stays the first failing member's, as it is for tasks.

### A set can say it does not hold paths

```yaml
sets:
  flavours:
    values: [dev, staging, prod]
```

Every other kind of set holds paths and is treated as one: refused if it
reaches outside the repository, reported if a glob matched nothing. Neither
question means anything about `dev` or `stable`, and asking the first refused
`a:b` for looking like a Windows drive. A set that says what it holds is asked
the right questions — and it is what lets a set hold the bare name a path
cannot be derived from, with `in: packages/$each` composing the path around it.

Empty is still an error, for the reason it always was.

### `$each` reaches the arguments, so per-file work can be written at all

The member of an `each:` set used to be reachable only through `in:`, so a
member could be a working directory and nothing else — and "run this over
every file" was unwritable. `$each` now stands as a whole argument or at the
**end** of one, with nothing after it:

```yaml
format:
  each: sources
  run: [dart, format, $each]

test:
  each: packages            # bare names
  in: packages/$each        # the path, composed
  run: [dart, test, --name, $each]
```

Allowing a prefix is what lets a set hold the part that cannot be derived —
the bare name — with the path composed where it is needed, so one task can
have both halves. Forbidding a suffix is what keeps `build/$each.dart` out:
deriving a path from a value is a computation, a computation wants a modifier,
and a modifier wants a language. That is a verb's job.

Refused when the file is read: a marker with no `each:`, an `each:` whose
marker is never written, the marker as the program in `run:`, text after the
marker, and `$each` in the arguments together with `in: $each` — the member is
a path from the root and `in:` moves into it, so the two would be relative to
different places. A composed `in:` says the opposite and is fine.

### `argv-from:` becomes `all:`, and the set goes where you write it

`argv-from:` appended its set to the end of argv and nowhere else, so
`cp <files> dest/` could not be written at all. `all:` names the set and the
marker `$all` says where its members go:

```yaml
lake-format:
  all: lake-sources
  run: [lake, format, --set-exit-if-changed, $all]
```

The marker is a whole argument and is written exactly once. A set named and
never used, a marker with no set, a marker inside a larger argument, and the
same marker twice are all refused when the file is read — none of them fails
at run time, they all succeed at the wrong thing.

`each:` and `all:` together are refused too. That pairing was legal and handed
the **whole** `all:` set to **every** member of the `each:` set, which nothing
reported and nobody meant.

**Breaking:** `argv-from: s` becomes `all: s` plus a `$all` in `run:`/`args:`.

### Three failures a committed file could reach with nothing said about it

- **The repository boundary is one check, and it reads both notations.** A
  set's written members and a task's `in:` never met it at all, so
  `sets: {x: ['/etc']}` expanded to real paths and `in: ../..` ran a body two
  levels above the root. It also asked POSIX only, while every caller joins the
  answer with the platform's own `p.join`: on Windows `..\..`, `\foo` and
  `\\server\share` all walked through a gate written to stop them, the last
  one landing a recursive delete on a file server. `--validate` reports the
  `in:` case now, since the set half of the same fence was already reachable
  from there.
- **A body that cannot start, or that throws, is a task failure.**
  `Process.start` throws rather than answering when the working directory is
  not there, and nothing caught it: exit 255, a number the table does not have,
  with the task's `::group::` left open so the rest of a CI job folded into a
  task that had already died. Any other escaping exception — a project verb's
  own, or a fault in the engine — is now named by type with its trace inside
  the fold.
- **`**/` means the same thing everywhere.** `sets:` corrected
  `package:glob`'s reading of it to "none or more directories" and `do: remove`
  did not, so one pattern matched two different sets of paths depending on
  which key it was written under. The correction also missed a globstar that
  began a brace alternative, so `{**/*.dart,**/*.yaml}` silently examined every
  nested file and no root one.

  **Behaviour change in a verb that deletes:** `remove: ['**/build']` now also
  removes a root-level `build`, which it previously left alone.

## 0.1.0

First release. Enough to replace one repository's `make`, and no more.

- `xtask.yaml` parsing with `--validate`, and errors that name the line rather
  than the file.
- The graph: `needs`, `then`, cycle detection with the cycle spelled out,
  run-once per invocation, declared order, and the five exit codes — `4`
  included, for a body that succeeded and a continuation that did not.
- Bodies: `run` as argv, `do` naming a verb the project registered, `args`,
  `argv-from`, `each`, `in`, `env`. Executable resolution honours `PATH`,
  `PATHEXT` and the fact that Windows cannot start a batch shim directly.
- `env-required`, checked before a body runs. The engine installs nothing.
- Sets: lists and globs with exclusions, expanded by the engine in a
  deterministic order. An expansion matching nothing is an error.
- Gate sets, the `collects:` derivation, `--list` and `--gate-members`, and
  log-grouping markers on a host that folds output.
- The `remove` primitive, which is the whole built-in list.
- `--dry-run`, printing what a run resolves to rather than what is written.
- `--emit-schema`, a JSON Schema for editors, generated from the same key lists
  the parser refuses unknown keys with.
- A mode that takes a name takes it either way — `--why build` and
  `--why=build` — because one flag taking both spellings and the rest taking
  one is a rule nobody can hold.
- `--why`, which names every entry point that reaches a task and spells the
  route edge by edge, saying whether each edge is a `needs:` or a `then:`.
- `--check-ci`, which reads the workflow files and reports a shell step that
  names a command instead of a gate set, and a gate set with no job to run it.
- `--keep-going`, and `--parallel`, which is the one place a promise is
  deliberately broken: output is collected per task and printed when that task
  ends, so the run says how wide it is and that the silence is expected.
- What each task took, printed after the last section rather than beside the
  task, because a line inside a fold is invisible to somebody who has expanded
  nothing.

Deliberately not here: `--emit-ci`, `--dry-run` output formats, a watch mode,
coloured output, shell completion. Each is a real convenience and each is a
place to hide a second list.
