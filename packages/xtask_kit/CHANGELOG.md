# Changelog

## 0.1.0

### Added

- `linuxAppInstall` and `linuxAppUninstall`: a built Linux app installed for
  the person running it under `~/.local`, linked onto `PATH`, with its menu
  entry and icons — described by a `LinuxApp`, whose icons are an `IconTree`
  or `IconFiles`. A link at `~/.local/bin/<binary>` that leads anywhere but
  the app's own directory is refused by the install and left by the uninstall,
  and so is a `~/.local/lib/<binary>` without the install's mark — the
  uninstall then removing nothing, menu entry and icons included.
- `cliInstall` and `cliUninstall`, with `installCli` and `uninstallCli` as
  functions: the bundles `dart build cli` leaves, installed into one `bin/`
  and `lib/` under `~/.local/share` with each command on `PATH` — a link, or
  on Windows a copy, with what a running process holds moved aside rather
  than failed on. Copied beside the earlier install and swapped in; a file on
  `PATH` the install did not lay down is refused rather than replaced, and so
  is a `~/.local/share/<name>` without the install's mark, which the uninstall
  leaves whole.
  `conflictingLibraries` is the check that two bundles can share one `lib/`;
  executables of one name are checked the same way.
- `replaceDirectory`, `notOurDirectory`, `markDirectory`, `ownerMark`,
  `notALink`, `notOurLink` and `pointLink`, which the install is made of: an
  installed directory replaced whole, and only where it carries the
  install's mark (`.xtask_kit`, naming its owner); a link replaced only where
  it is one and leads into the install's own directory.
- `onPathLine`: whether the command just installed is the one `PATH` finds,
  something else is, or nothing is — on Windows by every extension `PATHEXT`
  names.
- `homeOf` and `dataHome`.
- `vsCodeInstall`, `vsCodeUninstall` and `vsCodeProfiles`: a project's own VS
  Code extension, built as a VSIX, installed into the profile `PROFILE` or
  `--profile` names — checked against VS Code's profiles first, since
  `code --profile` creates a missing one empty. `installVsCodeExtension` and
  `uninstallVsCodeExtension` as functions.
- `bashScript()`: a project's shell script run under bash — on Windows Git's
  bash, never WSL's launcher (`findGitBash`, `runBashScript`).
- `packageTests()`: `flutter test` or `dart test` in each package, by whether
  its pubspec takes anything from the Flutter SDK; a package without `test/` is
  skipped, and a runner not on `PATH` answers `3` (`runPackageTests`,
  `usesFlutter`). The runner's code is translated, not flattened: no test
  ran is `0`, a refused command line or configuration `2`, a suite the run
  stopped `130`, a runner killed by a signal `128` and the signal, a failure
  `1`.
- `pubPublish` and `publishToPub`: a package published to pub after checking
  that the registry does not serve the version yet, the changelog names it,
  the package matches HEAD and git tracks every file pub would upload
  (`publishedFiles`, `untrackedRefusal`); then a wait until the registry
  serves it, answering `4` where the upload happened and the registry has not
  caught up, or where pub failed other than by refusing (`65`) and the
  registry does not show whether it went up. Git is asked from the package,
  so a submodule package and a committed link to a directory publish.
  The registry is pub's: `publish_to:`, `PUB_HOSTED_URL`, pub.dev.
