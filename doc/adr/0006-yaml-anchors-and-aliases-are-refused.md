# YAML anchors, aliases and merge keys are refused

`sets:` already exists to say a thing once, so an anchor is a second mechanism
for the same purpose — and in this design two ways to say one thing have
drifted everywhere they were allowed. It also defeats the property that a task
is read completely from its own keys: the reader of `*base` has to leave the
task and go find the declaration.

The refusal is a scan of the raw text, because it has to be. By the time a
document exists `package:yaml` has expanded every alias into a copy and the
evidence is gone.
