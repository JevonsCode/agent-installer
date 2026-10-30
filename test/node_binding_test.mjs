import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInstaller, defaultBackupsDirectory, defaultExtensionsDirectory } from '../bindings/node/index.mjs';

const executable = process.env.AGENT_INSTALLER_BIN;
if (!executable) throw new Error('Set AGENT_INSTALLER_BIN to the compiled agent-installer.');
const bundle = resolve('example/acme');

// The executable inherits this process's environment: point every home and
// configuration root at a temporary directory so no real client is touched.
async function withHome(run) {
  const home = await mkdtemp(join(tmpdir(), 'agent-installer-node-'));
  const saved = { ...process.env };
  Object.assign(process.env, {
    HOME: home, USERPROFILE: home, APPDATA: join(home, 'AppData'),
    XDG_CONFIG_HOME: join(home, '.config'), CODEX_HOME: '', OPENCODE_CONFIG: '',
  });
  try { await run(home); } finally {
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
    Object.assign(process.env, saved);
    await rm(home, { recursive: true, force: true });
  }
}

test('Node host scans, plans, applies and removes for selected clients', () => withHome(async home => {
  await mkdir(join(home, '.cursor'));
  const installer = createInstaller({
    executable,
    manifestPath: join(bundle, 'acme.manifest.json'),
    variables: { acmeMcp: '/opt/acme/bin/acme_mcp', bundle },
    extensionsDir: join(home, 'ext'),
    backupsDir: join(home, 'backups'),
  });
  const { clients } = await installer.scan();
  assert.equal(clients.find(c => c.id === 'cursor').detected, true);
  const planned = await installer.plan(['cursor']);
  assert.equal(planned.partial, false);
  assert.deepEqual(planned.problems, []);
  const [plan] = planned.clients;
  assert.equal(plan.state, 'not_connected');
  assert.ok(plan.changes.some(c => c.path === '~/.cursor/mcp.json' && c.action === 'create'));
  assert.equal(existsSync(join(home, '.cursor', 'mcp.json')), false);

  const [applied] = (await installer.apply(['cursor'])).clients;
  assert.equal(applied.state, 'connected');
  assert.deepEqual(applied.actionCodes, applied.actions.map(() => 'reload_config'));
  assert.deepEqual(JSON.parse(await readFile(join(home, '.cursor', 'mcp.json'), 'utf8')).mcpServers.acme.args,
    ['--source', 'Cursor']);
  const { clients: states } = await installer.status(['cursor']);
  assert.equal(states[0].state, 'connected');
  assert.ok(states[0].componentStates.every(c => ['current', 'unsupported'].includes(c.state)));

  const [removed] = (await installer.remove(['cursor'])).clients;
  assert.equal(removed.state, 'not_connected');
  assert.equal(existsSync(join(home, '.cursor', 'mcp.json')), false);
}));

test('a partial apply resolves with partial and the problems', () => withHome(async home => {
  await mkdir(join(home, '.cursor'));
  const foreign = '{"mcpServers":{"acme":{"command":"other-tool"}}}\n';
  await writeFile(join(home, '.cursor', 'mcp.json'), foreign);
  const installer = createInstaller({
    executable,
    manifestPath: join(bundle, 'acme.manifest.json'),
    variables: { acmeMcp: '/opt/acme/bin/acme_mcp', bundle },
    extensionsDir: join(home, 'ext'),
    backupsDir: join(home, 'backups'),
  });
  const result = await installer.apply(['cursor']);
  assert.equal(result.partial, true);
  assert.equal(result.problems.length, 1);
  assert.equal(result.problems[0].client, 'cursor');
  assert.match(result.problems[0].message, /already named "acme"/);
  assert.equal(await readFile(join(home, '.cursor', 'mcp.json'), 'utf8'), foreign);
  assert.ok(existsSync(join(home, '.cursor', 'skills', 'acme-helper')), 'other components were installed');
}));

test('Node host receives structured installer errors, always asynchronously', () => withHome(async home => {
  const bad = join(home, 'bad.json');
  await writeFile(bad, '{"schemaVersion":2}');
  const installer = createInstaller({ executable, manifestPath: bad, extensionsDir: join(home, 'ext') });
  await assert.rejects(() => installer.plan(['cursor']), error => error.code === 'invalid_manifest');
  await assert.rejects(async () => installer.apply([]), error => error.code === 'invalid_arguments');

  const relative = createInstaller({ executable, manifestPath: 'relative.json' });
  await assert.rejects(relative.scan(), error => error instanceof Error && error.code === 'invalid_arguments');
  const slow = createInstaller({ executable, manifestPath: bad, timeoutMs: 0 });
  await assert.rejects(slow.scan(), error => error.code === 'invalid_timeout');
  // No process answers within 1 ms: the outcome is unknown and nothing retries.
  const hurried = createInstaller({ executable, manifestPath: bad, extensionsDir: join(home, 'ext'), timeoutMs: 1 });
  await assert.rejects(hurried.scan(), error => error.code === 'unknown_outcome');
  const missing = createInstaller({ executable: join(home, 'no-such-installer'), manifestPath: bad });
  await assert.rejects(missing.scan(), error => error.code === 'unavailable');
}));

test('the default directories are the shared agent-clients convention', () => withHome(async home => {
  assert.equal(defaultExtensionsDirectory({ HOME: '/Users/a' }, 'darwin'), '/Users/a/.config/agent-clients/extensions');
  assert.equal(defaultExtensionsDirectory({ HOME: '/h', XDG_CONFIG_HOME: '/x' }, 'linux'), '/x/agent-clients/extensions');
  assert.equal(defaultExtensionsDirectory({ HOME: '/h', XDG_CONFIG_HOME: 'x' }, 'linux'), '/h/.config/agent-clients/extensions');
  assert.equal(defaultExtensionsDirectory({ APPDATA: 'C:\\Users\\a\\AppData\\Roaming' }, 'win32'),
    'C:\\Users\\a\\AppData\\Roaming\\agent-clients\\extensions');
  assert.equal(defaultBackupsDirectory('acme', { APPDATA: 'C:\\R' }, 'win32'), 'C:\\R\\agent-clients\\backups\\acme');
  assert.equal(defaultBackupsDirectory('acme', { HOME: '/h' }, 'linux'), '/h/.config/agent-clients/backups/acme');
  assert.equal(defaultExtensionsDirectory({}, 'linux'), undefined);

  // The old directory is read until the new one exists, and is never moved.
  const env = { APPDATA: home, XDG_CONFIG_HOME: home, HOME: home };
  const current = join(home, 'agent-clients', 'extensions');
  const legacy = join(home, 'agent-session-launcher', 'clients');
  assert.equal(defaultExtensionsDirectory(env, process.platform), current);
  await mkdir(legacy, { recursive: true });
  assert.equal(defaultExtensionsDirectory(env, process.platform), legacy);
  await mkdir(current, { recursive: true });
  assert.equal(defaultExtensionsDirectory(env, process.platform), current);
  assert.ok(existsSync(legacy));
}));
