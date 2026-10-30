#!/usr/bin/env node
// A minimal stdio MCP server for testing installs: one `ping` tool. Every
// request is appended to ~/.agent-installer-probe/events.log.
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const at = process.argv.indexOf('--client');
const client = at < 0 ? 'unknown' : process.argv[at + 1] ?? 'unknown';
const dir = join(homedir(), '.agent-installer-probe');
const log = entry => {
  mkdirSync(dir, { recursive: true });
  appendFileSync(join(dir, 'events.log'), `${JSON.stringify({ time: new Date().toISOString(), source: 'mcp', client, ...entry })}\n`);
};
const send = message => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);

createInterface({ input: process.stdin }).on('line', line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  const { id, method, params } = request;
  log({ method });
  if (id === undefined) return;
  if (method === 'initialize') {
    send({ id, result: {
      protocolVersion: params?.protocolVersion ?? '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'agent-installer-probe', version: '0.1.0' },
    } });
  } else if (method === 'tools/list') {
    send({ id, result: { tools: [{
      name: 'ping',
      description: 'Replies pong. Part of a temporary agent-installer test.',
      inputSchema: { type: 'object', properties: {} },
    }] } });
  } else if (method === 'tools/call' && params?.name === 'ping') {
    send({ id, result: { content: [{ type: 'text', text: `pong from agent-installer-probe (${client})` }] } });
  } else if (method === 'ping') {
    send({ id, result: {} });
  } else {
    send({ id, error: { code: -32601, message: `Unsupported method ${method}` } });
  }
});
