#Requires -Version 5.1
<#
.SYNOPSIS
    cac -- Claude Anti-fingerprint Cloak (Windows)
.DESCRIPTION
    Windows management tool, equivalent to the Unix cac Bash script.
    Manages proxy environments, identity isolation, wrapper interception.
.EXAMPLE
    .\cac.ps1 setup
    .\cac.ps1 add us1 http://user:pass@host:port
    .\cac.ps1 us1
#>

$ErrorActionPreference = "Stop"

$CAC_DIR = Join-Path $env:USERPROFILE ".cac"
$ENVS_DIR = Join-Path $CAC_DIR "envs"

# ── helpers ───────────────────────────────────────────────

function Write-Green  { param($Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Red    { param($Msg) Write-Host $Msg -ForegroundColor Red }
function Write-Yellow { param($Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Bold   { param($Msg) Write-Host $Msg -ForegroundColor White }

function Read-FileValue {
    param([string]$Path, [string]$Default = "")
    if (Test-Path $Path) {
        return (Get-Content $Path -Raw).Trim()
    }
    return $Default
}

function New-Uuid    { return [guid]::NewGuid().ToString().ToUpper() }
function New-Sid     { return [guid]::NewGuid().ToString().ToLower() }
function New-UserId  { return -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) }) }
function New-MachineId { return [guid]::NewGuid().ToString().Replace("-","").ToLower() }
function New-FakeHostname { return "host-$([guid]::NewGuid().ToString().Split('-')[0].ToLower())" }
function New-FakeMac {
    $bytes = @(0x02) + (1..5 | ForEach-Object { Get-Random -Maximum 256 })
    return ($bytes | ForEach-Object { "{0:x2}" -f $_ }) -join ":"
}

function Get-ProxyHostPort {
    param([string]$ProxyUrl)
    $hp = $ProxyUrl -replace ".*@", "" -replace ".*://", ""
    return $hp
}

function Parse-Proxy {
    param([string]$Raw)
    if ($Raw -match "^(http|https|socks5)://") { return $Raw }
    $parts = $Raw -split ":"
    if ($parts.Count -ge 4) {
        return "http://$($parts[2]):$($parts[3])@$($parts[0]):$($parts[1])"
    } elseif ($parts.Count -ge 2) {
        return "http://$($parts[0]):$($parts[1])"
    }
    return $null
}

function Test-ProxyReachable {
    param([string]$ProxyUrl)
    $hp = Get-ProxyHostPort $ProxyUrl
    $parts = $hp -split ":"
    if ($parts.Count -lt 2) { return $false }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($parts[0], [int]$parts[1], $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne(5000)
        $tcp.Close()
        return $success
    } catch { return $false }
}

function Require-Setup {
    $realClaude = Join-Path $CAC_DIR "real_claude"
    if (-not (Test-Path $realClaude)) {
        Write-Red "Error: run 'cac setup' first"
        exit 1
    }
}

function Get-CurrentEnv {
    return Read-FileValue (Join-Path $CAC_DIR "current")
}

function Find-RealClaude {
    $paths = $env:PATH -split ";" | Where-Object { $_ -notlike "*\.cac\bin*" }
    foreach ($p in $paths) {
        $candidate = Join-Path $p "claude.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Update-Statsig {
    param([string]$StableId)
    $statsigDir = Join-Path $env:USERPROFILE ".claude\statsig"
    if (-not (Test-Path $statsigDir)) { return }
    Get-ChildItem (Join-Path $statsigDir "statsig.stable_id.*") -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Content $_.FullName "`"$StableId`""
    }
}

function Update-ClaudeJsonUserId {
    param([string]$UserId)
    $jsonPath = Join-Path $env:USERPROFILE ".claude.json"
    if (-not (Test-Path $jsonPath)) { return }
    try {
        $d = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $d.userID = $UserId
        $d | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding UTF8
    } catch {
        Write-Yellow "Warning: failed to update ~/.claude.json userID"
    }
}

# ── write wrapper (claude.cmd) ────────────────────────────

function Write-Wrapper {
    $binDir = Join-Path $CAC_DIR "bin"
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    $wrapperContent = @'
@echo off
setlocal enabledelayedexpansion

set "CAC_DIR=%USERPROFILE%\.cac"
set "ENVS_DIR=!CAC_DIR!\envs"

REM stopped: passthrough
if exist "!CAC_DIR!\stopped" (
    set /p REAL_CLAUDE=<"!CAC_DIR!\real_claude"
    "!REAL_CLAUDE!" %*
    exit /b !ERRORLEVEL!
)

REM read current env
if not exist "!CAC_DIR!\current" (
    echo [cac] Error: no active env, run 'cac ^<name^>' >&2
    exit /b 1
)
set /p ENV_NAME=<"!CAC_DIR!\current"
for /f "delims=" %%i in ("!ENV_NAME!") do set "ENV_NAME=%%i"
set "ENV_DIR=!ENVS_DIR!\!ENV_NAME!"

if not exist "!ENV_DIR!" (
    echo [cac] Error: env '!ENV_NAME!' not found >&2
    exit /b 1
)

REM read proxy
set /p PROXY=<"!ENV_DIR!\proxy"
for /f "delims=" %%i in ("!PROXY!") do set "PROXY=%%i"

REM inject proxy
set "HTTPS_PROXY=!PROXY!"
set "HTTP_PROXY=!PROXY!"
set "ALL_PROXY=!PROXY!"
set "NO_PROXY=localhost,127.0.0.1"

REM telemetry kill switches
set "CLAUDE_CODE_SKIP_AUTO_UPDATE=1"
set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
set "CLAUDE_CODE_ENABLE_TELEMETRY="
set "DO_NOT_TRACK=1"
set "OTEL_SDK_DISABLED=true"
set "OTEL_TRACES_EXPORTER=none"
set "OTEL_METRICS_EXPORTER=none"
set "OTEL_LOGS_EXPORTER=none"
set "SENTRY_DSN="
set "DISABLE_ERROR_REPORTING=1"
set "DISABLE_BUG_COMMAND=1"
set "TELEMETRY_DISABLED=1"
set "DISABLE_TELEMETRY=1"
set "LANG=en_US.UTF-8"

REM clear third-party API config
set "ANTHROPIC_BASE_URL="
set "ANTHROPIC_AUTH_TOKEN="
set "ANTHROPIC_API_KEY="

REM fingerprint hook via NODE_OPTIONS
if exist "!ENV_DIR!\hostname" (
    set /p CAC_HOSTNAME=<"!ENV_DIR!\hostname"
)
if exist "!ENV_DIR!\mac_address" (
    set /p CAC_MAC=<"!ENV_DIR!\mac_address"
)
if exist "!ENV_DIR!\machine_id" (
    set /p CAC_MACHINE_ID=<"!ENV_DIR!\machine_id"
)
set "CAC_USERNAME=user-!ENV_NAME:~0,8!"
if exist "!CAC_DIR!\fingerprint-hook.js" (
    set "NODE_OPTIONS=--require !CAC_DIR!\fingerprint-hook.js !NODE_OPTIONS!"
)

REM timezone
if exist "!ENV_DIR!\tz" (
    set /p TZ=<"!ENV_DIR!\tz"
)

REM inject statsig stable_id
if exist "!ENV_DIR!\stable_id" (
    set /p STABLE_ID=<"!ENV_DIR!\stable_id"
    for %%f in ("%USERPROFILE%\.claude\statsig\statsig.stable_id.*") do (
        if exist "%%f" echo "!STABLE_ID!"> "%%f"
    )
)

REM launch real claude
set /p REAL_CLAUDE=<"!CAC_DIR!\real_claude"
for /f "delims=" %%i in ("!REAL_CLAUDE!") do set "REAL_CLAUDE=%%i"
if not exist "!REAL_CLAUDE!" (
    echo [cac] Error: !REAL_CLAUDE! not found, run 'cac setup' >&2
    exit /b 1
)

"!REAL_CLAUDE!" %*
exit /b !ERRORLEVEL!
'@

    $wrapperPath = Join-Path $binDir "claude.cmd"
    Set-Content $wrapperPath $wrapperContent -Encoding ASCII
    Write-Host "  wrapper -> $wrapperPath"
}

# ── cmd: setup ────────────────────────────────────────────

function Cmd-Setup {
    Write-Host "=== cac setup ==="

    $realClaude = Find-RealClaude
    if (-not $realClaude) {
        Write-Red "Error: claude.exe not found, install Claude Code first"
        Write-Host "  npm install -g @anthropic-ai/claude-code"
        exit 1
    }
    Write-Host "  real claude: $realClaude"

    New-Item -ItemType Directory -Path $ENVS_DIR -Force | Out-Null
    Set-Content (Join-Path $CAC_DIR "real_claude") $realClaude

    Write-Wrapper

    # copy fingerprint-hook.js
    $hookSrc = Join-Path $PSScriptRoot "fingerprint-hook.js"
    $hookDst = Join-Path $CAC_DIR "fingerprint-hook.js"
    if (Test-Path $hookSrc) {
        Copy-Item $hookSrc $hookDst -Force
        Write-Host "  fingerprint hook -> $hookDst"
    } elseif (Test-Path $hookDst) {
        Write-Host "  fingerprint hook (exists)"
    } else {
        Write-Yellow "  fingerprint-hook.js not found"
    }

    Write-Host ""
    Write-Host "-- Next steps --"
    Write-Host "1. Make sure PATH includes:"
    Write-Host ""
    Write-Host "   $CAC_DIR\bin       (claude wrapper)"
    Write-Host "   $env:USERPROFILE\bin     (cac command)"
    Write-Host ""
    Write-Host "2. Add your first environment:"
    Write-Host "   cac add <name> <host:port:user:pass>"
}

# ── cmd: add ──────────────────────────────────────────────

function Cmd-Add {
    param([string]$Name, [string]$RawProxy)
    Require-Setup

    if (-not $Name -or -not $RawProxy) {
        Write-Host "Usage: cac add <name> <host:port:user:pass>"
        Write-Host "  or:  cac add <name> http://user:pass@host:port"
        exit 1
    }

    $envDir = Join-Path $ENVS_DIR $Name
    if (Test-Path $envDir) {
        Write-Red "Error: env '$Name' already exists, use 'cac ls'"
        exit 1
    }

    $proxy = Parse-Proxy $RawProxy
    if (-not $proxy) {
        Write-Red "Error: invalid proxy format"
        exit 1
    }

    Write-Bold "Creating env: $Name"
    Write-Host "  Proxy: $proxy"
    Write-Host ""

    Write-Host -NoNewline "  Testing proxy ... "
    if (Test-ProxyReachable $proxy) {
        Write-Green "reachable"
    } else {
        Write-Yellow "unreachable"
        Write-Host "  Warning: proxy currently unreachable"
    }

    # detect timezone
    Write-Host -NoNewline "  Detecting timezone ... "
    $tz = "America/New_York"
    $lang = "en_US.UTF-8"
    try {
        $exitIp = & curl.exe -s --proxy $proxy --connect-timeout 8 https://api.ipify.org 2>$null
        if ($exitIp) {
            $ipInfo = & curl.exe -s --connect-timeout 8 "http://ip-api.com/json/${exitIp}?fields=timezone,countryCode" 2>$null
            $ipObj = $ipInfo | ConvertFrom-Json
            $tzResult = $ipObj.timezone
            if ($tzResult) { $tz = $tzResult }
        }
        Write-Green $tz
    } catch {
        Write-Yellow "failed, using default $tz"
    }
    Write-Host ""

    $confirm = Read-Host "Confirm? [yes/N]"
    if ($confirm -ne "yes") { Write-Host "Cancelled."; return }

    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    Set-Content (Join-Path $envDir "proxy")      $proxy
    Set-Content (Join-Path $envDir "uuid")        (New-Uuid)
    Set-Content (Join-Path $envDir "stable_id")   (New-Sid)
    Set-Content (Join-Path $envDir "user_id")     (New-UserId)
    Set-Content (Join-Path $envDir "machine_id")  (New-MachineId)
    Set-Content (Join-Path $envDir "hostname")    (New-FakeHostname)
    Set-Content (Join-Path $envDir "mac_address") (New-FakeMac)
    Set-Content (Join-Path $envDir "tz")          $tz
    Set-Content (Join-Path $envDir "lang")        $lang

    Write-Host ""
    Write-Green "Env '$Name' created"
    Write-Host "  UUID     : $(Get-Content (Join-Path $envDir 'uuid'))"
    Write-Host "  stable_id: $(Get-Content (Join-Path $envDir 'stable_id'))"
    Write-Host "  TZ       : $tz"
    Write-Host ""
    Write-Host "Switch to it: cac $Name"
}

# ── cmd: switch ───────────────────────────────────────────

function Cmd-Switch {
    param([string]$Name)
    Require-Setup

    $envDir = Join-Path $ENVS_DIR $Name
    if (-not (Test-Path $envDir)) {
        Write-Red "Error: env '$Name' not found, use 'cac ls'"
        exit 1
    }

    $proxy = Read-FileValue (Join-Path $envDir "proxy")
    Write-Host -NoNewline "Testing [$Name] proxy ... "
    if (Test-ProxyReachable $proxy) {
        Write-Green "reachable"
    } else {
        Write-Yellow "unreachable"
    }

    Set-Content (Join-Path $CAC_DIR "current") $Name
    $stoppedFile = Join-Path $CAC_DIR "stopped"
    if (Test-Path $stoppedFile) { Remove-Item $stoppedFile -Force }

    $stableId = Read-FileValue (Join-Path $envDir "stable_id")
    $userId = Read-FileValue (Join-Path $envDir "user_id")
    if ($stableId) { Update-Statsig $stableId }
    if ($userId) { Update-ClaudeJsonUserId $userId }

    Write-Green "Switched to $Name"
}

# ── cmd: ls ───────────────────────────────────────────────

function Cmd-Ls {
    Require-Setup

    if (-not (Test-Path $ENVS_DIR) -or (Get-ChildItem $ENVS_DIR -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Host "(no envs yet, use 'cac add <name> <proxy>')"
        return
    }

    $current = Get-CurrentEnv
    $stoppedTag = ""
    if (Test-Path (Join-Path $CAC_DIR "stopped")) { $stoppedTag = " [stopped]" }

    Get-ChildItem $ENVS_DIR -Directory | ForEach-Object {
        $name = $_.Name
        $proxy = Read-FileValue (Join-Path $_.FullName "proxy")
        $hp = Get-ProxyHostPort $proxy
        if ($name -eq $current) {
            Write-Host -NoNewline "  > " -ForegroundColor Green
            Write-Bold "${name}${stoppedTag}"
            Write-Host "    proxy: $hp"
        } else {
            Write-Host "    $name"
            Write-Host "    proxy: $hp"
        }
    }
}

# ── cmd: check ────────────────────────────────────────────

function Cmd-Check {
    Require-Setup

    if (Test-Path (Join-Path $CAC_DIR "stopped")) {
        Write-Yellow "cac is stopped -- claude running without protection"
        Write-Host "  Resume: cac -c"
        return
    }

    $current = Get-CurrentEnv
    if (-not $current) {
        Write-Red "Error: no active env, run 'cac <name>'"
        exit 1
    }

    $envDir = Join-Path $ENVS_DIR $current
    $proxy = Read-FileValue (Join-Path $envDir "proxy")

    Write-Bold "Current env: $current"
    Write-Host "  Proxy     : $(Get-ProxyHostPort $proxy)"
    Write-Host "  UUID      : $(Read-FileValue (Join-Path $envDir 'uuid'))"
    Write-Host "  stable_id : $(Read-FileValue (Join-Path $envDir 'stable_id'))"
    Write-Host "  user_id   : $(Read-FileValue (Join-Path $envDir 'user_id'))"
    Write-Host "  TZ        : $(Read-FileValue (Join-Path $envDir 'tz') '(not set)')"
    Write-Host ""

    Write-Host -NoNewline "  TCP test  ... "
    if (-not (Test-ProxyReachable $proxy)) {
        Write-Red "FAIL"
        return
    }
    Write-Green "OK"

    Write-Host -NoNewline "  Exit IP   ... "
    try {
        $ip = & curl.exe -s --proxy $proxy --connect-timeout 8 https://api.ipify.org 2>$null
        if ($ip) { Write-Green $ip } else { Write-Yellow "failed" }
    } catch {
        Write-Yellow "failed"
    }
}

# ── cmd: stop / continue ─────────────────────────────────

function Cmd-Stop {
    New-Item -ItemType File -Path (Join-Path $CAC_DIR "stopped") -Force | Out-Null
    Write-Yellow "cac stopped -- claude will run without proxy/disguise"
    Write-Host "  Resume: cac -c"
}

function Cmd-Continue {
    $stoppedFile = Join-Path $CAC_DIR "stopped"
    if (-not (Test-Path $stoppedFile)) {
        Write-Host "cac is not stopped"
        return
    }

    $current = Get-CurrentEnv
    if (-not $current) {
        Write-Red "Error: no active env, run 'cac <name>'"
        exit 1
    }

    Remove-Item $stoppedFile -Force
    Write-Green "cac resumed -- current env: $current"
}

# ── cmd: help ─────────────────────────────────────────────

function Cmd-Help {
    Write-Host ""
    Write-Bold "cac -- Claude Anti-fingerprint Cloak (Windows)"
    Write-Host ""
    Write-Bold "Usage:"
    Write-Host "  cac setup                              First-time setup"
    Write-Host "  cac add <name> <host:port:user:pass>   Add new env"
    Write-Host "  cac <name>                             Switch to env"
    Write-Host "  cac ls                                 List all envs"
    Write-Host "  cac check                              Check current env"
    Write-Host "  cac stop                               Temporarily disable"
    Write-Host "  cac -c                                 Resume from stop"
    Write-Host ""
    Write-Bold "Proxy formats:"
    Write-Host "  host:port:user:pass                    With auth"
    Write-Host "  host:port                              No auth"
    Write-Host "  http://user:pass@host:port             Full URL"
    Write-Host "  socks5://host:port                     SOCKS5"
    Write-Host ""
    Write-Bold "Examples:"
    Write-Host "  cac setup"
    Write-Host "  cac add us1 1.2.3.4:1080:username:password"
    Write-Host "  cac us1"
    Write-Host "  cac check"
    Write-Host ""
    Write-Bold "Files:"
    Write-Host "  %USERPROFILE%\.cac\bin\claude.cmd           Wrapper"
    Write-Host "  %USERPROFILE%\.cac\current                  Active env"
    Write-Host "  %USERPROFILE%\.cac\envs\<name>\             Env data"
    Write-Host "  %USERPROFILE%\.cac\fingerprint-hook.js      Node.js hook"
    Write-Host ""
}

# ── entry: dispatch ───────────────────────────────────────

if ($args.Count -eq 0) { Cmd-Help; exit 0 }

switch ($args[0]) {
    "setup"   { Cmd-Setup }
    "add"     { Cmd-Add $args[1] $args[2] }
    "ls"      { Cmd-Ls }
    "list"    { Cmd-Ls }
    "check"   { Cmd-Check }
    "stop"    { Cmd-Stop }
    "-c"      { Cmd-Continue }
    "help"    { Cmd-Help }
    "--help"  { Cmd-Help }
    "-h"      { Cmd-Help }
    default   { Cmd-Switch $args[0] }
}
