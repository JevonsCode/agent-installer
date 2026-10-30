#!/usr/bin/env node
// A lifecycle hook for testing installs: records that it ran and prints
// nothing, so it never adds context or blocks the client.
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const arg = name => {
  const at = process.argv.indexOf(name);
  return at < 0 ? 'unknown' : process.argv[at + 1] ?? 'unknown';
};
const dir = join(homedir(), '.agent-installer-probe');
mkdirSync(dir, { recursive: true });
appendFileSync(join(dir, 'events.log'), `${JSON.stringify({
  time: new Date().toISOString(), source: 'hook', client: arg('--client'), event: arg('--event'),
})}\n`);
process.stdin.resume();
process.stdin.on('data', () => {});
process.stdin.on('end', () => process.exit(0));
setTimeout(() => process.exit(0), 500);
