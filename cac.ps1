#Requires -Version 5.1

$ErrorActionPreference = "Stop"

function Find-GitBash {
    $candidates = @()

    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432)) {
        if ($base) {
            $candidates += (Join-Path $base "Git\bin\bash.exe")
        }
    }

    if ($env:LocalAppData) {
        $candidates += (Join-Path $env:LocalAppData "Programs\Git\bin\bash.exe")
        $candidates += (Join-Path $env:LocalAppData "Git\bin\bash.exe")
    }

    try {
        $gitMatches = @(Get-Command git.exe -All -ErrorAction Stop | Select-Object -ExpandProperty Source)
        foreach ($gitExe in $gitMatches) {
            $candidates += [System.IO.Path]::GetFullPath((Join-Path (Split-Path $gitExe -Parent) "..\bin\bash.exe"))
        }
    } catch {}

    try {
        $bashMatches = @(Get-Command bash.exe -All -ErrorAction Stop | Select-Object -ExpandProperty Source)
        foreach ($bashExe in $bashMatches) {
            if ($bashExe -notmatch "\\WindowsApps\\") {
                $candidates += $bashExe
            }
        }
    } catch {}

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cacScript = Join-Path $scriptDir "cac"
$bashExe = Find-GitBash

if (-not $bashExe) {
    Write-Error "Git Bash not found. Install Git for Windows or add bash.exe to PATH."
    exit 9009
}

& $bashExe $cacScript @args
exit $LASTEXITCODE
