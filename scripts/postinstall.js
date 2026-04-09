#!/usr/bin/env node
var path = require('path');
var fs = require('fs');
var childProcess = require('child_process');

var pkgDir = path.join(__dirname, '..');
var cacBin = path.join(pkgDir, 'cac');
var home = process.env.HOME || process.env.USERPROFILE || '';
var cacDir = path.join(home, '.cac');

function findWindowsBash() {
  if (process.platform !== 'win32') return null;

  var seen = Object.create(null);
  var candidates = [];

  function addCandidate(candidate) {
    if (!candidate) return;
    var normalized = path.normalize(candidate);
    if (seen[normalized]) return;
    seen[normalized] = true;
    candidates.push(normalized);
  }

  [process.env.ProgramFiles, process.env.ProgramW6432].forEach(function (base) {
    if (base) addCandidate(path.join(base, 'Git', 'bin', 'bash.exe'));
  });

  if (process.env.LocalAppData) {
    addCandidate(path.join(process.env.LocalAppData, 'Programs', 'Git', 'bin', 'bash.exe'));
    addCandidate(path.join(process.env.LocalAppData, 'Git', 'bin', 'bash.exe'));
  }

  try {
    var gitWhere = childProcess.spawnSync('where.exe', ['git.exe'], { encoding: 'utf8', windowsHide: true });
    if (gitWhere.status === 0 && gitWhere.stdout) {
      gitWhere.stdout.split(/\r?\n/).forEach(function (line) {
        var gitExe = line.trim();
        if (gitExe) addCandidate(path.resolve(path.dirname(gitExe), '..', 'bin', 'bash.exe'));
      });
    }
  } catch (e) {}

  try {
    var bashWhere = childProcess.spawnSync('where.exe', ['bash.exe'], { encoding: 'utf8', windowsHide: true });
    if (bashWhere.status === 0 && bashWhere.stdout) {
      bashWhere.stdout.split(/\r?\n/).forEach(function (line) {
        var bashExe = line.trim();
        if (bashExe && bashExe.toLowerCase().indexOf('\\windowsapps\\') === -1) addCandidate(bashExe);
      });
    }
  } catch (e) {}

  for (var i = 0; i < candidates.length; i++) {
    if (fs.existsSync(candidates[i])) return candidates[i];
  }

  return null;
}

// Ensure cac is executable
try { fs.chmodSync(cacBin, 0o755); } catch (e) {}

// Auto-sync runtime files on install/upgrade
// Pure Node.js — no bash/zsh dependency
// Ensures bug fixes (dns-guard, relay, fingerprint-hook) take effect immediately
try {
  fs.mkdirSync(cacDir, { recursive: true });
  var files = ['cac-dns-guard.js', 'relay.js', 'fingerprint-hook.js'];
  for (var i = 0; i < files.length; i++) {
    var src = path.join(pkgDir, files[i]);
    var dst = path.join(cacDir, files[i]);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, dst);
    }
  }
} catch (e) {
  // Non-fatal — _ensure_initialized will catch it on first cac command
}

// Patch existing wrapper for known bugs — pure Node.js, no shell execution needed.
// Users who upgrade via npm install keep their old ~/.cac/bin/claude until _ensure_initialized
// runs (triggered by any cac command). This patch fixes critical bugs immediately.
var wrapperPath = path.join(cacDir, 'bin', process.platform === 'win32' ? 'claude.cmd' : 'claude');
// Skip wrapper patching on Windows (claude.cmd is a simple bat file)
if (home && fs.existsSync(wrapperPath) && process.platform !== 'win32') {
  try {
    var wrapperContent = fs.readFileSync(wrapperPath, 'utf8');
    var patched = wrapperContent;
    // Fix: pgrep returns exit 1 when no claude process exists; under set -euo pipefail
    // this aborts the wrapper before launching claude (claude appears to do nothing).
    var buggyPgrep = '_claude_count=$(pgrep -x "claude" 2>/dev/null | wc -l | tr -d \'[:space:]\')';
    var fixedPgrep = buggyPgrep + ' || _claude_count=0';
    if (patched.indexOf(buggyPgrep) !== -1 && patched.indexOf(fixedPgrep) === -1) {
      patched = patched.replace(buggyPgrep, fixedPgrep);
    }
    // Fix: _count_claude_processes may not exist in old wrappers
    var oldClaudeCount = '_claude_count=$(pgrep -x "claude" 2>/dev/null | wc -l | tr -d \'[:space:]\') || _claude_count=0';
    var newClaudeCount = '_claude_count=$(_count_claude_processes)';
    if (patched.indexOf(oldClaudeCount) !== -1 && patched.indexOf(newClaudeCount) === -1) {
      patched = patched.replace(oldClaudeCount, newClaudeCount);
    }
    // Fix: session exit killed the shared relay, breaking all other sessions.
    // Remove the trap so _cleanup_all never fires on exit.
    var buggyTrap = 'trap _cleanup_all EXIT INT TERM';
    if (patched.indexOf(buggyTrap) !== -1) {
      patched = patched.replace(buggyTrap, '');
    }
    if (patched !== wrapperContent) {
      fs.writeFileSync(wrapperPath, patched);
    }
  } catch (e) {
    // Non-fatal
  }
}

// Migrate existing environments: generate missing files added in v1.5.0
// (fake_git_remote, git_email, device_token)
try {
  var crypto = require('crypto');
  var envsDir = path.join(cacDir, 'envs');
  if (fs.existsSync(envsDir)) {
    var envs = fs.readdirSync(envsDir);
    for (var ei = 0; ei < envs.length; ei++) {
      var envDir = path.join(envsDir, envs[ei]);
      if (!fs.statSync(envDir).isDirectory()) continue;
      // fake_git_remote
      if (!fs.existsSync(path.join(envDir, 'fake_git_remote'))) {
        var u1 = crypto.randomUUID().split('-')[0];
        var u2 = crypto.randomUUID().split('-')[1];
        fs.writeFileSync(path.join(envDir, 'fake_git_remote'), 'https://github.com/user-' + u1 + '/project-' + u2 + '.git\n');
      }
      // git_email
      if (!fs.existsSync(path.join(envDir, 'git_email'))) {
        var u3 = crypto.randomUUID().split('-')[0].toLowerCase();
        fs.writeFileSync(path.join(envDir, 'git_email'), 'user-' + u3 + '@users.noreply.github.com\n');
      }
      // device_token
      if (!fs.existsSync(path.join(envDir, 'device_token'))) {
        fs.writeFileSync(path.join(envDir, 'device_token'), crypto.randomBytes(32).toString('hex') + '\n');
      }
      // Migrate telemetry mode names
      var tmFile = path.join(envDir, 'telemetry_mode');
      if (fs.existsSync(tmFile)) {
        var tm = fs.readFileSync(tmFile, 'utf8').trim();
        var mapped = { conservative: 'stealth', aggressive: 'paranoid', off: 'transparent' };
        if (mapped[tm]) fs.writeFileSync(tmFile, mapped[tm] + '\n');
      }
    }
  }
} catch (e) {
  // Non-fatal — cac env create will generate these for new environments
}

// Trigger _ensure_initialized to fully regenerate wrapper to current version.
// cac env ls now calls _require_setup (fixed in 1.4.3+).
if (home) {
  try {
    var spawnCommand = cacBin;
    var spawnArgs = ['env', 'ls'];
    if (process.platform === 'win32') {
      var bashExe = findWindowsBash();
      if (!bashExe) throw new Error('bash.exe not found');
      spawnCommand = bashExe;
      spawnArgs = [cacBin].concat(spawnArgs);
    }
    childProcess.spawnSync(spawnCommand, spawnArgs, {
      stdio: 'ignore',
      timeout: 8000,
      cwd: pkgDir,
      env: Object.assign({}, process.env, { HOME: home })
    });
  } catch (e) {
    // Non-fatal
  }
}

console.log([
  '',
  '  claude-cac installed successfully',
  '',
  '  Quick start:',
  '    cac env create <name> [-p <proxy>]   Create an isolated environment',
  '    cac <name>                           Switch environment',
  '    claude                               Start Claude Code',
  '',
  '  Docs: https://cac.nextmind.space/docs',
  ''
].join('\n'));
