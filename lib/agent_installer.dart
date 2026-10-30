/// Detects local agent clients and installs a product's integration (MCP
/// server, hooks, instructions, skills, permissions) into selected clients.
library;

export 'src/extensions.dart'
    show
        ExtensionFile,
        ExtensionProblem,
        defaultBackupsDirectory,
        defaultExtensionsDirectory,
        defaultSharedDirectory;
export 'src/environment.dart' show InstallEnvironment;
export 'src/errors.dart' show AgentInstallException;
export 'src/installer.dart'
    show
        AgentInstaller,
        ClientResult,
        ClientStatus,
        ComponentStatus,
        PlannedChange,
        TargetScan,
        scanTargets;
export 'src/json_edit.dart' show JsonEdit;
export 'src/manifest.dart' show ProductManifest;
export 'src/targets.dart'
    show InstallTarget, InstallTargets, builtinInstallTargets, hookEvents;
