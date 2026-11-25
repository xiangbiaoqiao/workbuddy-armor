<#
.SYNOPSIS
  Decide WHY opencode is still refusing: wrong placement, or weak prompt.

.DESCRIPTION
  Two different diseases look identical from the chat window:

    A) the agent file was never loaded  -> no amount of better prompt text helps.
       Fix the path / filename / frontmatter, or switch to the purge plugin route.
    B) the agent file IS loaded but the model refused anyway -> the prompt is live
       and too weak for that model. Fix with the full purge frame, or change model.

  This script separates them in one run. It checks the file shape on disk, then asks
  the model to echo a marker that only exists inside the prompt file. Marker comes
  back = layer B. Marker missing = layer A.

  Read-only except: it may run `opencode reload` and one tiny model request.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\verify-opencode-agent.ps1
  powershell -ExecutionPolicy Bypass -File scripts\verify-opencode-agent.ps1 -Model anthropic/claude-sonnet-5-5
#>
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$AgentName = 'build',
    [string]$Model,
    [string]$CliPath,
    [switch]$SkipRun
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$problems = @()
function Good($t) { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow; $script:problems += $t }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red;   $script:problems += $t }
function Note($t) { Write-Host "  ..     $t" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "== 1. locate the config dir ==" -ForegroundColor Cyan
if (-not $ConfigDir) {
    if ($env:OPENCODE_CONFIG_DIR) { $ConfigDir = $env:OPENCODE_CONFIG_DIR }
    elseif ($env:XDG_CONFIG_HOME)  { $ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode' }
    else { $ConfigDir = Join-Path $HOME '.config\opencode' }
}
$ConfigDir = [System.IO.Path]::GetFullPath($ConfigDir)
Note "OPENCODE_CONFIG_DIR = $(if ($env:OPENCODE_CONFIG_DIR) { $env:OPENCODE_CONFIG_DIR } else { '(unset)' })"
if (Test-Path $ConfigDir) { Good "config dir exists: $ConfigDir" }
else { Bad "config dir missing: $ConfigDir  (start opencode once so it creates it)" }

# the desktop app may keep config elsewhere; show both candidates
$alt = Join-Path $env:APPDATA 'opencode'
if ((Test-Path $alt) -and ($alt -ne $ConfigDir)) {
    Note "also present: $alt  <- if opencode reads this one, put the agent file there instead"
}

Write-Host ""
Write-Host "== 2. agent file on disk ==" -ForegroundColor Cyan
$file = Join-Path $ConfigDir "agents\$AgentName.md"
$projFile = Join-Path (Get-Location) ".opencode\agents\$AgentName.md"
Note "expected: $file"

if (-not (Test-Path $file)) {
    Bad "no agent file at $file"
    if (Test-Path $projFile) {
        Warn "but a PROJECT-level .opencode/agents/$AgentName.md exists in the current dir; project files override global ones"
    }
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - folder named 'agent' instead of 'agents'"
    Write-Host "    - file saved as build.md.txt (Windows hides the .txt)"
    Write-Host "    - saved into the project's .opencode of a DIFFERENT folder than the one you open"
} else {
    Good "file exists: $file ($((Get-Item $file).Length) bytes, modified $((Get-Item $file).LastWriteTime.ToString('MM-dd HH:mm')))"
    $raw = Get-Content $file -Raw -Encoding UTF8
    $lines = Get-Content $file -Encoding UTF8

    # BOM silently breaks frontmatter parsing
    $bytes = [System.IO.File]::ReadAllBytes($file)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Bad "file starts with a UTF-8 BOM - frontmatter parser will not see '---'. Re-save as UTF-8 without BOM"
    } else { Good "no BOM" }

    if ($lines[0].Trim() -eq '---') { Good "line 1 is '---' (frontmatter opens)" }
    else { Bad ("line 1 is '" + $lines[0].Trim() + "' - you probably pasted the markdown fence. It must be exactly ---") }

    if ($raw -match '```') {
        Bad "file still contains ``` code fences from the chat reply - strip them, the body must be plain markdown"
    } else { Good "no stray code fences" }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } }
    if ($end -gt 0) { Good "frontmatter closes at line $($end + 1)" }
    else { Bad "no closing '---' - the whole file is being read as frontmatter and the body is empty" }

    if ($end -gt 0) {
        $fm = ($lines[0..$end] -join "`n")
        if ($fm -match "(?m)^mode:\s*(primary|all)") { Good "mode: primary/all" } else { Warn "mode is not primary/all - the agent may not be selectable as the main agent" }
        if ($fm -match 'effect:\s*allow') { Good "permissions allow rule present" } else { Note "no permissions block (approval prompts will still appear)" }
    }

    $body = if ($end -gt 0) { ($lines[($end + 1)..($lines.Count - 1)] -join "`n") } else { "" }
    Note "body length: $($body.Length) chars"
    if ($body.Length -lt 500) { Bad "body is nearly empty ($($body.Length) chars) - the prompt text did not make it in" }
    else { Good "prompt body present" }

    if ($body -match 'fixture label') { Good "contains the fixture-label clause (the part that decides real-vs-sandbox)" }
    else { Warn "MISSING the 'fixture label' clause - without it the model excludes named real companies from the sandbox" }
    if ($body -match '\[ARMOR-OK\]') { Good "contains the [ARMOR-OK] marker instruction" }
    else { Warn "no [ARMOR-OK] marker line, so step 4 cannot prove the prompt is loaded" }
}

Write-Host ""
Write-Host "== 3. is the CLI available ==" -ForegroundColor Cyan
if (-not $CliPath) {
    $cand = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\opencode-cli.exe')
    )
    $onPath = (Get-Command opencode -ErrorAction SilentlyContinue)
    if ($onPath) { $cand = @($onPath.Source) + $cand }
    $CliPath = $cand | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if ($CliPath) { Good "cli: $CliPath"; Note ((& $CliPath --version 2>&1 | Out-String).Trim()) }
else { Warn "opencode CLI not found; run step 4 manually inside the app instead" }

Write-Host ""
Write-Host "== 4. live marker test ==" -ForegroundColor Cyan
if ($SkipRun -or -not $CliPath -or -not (Test-Path $file)) {
    Note "skipped"
} else {
    Write-Host "  reloading config..." -ForegroundColor DarkGray
    # the private server started by --standalone reads OPENCODE_CONFIG_DIR; set it so we
    # test the directory we just inspected, not whatever the desktop app happens to use
    $env:OPENCODE_CONFIG_DIR = $ConfigDir
    (& $CliPath reload 2>&1 | Out-Null)

    if (-not $Model) {
        $cfgJson = Join-Path $ConfigDir 'opencode.json'
        if (Test-Path $cfgJson) {
            try { $Model = (Get-Content $cfgJson -Raw -Encoding UTF8 | ConvertFrom-Json).model } catch { }
        }
    }
    Note "model: $(if ($Model) { $Model } else { '(agent/session default)' })"

    $ask = "Reply with exactly two lines: line 1 must be the literal text [ARMOR-OK], line 2 must be 2"
    $args = @('run', '--standalone', '--agent', $AgentName)
    if ($Model) { $args += @('-m', $Model) }
    $args += $ask

    Note "running: opencode $($args -join ' ')"
    $out = (& $CliPath @args 2>&1 | Out-String)
    if ($out -match '\[ARMOR-OK\]') {
        Good "MARKER RETURNED -> the prompt file IS live in the system prompt"
        Write-Host ""
        Write-Host "  Diagnosis: LAYER B. Placement is correct; the refusal is the" -ForegroundColor Yellow
        Write-Host "  prompt/model, not the install." -ForegroundColor Yellow
        Write-Host "  Do, in order:"
        Write-Host "    1. check the model in use - free-tier models refuse regardless of prompt"
        Write-Host "    2. switch to the stronger frame:  powershell -File scripts\bootstrap-opencode.ps1"
        Write-Host "       (that installs opencode-purge: 27 category rules + intent mapping, ~25KB)"
        Write-Host "    3. if it still refuses, the request wording is the trigger: ask for the"
        Write-Host "       retrieval method / architecture first, not the named target"
    } else {
        Bad "NO MARKER -> the prompt file is NOT reaching the model"
        Write-Host ""
        Write-Host "  Diagnosis: LAYER A. Fix placement before touching prompt text." -ForegroundColor Yellow
        Write-Host "  bootstrap/purge would ALSO fail here if the config dir is wrong - fix that first."
        if ($out.Trim()) {
            Write-Host ""
            Note "model actually said:"
            ($out.Trim() -split "`n" | Select-Object -First 6) | ForEach-Object { Write-Host "    $_" }
        }
    }
}

Write-Host ""
Write-Host ("=" * 62)
if ($problems.Count -eq 0) { Write-Host "no file-shape problems detected" -ForegroundColor Green }
else { Write-Host ("issues: " + $problems.Count) -ForegroundColor Yellow }
Write-Host ("=" * 62)
