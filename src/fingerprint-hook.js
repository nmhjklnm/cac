// This file is injected via NODE_OPTIONS="--require /path/to/fingerprint-hook.js"
// It monkey-patches Node.js system APIs to return spoofed device identifiers.
// Reads from CAC_HOSTNAME, CAC_MAC, CAC_MACHINE_ID, CAC_USERNAME env vars.
// Works on macOS, Linux, and Windows.

const os = require('os');
const fs = require('fs');
const child_process = require('child_process');

// --- os.hostname() ---
const fakeHostname = process.env.CAC_HOSTNAME;
if (fakeHostname) {
  os.hostname = () => fakeHostname;
}

// --- os.networkInterfaces() ---
const fakeMac = process.env.CAC_MAC;
if (fakeMac) {
  const _origNetworkInterfaces = os.networkInterfaces.bind(os);
  os.networkInterfaces = () => {
    const ifaces = _origNetworkInterfaces();
    for (const name of Object.keys(ifaces)) {
      for (const info of ifaces[name]) {
        if (info.mac && info.mac !== '00:00:00:00:00:00') {
          info.mac = fakeMac;
        }
      }
    }
    return ifaces;
  };
}

// --- os.userInfo() ---
const fakeUsername = process.env.CAC_USERNAME;
if (fakeUsername) {
  const _origUserInfo = os.userInfo.bind(os);
  os.userInfo = (opts) => {
    const info = _origUserInfo(opts);
    info.username = fakeUsername;
    return info;
  };
}

// --- machine-id interception helpers ---
const MACHINE_ID_PATHS = ['/etc/machine-id', '/var/lib/dbus/machine-id'];
function isMachineIdPath(p) {
  const s = typeof p === 'string' ? p : (p && p.toString ? p.toString() : '');
  return MACHINE_ID_PATHS.includes(s);
}
function fakeResult(options, data) {
  return (typeof options === 'string' || (options && options.encoding))
    ? data : Buffer.from(data);
}

// --- fs.readFileSync / fs.readFile / fs.promises.readFile ---
const fakeMachineId = process.env.CAC_MACHINE_ID;
if (fakeMachineId) {
  const fakeData = fakeMachineId + '\n';

  const _origReadFileSync = fs.readFileSync.bind(fs);
  fs.readFileSync = (path, options) => {
    if (isMachineIdPath(path)) return fakeResult(options, fakeData);
    return _origReadFileSync(path, options);
  };

  const _origReadFile = fs.readFile.bind(fs);
  fs.readFile = (path, ...args) => {
    if (isMachineIdPath(path)) {
      const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (cb) {
        const opts = args.length > 1 ? args[0] : null;
        process.nextTick(cb, null, fakeResult(opts, fakeData));
        return;
      }
    }
    return _origReadFile(path, ...args);
  };

  // Patch fs.promises.readFile (used by modern Node.js code)
  try {
    const fsp = require('fs').promises || require('fs/promises');
    if (fsp && fsp.readFile) {
      const _origPromiseReadFile = fsp.readFile.bind(fsp);
      fsp.readFile = (path, options) => {
        if (isMachineIdPath(path)) {
          return Promise.resolve(fakeResult(options, fakeData));
        }
        return _origPromiseReadFile(path, options);
      };
    }
  } catch (_) { /* fs/promises not available on older Node */ }
}

// --- Windows: intercept child_process for wmic / reg queries ---
function makeFakeChildProcess() {
  const { EventEmitter } = require('events');
  const cp = new EventEmitter();
  cp.stdout = new EventEmitter();
  cp.stderr = new EventEmitter();
  cp.stdin = null;
  cp.stdio = [null, cp.stdout, cp.stderr];
  cp.pid = 0;
  cp.exitCode = null;
  cp.signalCode = null;
  cp.killed = false;
  cp.spawnargs = [];
  cp.spawnfile = '';
  cp.kill = () => false;
  return cp;
}

if (process.platform === 'win32' && fakeMachineId) {
  const _origExecSync = child_process.execSync.bind(child_process);
  child_process.execSync = (cmd, options) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      return fakeResult(options, `UUID\n${fakeMachineId}\n`);
    }
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      return fakeResult(options, `    MachineGuid    REG_SZ    ${fakeMachineId}\n`);
    }
    return _origExecSync(cmd, options);
  };

  const _origExec = child_process.exec.bind(child_process);
  child_process.exec = (cmd, ...args) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      if (cb) process.nextTick(cb, null, `UUID\n${fakeMachineId}\n`, '');
      return makeFakeChildProcess();
    }
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      if (cb) process.nextTick(cb, null, `    MachineGuid    REG_SZ    ${fakeMachineId}\n`, '');
      return makeFakeChildProcess();
    }
    return _origExec(cmd, ...args);
  };

  const _origExecFileSync = child_process.execFileSync.bind(child_process);
  child_process.execFileSync = (file, argsOrOpts, options) => {
    // Handle optional args parameter: execFileSync(file[, args][, options])
    let args = argsOrOpts;
    let opts = options;
    if (!Array.isArray(argsOrOpts) && typeof argsOrOpts === 'object') {
      args = [];
      opts = argsOrOpts;
    }
    const fileStr = (typeof file === 'string' ? file : '').toLowerCase();
    const argsStr = Array.isArray(args) ? args.join(' ') : '';
    if ((fileStr.includes('wmic') && /csproduct.*uuid/i.test(argsStr)) ||
        (fileStr.includes('reg') && /MachineGuid/i.test(argsStr))) {
      return fakeResult(opts, fakeMachineId + '\n');
    }
    return _origExecFileSync(file, argsOrOpts, options);
  };
}
