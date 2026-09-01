# Above `-j 1`, a task's output is buffered and printed whole

A task's output normally passes through as it arrives and is never buffered to
the end, because a long test run has to be watchable. Two tasks writing to one
terminal at once produce a transcript belonging to neither, and a collapsible
section that folds lines from two tasks folds nothing — so there is no
arrangement that keeps both promises. The choice is sequential and watchable,
or parallel and buffered, and which one is wanted is the caller's to say: `-j`
is opt-in, and `-j 1` is unchanged.

## Consequences

Declaration order survives as a preference rather than a guarantee — it decides
which ready task is *begun* first, not which finishes. A parallel run announces
itself before going quiet, because the first thing a long one does is nothing
at all and a silence nobody explained reads as a hang.
