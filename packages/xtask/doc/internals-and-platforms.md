# Internals and platforms

For whoever needs to know what the engine does at the edges — a run told to
stop, a Windows machine, a value that must not be printed — read this before
relying on any of them.

## Ctrl-C, and SIGTERM

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

### When the installed `xtask` handed the run over

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

Before the run is started, while the installed `xtask` gets the package's
resolution, an interrupt or a `SIGTERM` stops the `dart pub get` the way a
body is stopped, `SIGTERM` and then `SIGKILL` after a grace, and the run is
refused with `130` or `143`, which the `--report` says. The `pub get` is
started as a body is, with a stdin that ends at once, its output read as
UTF-8 that may be malformed, and its pipes let go of a grace after it ends,
whatever it left running. On Windows the Ctrl-C reaches the `pub get` from the
console, and the installed `xtask` hears it as well: a Ctrl-C from the start
of the `pub get` to the start of the run refuses the run with `130`, the one
between the two included. This too is decided by a test that names the
platform, not measured on a Windows console.

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

## Secrets

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
