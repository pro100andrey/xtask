# xtask

A task runner whose tasks are data. One file at the repository root says what a
project's jobs are; the same file is what a person types and what a CI job
runs, so the two cannot drift apart.

## Language

### The file

**Task**:
One named job, read completely from its own keys. It has at most one body and
may name others it needs or follows.
_Avoid_: step, target, script, command

**Gate set**:
A named list of tasks, declared at the top of the file, run by being named.
Named after who runs it — one person's command, or one CI job's.
_Avoid_: group, suite, stage, pipeline

**Set**:
A named list of strings a task iterates over or passes as arguments. A **glob
set** is found on disk, a **list set** is written out, a **value set** holds
members that are not paths at all.
_Avoid_: collection, list (unqualified), files

**Member**:
One string a set expands to.
_Avoid_: item, element, entry

**Body**:
What a task does: an external program as argv (`run:`), or a verb (`do:`). A
task with neither is a composite and does nothing of its own.
_Avoid_: action, command, payload

**Verb**:
A Dart function the project registers under a name, reached by `do:`. The place
logic goes, because the file cannot branch.
_Avoid_: plugin, handler, action, hook

**Marker**:
`$all` or `$each`, standing where a set's members go. It is a substitution, not
an expression: nothing may follow `$each`, and `$all` is a whole argument or
nothing.
_Avoid_: variable, placeholder, template, interpolation

### The run

**Plan**:
The order a run will take: every task it reaches, once each.
_Avoid_: schedule, DAG, execution order

**Continuation**:
A task reached through another's `then:` — something that runs *after* a body
rather than before it. Its failure is its own outcome, distinct from the body
failing.
_Avoid_: callback, post-step, follow-up

**Resolved body**:
A body with everything about it decided: the set expanded, the member
substituted, the directory absolute, the program found on this machine. What a
dry run prints and a run performs, worked out once.
_Avoid_: command, invocation, resolved task

**Fan-out**:
A task running its body once per member of its `each:` set.
_Avoid_: matrix, loop, iteration, parallelism

**Entry point**:
A name somebody types: a task nothing else names, or a gate set.
_Avoid_: root, target, goal

### The command line

**Mode**:
A flag that replaces a run with something else — `--list`, `--validate`,
`--dry-run`, `--check-ci`, `--why`, `--gate-members`, `--emit-schema`,
`--version`. Exactly one per invocation, or none.
_Avoid_: subcommand, action, verb

**Run modifier**:
A flag that changes a run without replacing it — `-j`, `--keep-going`.
_Avoid_: option, switch, setting
