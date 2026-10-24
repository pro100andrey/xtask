# Gate sets, and CI

For whoever writes the CI workflow, or adds a task to a gate — read this before
the first job, and again when `--check-ci` refuses a step.

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
  in: packages/web
  run: [dart, test, test/web/web_e2e_test.dart]
```

which turns "a browser test failed somewhere inside" into "task `web-e2e`
requires `CHROMEDRIVER`, which is not set".
