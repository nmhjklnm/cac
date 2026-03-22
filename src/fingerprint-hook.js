// This file is injected via NODE_OPTIONS="--require /path/to/fingerprint-hook.js"
// It monkey-patches Node.js system APIs to return spoofed device identifiers.
// Works on macOS, Linux, and Windows.

const os = require('os');
const fs = require('fs');
const child_process = require('child_process');

// --- os.hostname() ---
const fakeHostname = process.env.FKCLAUDE_HOSTNAME;
if (fakeHostname) {
  os.hostname = () => fakeHostname;
}

// --- os.networkInterfaces() ---
const fakeMac = process.env.FKCLAUDE_MAC;
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
const fakeUsername = process.env.FKCLAUDE_USERNAME;
if (fakeUsername) {
  const _origUserInfo = os.userInfo.bind(os);
  os.userInfo = (opts) => {
    const info = _origUserInfo(opts);
    info.username = fakeUsername;
    return info;
  };
}

// --- fs.readFileSync intercept for /etc/machine-id ---
const fakeMachineId = process.env.FKCLAUDE_MACHINE_ID;
if (fakeMachineId) {
  const _origReadFileSync = fs.readFileSync.bind(fs);
  fs.readFileSync = (path, options) => {
    const p = typeof path === 'string' ? path : path.toString();
    if (p === '/etc/machine-id' || p === '/var/lib/dbus/machine-id') {
      return typeof options === 'string' || (options && options.encoding)
        ? fakeMachineId + '\n'
        : Buffer.from(fakeMachineId + '\n');
    }
    return _origReadFileSync(path, options);
  };
  // Also patch fs.readFile (async version)
  const _origReadFile = fs.readFile.bind(fs);
  fs.readFile = (path, ...args) => {
    const p = typeof path === 'string' ? path : path.toString();
    if (p === '/etc/machine-id' || p === '/var/lib/dbus/machine-id') {
      const cb = args[args.length - 1];
      if (typeof cb === 'function') {
        const options = args.length > 1 ? args[0] : null;
        const result = typeof options === 'string' || (options && options.encoding)
          ? fakeMachineId + '\n'
          : Buffer.from(fakeMachineId + '\n');
        process.nextTick(cb, null, result);
        return;
      }
    }
    return _origReadFile(path, ...args);
  };
}

// --- Windows: intercept child_process for wmic / reg queries ---
if (process.platform === 'win32' && fakeMachineId) {
  // Intercept execSync to catch wmic and reg query calls for MachineGuid
  const _origExecSync = child_process.execSync.bind(child_process);
  child_process.execSync = (cmd, options) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    // wmic csproduct get UUID
    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      const result = `UUID\n${fakeMachineId}\n`;
      return (options && options.encoding) ? result : Buffer.from(result);
    }
    // reg query for MachineGuid
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      const result = `    MachineGuid    REG_SZ    ${fakeMachineId}\n`;
      return (options && options.encoding) ? result : Buffer.from(result);
    }
    return _origExecSync(cmd, options);
  };

  // Intercept exec (async) for the same patterns
  const _origExec = child_process.exec.bind(child_process);
  child_process.exec = (cmd, ...args) => {
    const cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;

    if (/wmic\s+csproduct\s+get\s+uuid/i.test(cmdStr)) {
      if (cb) { process.nextTick(cb, null, `UUID\n${fakeMachineId}\n`, ''); }
      return;
    }
    if (/reg\s+query.*MachineGuid/i.test(cmdStr)) {
      if (cb) { process.nextTick(cb, null, `    MachineGuid    REG_SZ    ${fakeMachineId}\n`, ''); }
      return;
    }
    return _origExec(cmd, ...args);
  };

  // Intercept execFileSync for powershell/cmd invocations querying machine GUID
  const _origExecFileSync = child_process.execFileSync.bind(child_process);
  child_process.execFileSync = (file, args, options) => {
    const fileStr = (typeof file === 'string' ? file : '').toLowerCase();
    const argsStr = Array.isArray(args) ? args.join(' ') : '';
    if ((fileStr.includes('wmic') && /csproduct.*uuid/i.test(argsStr)) ||
        (fileStr.includes('reg') && /MachineGuid/i.test(argsStr))) {
      const result = fakeMachineId + '\n';
      return (options && options.encoding) ? result : Buffer.from(result);
    }
    return _origExecFileSync(file, args, options);
  };
}
