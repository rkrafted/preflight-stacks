#!/usr/bin/env node
// Runs preflight and prints one JSON envelope, so n8n never has to interpret an exit code or a
// shell. `preflight stack plan` exits 3 when the stack does not fit the build, and n8n's Execute
// Command node treats any non-zero exit as a node error - which would hide the JSON that explains
// why. This wrapper always exits 0 and reports the child's code in the envelope.
//
//   node run-preflight.js <preflight.exe> stack plan "<stack>" --game "<game>" --json
//   {"exitCode":3,"stdout":"{...}","stderr":""}

'use strict';

const { spawnSync } = require('child_process');

const argv = process.argv.slice(2);
if (argv.length < 2) {
  process.stdout.write(JSON.stringify({ exitCode: 2, stdout: '', stderr: 'usage: run-preflight.js <preflight> <args...>' }));
  process.exit(0);
}

const [binary, ...args] = argv;
const result = spawnSync(binary, args, { encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024 });

if (result.error) {
  process.stdout.write(JSON.stringify({ exitCode: 2, stdout: '', stderr: String(result.error.message || result.error) }));
  process.exit(0);
}

process.stdout.write(
  JSON.stringify({
    exitCode: result.status === null ? 2 : result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  }),
);
