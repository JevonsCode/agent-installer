import { spawn } from 'node:child_process';
import { isAbsolute } from 'node:path';

const MAX_BYTES = 4 * 1024 * 1024;

/**
 * Bind the native `agent-installer` executable and a product manifest once,
 * then call `scan`, `status`, `plan`, `apply` and `remove`. Failures reject
 * with an Error whose `code` is the installer error code. `apply` and
 * `remove` change files: call them only after the person chose the clients.
 */
export function createInstaller({
  executable, manifestPath, variables = {}, extensionsDir, backupsDir, timeoutMs = 60000,
} = {}) {
  for (const [name, path] of [['executable', executable], ['manifestPath', manifestPath]]) {
    if (typeof path !== 'string' || !isAbsolute(path)) {
      throw installerError('invalid_arguments', `${name} must be an absolute path.`);
    }
  }
  for (const [name, path] of [['extensionsDir', extensionsDir], ['backupsDir', backupsDir]]) {
    if (path !== undefined && (typeof path !== 'string' || !isAbsolute(path))) {
      throw installerError('invalid_arguments', `${name} must be an absolute path.`);
    }
  }
  const common = [
    ...(extensionsDir === undefined ? [] : ['--extensions', extensionsDir]),
    '--json',
  ];
  const product = [
    '--product', manifestPath,
    ...Object.entries(variables).flatMap(([key, value]) => ['--var', `${key}=${value}`]),
    ...(backupsDir === undefined ? [] : ['--backups', backupsDir]),
  ];
  const clientArgs = clients => {
    if (!Array.isArray(clients) || clients.length === 0 || clients.some(c => typeof c !== 'string')) {
      throw installerError('invalid_arguments', 'Select at least one client ID.');
    }
    return ['--clients', clients.join(',')];
  };
  const call = async args => {
    const result = await runInstaller(executable, [...args, ...common], timeoutMs);
    if (!result.ok) throw installerError(result.error.code, result.error.message);
    return result;
  };
  return {
    scan: async () => {
      const { clients, extensionErrors } = await call(['scan']);
      return { clients, extensionErrors };
    },
    status: async clients => {
      const { clients: states, extensionErrors } = await call([
        'status', ...product, ...(clients === undefined ? [] : clientArgs(clients)),
      ]);
      return { clients: states, extensionErrors };
    },
    plan: async clients => (await call(['plan', ...product, ...clientArgs(clients)])).clients,
    apply: async clients => (await call(['apply', ...product, ...clientArgs(clients)])).clients,
    remove: async clients => (await call(['remove', ...product, ...clientArgs(clients)])).clients,
  };
}

function runInstaller(executable, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const chunks = [];
    let bytes = 0;
    let done = false;
    const timer = setTimeout(() => finish(installerError('unknown_outcome',
      'The installer timed out; check status before trying again.'), true), timeoutMs);
    function finish(error, kill = false, value) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (kill) child.kill();
      if (error) reject(error); else resolve(value);
    }
    child.on('error', () => finish(installerError('unavailable', 'The installer executable could not start.')));
    child.stdout.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > MAX_BYTES) finish(installerError('invalid_response', 'The installer response is too large.'), true);
      else chunks.push(chunk);
    });
    child.on('close', () => {
      if (done) return;
      let result;
      try { result = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { return finish(installerError('invalid_response', 'The installer did not return JSON.')); }
      if (!result || result.version !== 1 || typeof result.ok !== 'boolean') {
        return finish(installerError('invalid_response', 'The installer returned an invalid response.'));
      }
      finish(null, false, result);
    });
  });
}

function installerError(code, message) {
  return Object.assign(new Error(message), { code });
}
