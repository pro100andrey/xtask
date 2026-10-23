# Changelog

## 0.1.0

### Added

- `linuxAppInstall` and `linuxAppUninstall`: a built Linux app installed for
  the person running it under `~/.local`, linked onto `PATH`, with its menu
  entry and icons — described by a `LinuxApp`, whose icons are an `IconTree`
  or `IconFiles`.
- `replaceDirectory`, `notALink` and `pointLink`, which the install is made
  of: an installed directory replaced whole, and a link replaced only where it
  is one.
- `onPathLine`: whether the command just installed is the one `PATH` finds,
  something else is, or nothing is.
- `homeOf` and `dataHome`.
