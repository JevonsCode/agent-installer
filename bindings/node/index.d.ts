export type Component = 'mcp' | 'hooks' | 'permissions' | 'instructions' | 'skills' | 'plugin';

export interface ExtensionProblem {
  file?: string;
  message: string;
}

export interface TargetScan {
  id: string;
  name: string;
  detected: boolean;
  /** What showed the client is installed, e.g. `~/.codex/config.toml` or `command: codex`. */
  evidence: string[];
  components: Component[];
  builtin: boolean;
  platformSupported: boolean;
  /** Why the client must be configured by hand. */
  manual?: string;
  extensionFile?: string;
}

export interface ComponentStatus {
  component: Component;
  state: 'current' | 'outdated' | 'missing' | 'conflict' | 'unsupported';
  message?: string;
}

export type ClientState =
  | 'connected' | 'update_available' | 'not_connected' | 'conflict' | 'manual' | 'unsupported';

export interface ClientStatus extends TargetScan {
  state: ClientState;
  componentStates: ComponentStatus[];
}

export interface PlannedChange {
  /** Shown relative to the home directory, e.g. `~/.claude.json`. */
  path: string;
  components: Component[];
  /** `adopt`: an existing directory that already holds the product's files gets its receipt. */
  action: 'create' | 'update' | 'delete' | 'adopt';
  diff?: string;
}

export interface ClientResult {
  id: string;
  name: string;
  state: ClientState;
  changes: PlannedChange[];
  /** Components that could not be changed, with the reason. */
  problems: string[];
  /** What the person still has to do, e.g. restart the client. */
  actions: string[];
}

export interface InstallerOptions {
  /** Absolute path to the native `agent-installer` for this OS and CPU. */
  executable: string;
  /** Absolute path to the product manifest. */
  manifestPath: string;
  /** Values for the manifest's `{placeholders}`. */
  variables?: Record<string, string>;
  /** Defaults to the shared per-user extension directory. */
  extensionsDir?: string;
  /** Where originals are copied before a change. */
  backupsDir?: string;
  timeoutMs?: number;
}

/** Rejections carry the installer error code. */
export interface InstallerError extends Error {
  code: string;
}

export interface Installer {
  scan(): Promise<{ clients: TargetScan[]; extensionErrors: ExtensionProblem[] }>;
  status(clients?: string[]): Promise<{ clients: ClientStatus[]; extensionErrors: ExtensionProblem[] }>;
  /** A dry run: returns the changes and diffs without writing. */
  plan(clients: string[]): Promise<ClientResult[]>;
  /** Writes; call only for clients the person selected. */
  apply(clients: string[]): Promise<ClientResult[]>;
  remove(clients: string[]): Promise<ClientResult[]>;
}

export function createInstaller(options: InstallerOptions): Installer;
