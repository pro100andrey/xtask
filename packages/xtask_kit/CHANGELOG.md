# Changelog

## 0.1.0

### Added

- `linuxAppInstall` and `linuxAppUninstall`: a built Linux app installed for
  the person running it under `~/.local`, linked onto `PATH`, with its menu
  entry and icons — described by a `LinuxApp`, whose icons are an `IconTree`
  or `IconFiles`.
- `cliInstall` and `cliUninstall`, with `installCli` and `uninstallCli` as
  functions: the bundles `dart build cli` leaves, installed into one `bin/`
  and `lib/` under `~/.local/share` with each command on `PATH` — a link, or
  on Windows a copy, with what a running process holds moved aside rather
  than failed on. `conflictingLibraries` is the check that two bundles can
  share one `lib/`.
- `replaceDirectory`, `notALink` and `pointLink`, which the install is made
  of: an installed directory replaced whole, and a link replaced only where it
  is one.
- `onPathLine`: whether the command just installed is the one `PATH` finds,
  something else is, or nothing is.
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
  skipped (`runPackageTests`, `usesFlutter`).
- `pubPublish` and `publishToPub`: a package published to pub after checking
  that the registry does not serve the version yet, the changelog names it,
  and the package matches HEAD; then a wait until the registry serves it,
  answering `4` where the upload happened and the registry has not caught up.
