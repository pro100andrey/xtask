# Publishing to pub

`pubPublish` publishes a package and does not report success until the
registry serves it:

```dart
exitCode = await runXtask(args, verbs: {
  'publish': pubPublish(const PubPackage('packages/my_pkg')),
});
```

```yaml
version: 1

tasks:
  check:
    desc: the checks a release needs
    run: [dart, analyze, --fatal-infos]

  publish:
    desc: publish my_pkg to pub.dev and wait until it is served
    needs: [check]
    do: publish
```

## What it checks before the upload

An upload cannot be taken back, and a version cannot be uploaded twice, so
before it the verb checks:

- that the `pubspec.yaml` names the package and its version and does not say
  `publish_to: none`;
- that `CHANGELOG.md` names the version in a heading (`## 1.2.0`,
  `## [1.2.0] - 2026-10-23`, `# v1.2.0`) — pub.dev shows, for each version,
  the changelog it was uploaded with;
- that `git status` shows the package matching HEAD, untracked files
  included — pub packs the directory, not the index;
- that every file `dart pub publish --dry-run` lists is one git tracks — a
  `.pubignore` stops pub reading the `.gitignore` beside it, and pub never
  reads `.git/info/exclude`, so a file git ignores can be in the archive
  without `git status` showing it. Git is asked in the package, so a package
  that is a submodule is read from its own repository, and a tracked link to
  a directory covers the files pub lists under it;
- that the registry does not already serve the version, and could be asked.

## The upload and the wait

Then `dart pub publish --force` in the package, and a bounded wait,
`registryWaits` (about three and a half minutes), until the registry lists the
version. The registry is where pub uploads: the `publish_to:` URL, or
`PUB_HOSTED_URL`, or pub.dev, asked through
pub's API without a credential; a private registry that wants one takes a
`probe:` of the project's own.

## Exit codes

Three endings. Nothing was uploaded: `2` where there is no package to publish
(no `pubspec.yaml`, no name or version, `publish_to: none`), `1` for any other
refusal. Uploaded and served: `0`. Uploaded, and the registry
has not served it in time: `4`. Pub answering other than `0` is not proof
that nothing went up, so the registry is asked once then: serving the version
is a `0`. Not serving it is a `1` only after pub's `65`, its refusal before
the upload (validation, credentials); after any other failure, and where the
registry does not answer, it is a `4` — it may have been uploaded. The upload is not undone, and a pipeline must
not read that as a failed publish — the registry will not take the version
again.

## On Windows

Nothing differs: `git` and `dart` are started by the engine as any `run:`
body's program is.

## As functions

`publishToPub` is the same as a function.
