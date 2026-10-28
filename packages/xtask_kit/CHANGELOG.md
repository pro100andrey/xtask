# Changelog

## 0.1.1

### Added

- `adopt:` on `LinuxApp` and `DartCli`, an `EarlierInstall`: what shows an
  installed directory without the `.xtask_kit` mark to be the project's own
  install from before it used this package — a command on `PATH` linking into
  it, or a file only that install wrote. Such a directory is replaced and
  removed like a marked one, so the first install after the move no longer
  refuses it; without the evidence it is refused as before, and so is one
  whose mark names another owner. `notOurDirectory` and `replaceDirectory`
  take the same evidence.
- `forbiddenLibraries:` on `DartCli`: native libraries a bundle must not
  carry, by bundle; the install refuses one that does before copying.
- `afterInstall:` and `beforeUninstall:` on `DartCli`, each a `CliStep` run
  with the `CliPlaces` the tool is installed to: a project's own step after a
  successful install, answering for it, and before an uninstall removes
  anything, stopping it where it fails.
- `uninstallCliWithOutcome` and `Uninstalled`: what a CLI uninstall came to
  — `removed`, `nothing` or `foreign` — which its exit code, `0` for all
  three, does not say; and `afterUninstall:` on `DartCli`, a
  `CliUninstallStep` run after an uninstall that answered `0`, handed that
  outcome. An uninstall with nothing to remove now says so rather than
  `✓ removed`.
- `findBash(context)`: the bash the `bash` verb runs a script under — `bash`
  off Windows, Git's on it — found from a verb's context, for a verb that
  starts bash itself, without handing `findGitBash` its lookups by hand.
- `foreignRetired: ForeignRetired.leave` on `DartCli`: a file under a
  `retired:` name the install did not lay down is left, with a warning,
  rather than refusing the install, which stays the default.

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
  `usesFlutter`). The runner's code is translated, not flattened: a refused
  command line or configuration is `2`, a suite the run stopped `130`, a
  runner killed by a signal `128` and the signal, a failure `1` — and so is a
  filter that chose no test, unless the verb was registered with
  `allowNoTests: true`.
- `pubPublish` and `publishToPub`: a package published to pub after checking
  that the registry does not serve the version yet, the changelog names it,
  the package matches HEAD and git tracks every file pub would upload
  (`publishedFiles`, `untrackedRefusal`); then a wait until the registry
  serves it, answering `4` where the upload happened and the registry has not
  caught up, or where pub failed other than by refusing (`65`) and the
  registry does not show whether it went up. Git is asked from the package,
  so a submodule package and a committed link to a directory publish.
  The registry is pub's: `publish_to:`, `PUB_HOSTED_URL`, pub.dev.
