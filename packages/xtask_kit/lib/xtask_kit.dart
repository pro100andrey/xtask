/// `xtask_kit` — verbs for `xtask` that projects otherwise write again each.
///
/// A verb here is configured in Dart and registered like a project's own:
///
/// ```dart
/// exitCode = await runXtask(args, verbs: {
///   'install': linuxAppInstall(app),
///   'uninstall': linuxAppUninstall(app),
/// });
/// ```
///
/// What it installs is data the project hands over — names and paths — and
/// what the task file says is still only `do: install`. Building is a task of
/// its own, which the install `needs:`.
library;

export 'src/bash.dart' show bashScript, findGitBash, runBashScript;
export 'src/cli.dart'
    show
        CliPlaces,
        DartCli,
        cliInstall,
        cliUninstall,
        conflictingLibraries,
        installCli,
        uninstallCli;
export 'src/home.dart' show dataHome, homeOf;
export 'src/linux_app.dart'
    show
        IconFiles,
        IconTree,
        LinuxApp,
        LinuxAppPlaces,
        LinuxIcons,
        installedDesktopEntry,
        linuxAppInstall,
        linuxAppUninstall,
        missingFromBundle;
export 'src/on_path.dart' show onPathLine;
export 'src/package_tests.dart' show packageTests, runPackageTests, usesFlutter;
export 'src/publish.dart'
    show
        PubPackage,
        RegistryProbe,
        RegistryUnavailable,
        askRegistry,
        changelogNames,
        manifestField,
        pubPublish,
        publishToPub,
        publishedFiles,
        registryWaits,
        servedVersions,
        uncommittedRefusal,
        untrackedRefusal;
export 'src/replace.dart'
    show notALink, notOurLink, pointLink, replaceDirectory;
export 'src/vscode.dart'
    show
        ProfileNames,
        VsCodeExtension,
        VsCodeManifest,
        installVsCodeExtension,
        installedVersion,
        profileArgs,
        readProfileNames,
        uninstallVsCodeExtension,
        vsCodeInstall,
        vsCodeProfiles,
        vsCodeUninstall,
        vsCodeUserDir;
