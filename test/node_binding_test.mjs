import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInstaller } from '../bindings/node/index.mjs';

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
  const [plan] = await installer.plan(['cursor']);
  assert.equal(plan.state, 'not_connected');
  assert.ok(plan.changes.some(c => c.path === '~/.cursor/mcp.json' && c.action === 'create'));
  assert.equal(existsSync(join(home, '.cursor', 'mcp.json')), false);

  const [applied] = await installer.apply(['cursor']);
  assert.equal(applied.state, 'connected');
  assert.deepEqual(JSON.parse(await readFile(join(home, '.cursor', 'mcp.json'), 'utf8')).mcpServers.acme.args,
    ['--source', 'Cursor']);
  const { clients: states } = await installer.status(['cursor']);
  assert.equal(states[0].state, 'connected');
  assert.ok(states[0].componentStates.every(c => ['current', 'unsupported'].includes(c.state)));

  const [removed] = await installer.remove(['cursor']);
  assert.equal(removed.state, 'not_connected');
  assert.equal(existsSync(join(home, '.cursor', 'mcp.json')), false);
}));

test('Node host receives structured installer errors', () => withHome(async home => {
  const bad = join(home, 'bad.json');
  await writeFile(bad, '{"schemaVersion":2}');
  const installer = createInstaller({ executable, manifestPath: bad, extensionsDir: join(home, 'ext') });
  await assert.rejects(() => installer.plan(['cursor']), error => error.code === 'invalid_manifest');
  assert.throws(() => createInstaller({ executable, manifestPath: 'relative.json' }),
    error => error.code === 'invalid_arguments');
  await assert.rejects(async () => installer.apply([]), error => error.code === 'invalid_arguments');
}));
