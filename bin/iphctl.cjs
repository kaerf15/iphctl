#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const { join } = require('node:path');

if (process.platform !== 'darwin') {
  console.error('iphctl requires macOS with iPhone Mirroring support.');
  process.exit(1);
}

const result = spawnSync(join(__dirname, '..', 'native', 'iphctl'), process.argv.slice(2), {
  stdio: 'inherit',
});

if (result.error) {
  console.error(`Unable to start iphctl: ${result.error.message}`);
  process.exit(1);
}

if (result.signal) {
  process.kill(process.pid, result.signal);
} else {
  process.exit(result.status ?? 1);
}
