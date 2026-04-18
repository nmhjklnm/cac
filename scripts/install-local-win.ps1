#Requires -Version 5.1

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

# Resolve npm global bin directory dynamically so users with custom Node setups
# (nvm-windows, fnm, volta, Scoop) get shims in a directory that's actually on PATH.
# Falls back to %APPDATA%\npm if `npm config get prefix` is unavailable.
function Get-NpmGlobalBin {
    # Try npm prefix -g first (most reliable across Node managers)
    try {
        $prefix = (npm prefix -g 2>$null | Select-Object -First 1)
        if ($prefix) {
            $prefix = $prefix.Trim()
            if ($prefix) { return $prefix }
        }
    } catch {}
    # Fallback: npm config get prefix via cmd.exe to avoid PowerShell .cmd shim issues
    try {
        $prefix = (cmd.exe /c "npm config get prefix" 2>$null | Select-Object -First 1)
        if ($prefix) {
            $prefix = $prefix.Trim()
            if ($prefix -and $prefix -notmatch 'Unknown|Error|not recognized') { return $prefix }
        }
    } catch {}
    if ($env:APPDATA) {
        return (Join-Path $env:APPDATA "npm")
    }
    throw "Cannot determine npm global bin directory: npm not found and APPDATA is not set"
}

$npmBin = Get-NpmGlobalBin

$cmdShim = Join-Path $npmBin "cac.cmd"
$psShim = Join-Path $npmBin "cac.ps1"
$bashShim = Join-Path $npmBin "cac"
$marker = "REM cac local checkout shim"
$psMarker = "# cac local checkout shim"
$bashMarker = "# cac local checkout shim"
$repoRootWin = $repoRoot

function Ensure-UserPathContains {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($current) {
        $parts = $current -split ";" | Where-Object { $_ }
    }
    if ($parts -contains $Dir) {
        return
    }
    $newPath = if ($current) { "$current;$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

function Remove-ShimIfManaged {
    param(
        [string]$Path,
        [string]$ExpectedMarker
    )

    if (-not (Test-Path $Path)) {
        return
    }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($ExpectedMarker)) {
        Remove-Item -LiteralPath $Path -Force
    }
}

if ($Uninstall) {
    Remove-ShimIfManaged -Path $cmdShim -ExpectedMarker $marker
    Remove-ShimIfManaged -Path $psShim -ExpectedMarker $psMarker
    Remove-ShimIfManaged -Path $bashShim -ExpectedMarker $bashMarker
    Write-Host "Removed local checkout shims from $npmBin"
    Write-Host "User PATH was left unchanged."
    exit 0
}

New-Item -ItemType Directory -Force -Path $npmBin | Out-Null

$cmdContent = @"
@echo off
$marker
set "REPO_ROOT=$repoRoot"
"%REPO_ROOT%\cac.cmd" %*
"@

$psContent = @"
$psMarker
& "$repoRoot\cac.ps1" @args
exit `$LASTEXITCODE
"@

$bashContent = @"
#!/usr/bin/env bash
$bashMarker
REPO_ROOT_WIN='$repoRootWin'
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT=`$(cygpath -u "`$REPO_ROOT_WIN")
else
  REPO_ROOT="`$REPO_ROOT_WIN"
fi
exec "`$REPO_ROOT/cac" "`$@"
"@

Set-Content -LiteralPath $cmdShim -Value $cmdContent -Encoding ASCII
Set-Content -LiteralPath $psShim -Value $psContent -Encoding ASCII
Set-Content -LiteralPath $bashShim -Value $bashContent -Encoding ASCII

Ensure-UserPathContains -Dir $npmBin

Write-Host "Installed local checkout shims:"
Write-Host "  $cmdShim"
Write-Host "  $psShim"
Write-Host "  $bashShim"
Write-Host ""
Write-Host "Reopen CMD / PowerShell / Git Bash, then run:"
Write-Host "  cac -v"
