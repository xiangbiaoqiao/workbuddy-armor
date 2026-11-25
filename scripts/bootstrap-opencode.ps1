<#
.SYNOPSIS
  One-shot opencode armour installer for a fresh machine.

.DESCRIPTION
  Four idempotent steps:

    1. preflight   node >= 18, python, locate the opencode config dir
    2. fetch       use -PurgeRepo, else git clone ADeRoy/opencode-purge
    3. apply       node bin/opencode-purge.js apply   <- the armour itself (system tier)
    4. clauses     patch-opencode-business.py         <- adds Scoped Rules 26/27

  Why two repos: opencode-purge owns the plugin and its
  experimental.chat.system.transform hook, which replaces the provider system prompt
  on every turn. That hook is the only thing that reliably survives a hard refusal.
  This repo patches that frame file with the clauses upstream is missing, and also
  ships static AGENTS.md injection (instruction tier, weaker).

  Step order matters: `purge apply` copies the repo's own prompt-inject.md over the
  target, which would wipe our clauses. So step 3 backs the patched file up first and
  step 4 re-inserts afterwards.

.PARAMETER PurgeRepo
  Path to an existing opencode-purge checkout. Skips the clone.

.PARAMETER ConfigDir
  opencode config dir. Default: OPENCODE_CONFIG_DIR, else XDG_CONFIG_HOME/opencode,
  else ~/.config/opencode.

.PARAMETER SkipPurge
  Only apply the clause patch; do not install opencode-purge.

.PARAMETER DryRun
  Print what would run; change nothing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\bootstrap-opencode.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\bootstrap-opencode.ps1 -PurgeRepo D:\src\opencode-purge
#>
[CmdletBinding()]
param(
    [string]$PurgeRepo,
    [string]$ConfigDir,
    [switch]$SkipPurge,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

function Step($n, $t) { Write-Host ("[{0}] {1}" -f $n, $t) -ForegroundColor Cyan }
function Ok($t)   { Write-Host ("      ok    {0}" -f $t) -ForegroundColor Green }
function Bad($t)  { Write-Host ("      fail  {0}" -f $t) -ForegroundColor Red }
function Info($t) { Write-Host ("      ..    {0}" -f $t) -ForegroundColor DarkGray }

# Native commands write progress to stderr; under ErrorActionPreference=Stop PowerShell
# turns that into a terminating error. Relax it for the call and collect everything.
function Invoke-Cmd {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$CmdArgs = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @CmdArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $code = 1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Out = ($out -replace "`r`n", "`n").Trim(); Code = $code }
}

$here = $PSScriptRoot
$fail = @()

# ---------------------------------------------------------------- 1. preflight
Step 1 "preflight"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Bad "node not on PATH. opencode-purge needs Node >= 18: https://nodejs.org"
    return 1
}
$nodeVer = ((Invoke-Cmd node @('--version')).Out) -replace '^v', ''
$nodeMajor = 0
if ($nodeVer -match '^(\d+)') { $nodeMajor = [int]$Matches[1] }
if ($nodeMajor -lt 18) {
    Bad "node $nodeVer is too old, need >= 18"
    return 1
}
Ok "node $nodeVer"

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Bad "python not on PATH (needed for the clause patch)"
    $fail += "python"
} else {
    Ok ("python " + ((Invoke-Cmd python @('--version')).Out) -replace '^Python\s*', '')
}

if ([string]::IsNullOrWhiteSpace($ConfigDir)) {
    if ($env:OPENCODE_CONFIG_DIR) {
        $ConfigDir = $env:OPENCODE_CONFIG_DIR
    } elseif ($env:XDG_CONFIG_HOME) {
        $ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode'
    } else {
        $ConfigDir = Join-Path $HOME '.config\opencode'
    }
}
$ConfigDir = [System.IO.Path]::GetFullPath($ConfigDir)
if (Test-Path $ConfigDir) {
    Ok "opencode config: $ConfigDir"
} else {
    Info "config dir does not exist yet: $ConfigDir"
    Write-Host "      Start opencode once on this machine so it creates its config, then re-run." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2. fetch purge
Step 2 "locate opencode-purge"

$purgeDir = $null
if ($SkipPurge) {
    Info "skipped (-SkipPurge)"
} elseif ($PurgeRepo) {
    $probe = Join-Path $PurgeRepo 'bin\opencode-purge.js'
    if (Test-Path $probe) {
        $purgeDir = (Resolve-Path $PurgeRepo).Path
        Ok "using checkout: $purgeDir"
    } else {
        Bad "-PurgeRepo has no bin\opencode-purge.js: $PurgeRepo"
        $fail += "purge-repo"
    }
} else {
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'workbuddy-armor'
    $purgeDir = Join-Path $cacheRoot 'opencode-purge'

    if (Test-Path (Join-Path $purgeDir 'bin\opencode-purge.js')) {
        Ok "already cloned: $purgeDir"
        if (-not $DryRun) {
            Push-Location $purgeDir
            $pull = Invoke-Cmd git @('pull', '--ff-only')
            Pop-Location
            if ($pull.Code -ne 0) { Info "git pull skipped/failed (continuing with local copy)" }
            else { Info "updated" }
        }
    } elseif ($DryRun) {
        Info "[dry run] would clone ADeRoy/opencode-purge -> $purgeDir"
    } else {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Bad "git not on PATH. Install git, or pass -PurgeRepo <path> to a checkout."
            $purgeDir = $null
            $fail += "git"
        } else {
            New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
            Info "cloning https://github.com/ADeRoy/opencode-purge.git"
            $cl = Invoke-Cmd git @('clone', '--depth', '1',
                                   'https://github.com/ADeRoy/opencode-purge.git', $purgeDir)
            if ($cl.Code -ne 0) {
                Bad "git clone exited $($cl.Code)"
                ($cl.Out -split "`n") | Select-Object -Last 4 | ForEach-Object { Info $_ }
                Write-Host "      If this machine is behind a proxy, set it first:" -ForegroundColor Yellow
                Write-Host "        git config --global http.https://github.com.proxy http://127.0.0.1:PORT" -ForegroundColor Yellow
                $purgeDir = $null
                $fail += "clone"
            } elseif (-not (Test-Path (Join-Path $purgeDir 'bin\opencode-purge.js'))) {
                Bad "clone reported success but bin\opencode-purge.js is missing"
                $purgeDir = $null
                $fail += "clone-layout"
            } else {
                Ok "cloned"
            }
        }
    }
}

# ---------------------------------------------------------------- 3. apply armour
Step 3 "install the armour (system tier)"

if ($SkipPurge) {
    Info "skipped"
} elseif (-not $purgeDir) {
    Info "no checkout available, skipped"
} elseif ($DryRun) {
    Info "[dry run] would run: node `"$purgeDir\bin\opencode-purge.js`" apply"
} else {
    $liveFrame = Join-Path $ConfigDir 'purge\prompt-inject.md'
    if (Test-Path $liveFrame) {
        $liveText = [System.IO.File]::ReadAllText($liveFrame, [System.Text.Encoding]::UTF8)
        if ($liveText -match '26\. Commercial deployment|27\. Resource catalog') {
            $preBak = "$liveFrame.preapply.bak"
            [System.IO.File]::Copy($liveFrame, $preBak, $true)
            Ok "backed up patched frame -> $(Split-Path $preBak -Leaf)"
        }
    }

    $cli = Join-Path $purgeDir 'bin\opencode-purge.js'
    $env:OPENCODE_CONFIG_DIR = $ConfigDir
    Info "node bin/opencode-purge.js apply"
    $ap = Invoke-Cmd node @($cli, 'apply')
    ($ap.Out -split "`n") | Select-Object -Last 12 | ForEach-Object { Info $_ }
    if ($ap.Code -ne 0) {
        Bad "purge apply exited $($ap.Code)"
        $fail += "purge-apply"
    } else {
        Ok "applied"
        $st = Invoke-Cmd node @($cli, 'status')
        if ($st.Out -match 'PT-02[^\n]*applied') {
            Ok "PT-02 SYSTEM_TRANSFORM hook is live"
        } elseif ($st.Out -match 'PT-02') {
            Bad "PT-02 reported but not applied"
            $fail += "PT-02"
        } else {
            Info "PT-02 not in this purge version's output; check 'status' manually"
        }
    }
}

# ---------------------------------------------------------------- 4. clauses
Step 4 "add clauses 26/27 (missing upstream)"

$patch = Join-Path $here 'patch-opencode-business.py'
if (-not (Test-Path $patch)) {
    Bad "patch script not found beside this script: $patch"
    $fail += "patch-script"
} elseif (-not $py) {
    Info "no python, skipped"
} elseif ($DryRun) {
    Info "[dry run] would run: python `"$patch`""
} else {
    $env:OPENCODE_CONFIG_DIR = $ConfigDir
    $pp = Invoke-Cmd python @($patch)
    ($pp.Out -split "`n") | ForEach-Object { Info $_ }
    if ($pp.Code -ne 0) {
        Bad "clause patch exited $($pp.Code)"
        $fail += "clauses"
    } else {
        $chk = Invoke-Cmd python @($patch, '--status')
        $miss = @(($chk.Out -split "`n") | Where-Object { $_ -match '^\s*MISS' })
        if ($miss.Count -gt 0) {
            Bad ("still missing: " + (($miss | ForEach-Object { $_.Trim() }) -join ' | '))
            $fail += "clauses-verify"
        } else {
            Ok "all 5 clause checks present"
        }
    }
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host ("=" * 64)
if ($fail.Count -eq 0) {
    Write-Host "DONE - armour installed, clauses 26/27 in place." -ForegroundColor Green
    Write-Host ""
    Write-Host "Now: fully quit opencode (kill the processes), reopen, start a NEW session."
    Write-Host "Prove it is live without waiting for a refusal:"
    if ($purgeDir) {
        Write-Host "  node `"$purgeDir\bin\opencode-purge.js`" status"
    }
    Write-Host "  Select-String `"$ConfigDir\purge\purge.log`" 'system.transform' | Select -Last 2"
    Write-Host "  # inChars ~38000 vs outChars ~23000+  -> different numbers = it swapped"
} else {
    Write-Host ("FINISHED WITH PROBLEMS: " + ($fail -join ', ')) -ForegroundColor Yellow
    Write-Host "Fix the items above and re-run - every step is idempotent."
}
Write-Host ("=" * 64)
if ($fail.Count -gt 0) { return 1 }
return 0
