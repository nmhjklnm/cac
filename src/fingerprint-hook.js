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
    const macParts = fakeMac.split(':').map(h => parseInt(h, 16));
    let ifIdx = 0;
    for (const name of Object.keys(ifaces)) {
      for (const info of ifaces[name]) {
        if (info.mac && info.mac !== '00:00:00:00:00:00') {
          // Derive per-interface MAC: XOR last octet with interface index
          const derived = macParts.slice();
          derived[5] = (derived[5] ^ ifIdx) & 0xff;
          info.mac = derived.map(b => b.toString(16).padStart(2, '0')).join(':');
        }
      }
      ifIdx++;
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

// --- Repository fingerprint (rh) interception ---
// Claude Code computes rh = SHA256(normalized_git_remote_url).hex.slice(0,16)
// and sends it with every 1p_event — cross-account linkage vector.
//
// CC 2.1.88 reads the remote URL via gitFilesystem.ts which calls
// fs.readFileSync('.git/config') directly — NOT via git subprocess.
// We intercept both paths for defense in depth.
const fakeGitRemote = process.env.CAC_FAKE_GIT_REMOTE;
if (fakeGitRemote) {
  // Path 1: intercept .git/config reads (primary path in CC 2.1.88)
  // Replaces the [remote "origin"] url line with our fake remote URL.
  function isGitConfigPath(p) {
    var s = typeof p === 'string' ? p : (p && p.toString ? p.toString() : '');
    return s === '.git/config' || s.endsWith('/.git/config') || s.endsWith('\\.git\\config');
  }
  function patchGitConfig(content) {
    var str = typeof content === 'string' ? content : content.toString('utf8');
    // Replace url = <anything> under [remote "origin"] section
    str = str.replace(
      /(\[remote\s+"origin"\][^\[]*?url\s*=\s*)[^\n]*/,
      '$1' + fakeGitRemote
    );
    return str;
  }

  // Patch readFileSync (sync path used by gitFilesystem.ts)
  var _origReadFileSyncRh = fs.readFileSync;
  fs.readFileSync = function(path, options) {
    var result = _origReadFileSyncRh.apply(fs, arguments);
    if (isGitConfigPath(path)) {
      var patched = patchGitConfig(result);
      return fakeResult(options, patched);
    }
    return result;
  };

  // Patch fs.promises.readFile (async path)
  try {
    var fspRh = require('fs').promises || require('fs/promises');
    if (fspRh && fspRh.readFile) {
      var _origPromiseReadFileRh = fspRh.readFile.bind(fspRh);
      fspRh.readFile = function(path, options) {
        if (isGitConfigPath(path)) {
          return _origPromiseReadFileRh(path, options).then(function(content) {
            return fakeResult(options, patchGitConfig(content));
          });
        }
        return _origPromiseReadFileRh(path, options);
      };
    }
  } catch (_) {}

  // Path 2: intercept git subprocess calls (fallback / older CC versions)
  const GIT_REMOTE_PATTERNS = [
    /git\s+remote\s+get-url/i,
    /git\s+remote\s+-v/i,
    /git\s+config\s+--get\s+remote\..*\.url/i,
    /git\s+ls-remote\s+--get-url/i,
  ];
  function isGitRemoteCmd(cmdStr) {
    return GIT_REMOTE_PATTERNS.some(function(p) { return p.test(cmdStr); });
  }

  const _origExecSyncFp = child_process.execSync.bind(child_process);
  child_process.execSync = function(cmd, options) {
    var cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    if (isGitRemoteCmd(cmdStr)) return fakeResult(options, fakeGitRemote + '\n');
    return _origExecSyncFp(cmd, options);
  };

  const _origExecFp = child_process.exec.bind(child_process);
  child_process.exec = function(cmd) {
    var args = Array.prototype.slice.call(arguments);
    var cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    var cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
    if (isGitRemoteCmd(cmdStr)) {
      if (cb) process.nextTick(cb, null, fakeGitRemote + '\n', '');
      return makeFakeChildProcess();
    }
    return _origExecFp.apply(child_process, args);
  };

  const _origExecFileSyncFp = child_process.execFileSync.bind(child_process);
  child_process.execFileSync = function(file, argsOrOpts, options) {
    var fileArgs = Array.isArray(argsOrOpts) ? argsOrOpts : [];
    var fullCmd = file + ' ' + fileArgs.join(' ');
    if (isGitRemoteCmd(fullCmd)) {
      var opts = Array.isArray(argsOrOpts) ? options : argsOrOpts;
      return fakeResult(opts, fakeGitRemote + '\n');
    }
    return _origExecFileSyncFp(file, argsOrOpts, options);
  };
}

// --- Git email interception ---
// Claude Code runs `git config --get user.email` on startup (yM8 line 159222)
// Intercept to prevent real email leakage (wrapper also sets GIT_AUTHOR_EMAIL)
const fakeGitEmail = process.env.CAC_GIT_EMAIL;
if (fakeGitEmail) {
  var _prevExecSync = child_process.execSync;
  child_process.execSync = function(cmd, options) {
    var cmdStr = typeof cmd === 'string' ? cmd : cmd.toString();
    if (/git\s+config\s+(--global\s+|--get\s+)*user\.email/i.test(cmdStr)) {
      return fakeResult(options, fakeGitEmail + '\n');
    }
    return _prevExecSync(cmd, options);
  };
}

// --- Docker/container environment detection bypass ---
// Claude Code checks /.dockerenv and /proc/1/cgroup to detect Docker
// In Docker mode with persona, we hide container signals
if (process.env.CAC_HIDE_DOCKER === '1') {
  const _origExistsSync = fs.existsSync.bind(fs);
  fs.existsSync = function(p) {
    var ps = typeof p === 'string' ? p : (p && p.toString ? p.toString() : '');
    if (ps === '/.dockerenv') return false;
    return _origExistsSync(p);
  };

  // Intercept /proc/1/cgroup reads to remove docker references
  var _prevReadFileSync = fs.readFileSync;
  fs.readFileSync = function(path, options) {
    var ps = typeof path === 'string' ? path : (path && path.toString ? path.toString() : '');
    if (ps === '/proc/1/cgroup') {
      var content;
      try { content = _prevReadFileSync(path, options); } catch(e) { throw e; }
      var str = typeof content === 'string' ? content : content.toString();
      str = str.replace(/docker|containerd|kubepods/gi, 'system.slice');
      return fakeResult(options, str);
    }
    return _prevReadFileSync(path, options);
  };
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
