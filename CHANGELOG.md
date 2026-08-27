# Changelog

## Unreleased

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
