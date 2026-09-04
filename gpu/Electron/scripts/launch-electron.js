#!/usr/bin/env node
const { spawn } = require('child_process');
const electron = require('electron');

const extraArgs = process.argv.slice(2);
const nofileTarget = 10240;

function forwardExit(child) {
  child.on('exit', (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code ?? 0);
  });
}

if (process.platform === 'win32') {
  forwardExit(spawn(electron, ['.', ...extraArgs], { stdio: 'inherit', env: process.env }));
} else {
  forwardExit(
    spawn(
      '/bin/sh',
      ['-c', `ulimit -n ${nofileTarget} 2>/dev/null || true; exec "$0" "$@"`, electron, '.', ...extraArgs],
      { stdio: 'inherit', env: process.env },
    ),
  );
}
