[CmdletBinding()]
param(
    [string]$SourcePrompt,
    # OpenCode global config dir (default: ~/.config/opencode, or $XDG_CONFIG_HOME/opencode)
    [string]$ConfigDir,
    [string]$SkillsSource,
    # Semicolon-separated list of known prompt file paths — if AGENTS.md body matches any
    # of these, it's treated as "the file IS the prompt" and can be replaced wholesale.
    [string]$KnownPrompts,
    [switch]$Uninstall,
    # Strip only the injected prompt block from AGENTS.md; keep skills and install-state.json.
    [switch]$RestoreMemory
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Unified UTF-8 output
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }
$Utf8 = New-Object System.Text.UTF8Encoding($false)

trap {
    Write-Host ("armor-install error: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# Locate inject block in AGENTS.md by marker comments.
function Find-InjectBlock([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, '<!--[^\r\n]*ARMOR-INJECT:BEGIN[^\r\n]*-->')
    if (-not $m.Success) {
        # Backward compat: also recognize earlier marker formats
        $m = [regex]::Match($Text, '<!--[^\r\n]*X-INJECT:BEGIN[^\r\n]*-->')
    }
    if (-not $m.Success) { return $null }
    $tail = $Text.Substring($m.Index + $m.Length)
    $e = [regex]::Match($tail, '<!--[^\r\n]*INJECT:END[^\r\n]*-->')
    if (-not $e.Success) { return $null }
    return @{ Start = $m.Index; End = $m.Index + $m.Length + $e.Index + $e.Length }
}

# Signatures that identify a file as a prior injection artifact (no markers, but content IS the prompt).
$injectSignatures = @(
    'INJECT:BEGIN',
    'ARMOR-INJECT',
    'UNRESTRICTED SANDBOX',
    'Little Code Sauce',
    'PRIME DIRECTIVE'
)

function Test-InjectionArtifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $t = Read-Utf8 $Path } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    foreach ($sig in $injectSignatures) {
        if ($t.Contains($sig)) { return $true }
    }
    return $false
}

function Get-CleanAgentsBackup {
    $cands = @()
    foreach ($pat in @('AGENTS.md.bak', 'AGENTS.md.bak_*', 'AGENTS.md.backup-*', 'AGENTS.md.zerox.bak')) {
        $cands += @(Get-ChildItem -LiteralPath $ConfigDir -Filter $pat -File -ErrorAction SilentlyContinue)
    }
    $managedBak = Join-Path $managedDir 'AGENTS.md.bak'
    if (Test-Path -LiteralPath $managedBak -PathType Leaf) {
        $cands += @(Get-Item -LiteralPath $managedBak)
    }
    foreach ($c in ($cands | Where-Object { $_ -and $_.Length -gt 0 } | Sort-Object LastWriteTime -Descending)) {
        if ($c.FullName -eq $agentsMd) { continue }
        if (Test-InjectionArtifact $c.FullName) { continue }
        return $c.FullName
    }
    return $null
}

# Resolve config dir
if ([string]::IsNullOrWhiteSpace($ConfigDir)) {
    if ($env:XDG_CONFIG_HOME) {
        $ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode'
    } else {
        $ConfigDir = Join-Path $HOME '.config\opencode'
    }
}
$ConfigDir = [System.IO.Path]::GetFullPath($ConfigDir)
$agentsMd = Join-Path $ConfigDir 'AGENTS.md'
$managedDir = Join-Path $ConfigDir 'armor-managed'
$backupPath = Join-Path $managedDir 'AGENTS.md.bak'
$markerEnd = '<!-- ARMOR-INJECT:END -->'

# Skills
if ([string]::IsNullOrWhiteSpace($SkillsSource)) {
    $SkillsSource = Join-Path $PSScriptRoot '..\skills'
}
if (-not [System.IO.Path]::IsPathRooted($SkillsSource)) {
    $SkillsSource = Join-Path $PSScriptRoot $SkillsSource
}
$skillsSource = $SkillsSource
$skillsTarget = Join-Path $ConfigDir 'skills'
$skillsManifestKey = 'installedSkills'

function Test-SkillCurrent([string]$SrcDir, [string]$DestDir) {
    $srcFile = [System.IO.Path]::Combine($SrcDir, 'SKILL.md')
    $dstFile = [System.IO.Path]::Combine($DestDir, 'SKILL.md')
    if (-not [System.IO.File]::Exists($srcFile)) { return $false }
    if (-not [System.IO.File]::Exists($dstFile)) { return $false }
    $s = New-Object System.IO.FileInfo($srcFile)
    $d = New-Object System.IO.FileInfo($dstFile)
    if ($s.Length -ne $d.Length) { return $false }
    if ([Math]::Abs(($s.LastWriteTimeUtc - $d.LastWriteTimeUtc).TotalSeconds) -gt 2) { return $false }
    return $true
}

function Get-SkillDirs {
    if (-not (Test-Path -LiteralPath $skillsSource)) { return @() }
    return @(Get-ChildItem -LiteralPath $skillsSource -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
}

function Install-Skills {
    $installed = @()
    $dirs = Get-SkillDirs
    if ($dirs.Count -eq 0) { return $installed }
    New-Item -ItemType Directory -Force -Path $skillsTarget | Out-Null

    $prevNames = @()
    $script:backedUpSkills = @{}
    $stPath = Join-Path $managedDir 'install-state.json'
    if (Test-Path -LiteralPath $stPath) {
        try {
            $ps = Read-Utf8 $stPath | ConvertFrom-Json
            if ($ps.installedSkills) { $prevNames = @($ps.installedSkills) }
            if ($ps.backedUpSkills) {
                foreach ($prop in $ps.backedUpSkills.PSObject.Properties) {
                    $script:backedUpSkills[$prop.Name] = [string]$prop.Value
                }
            }
        } catch {}
    }

    foreach ($d in $dirs) {
        $dest = Join-Path $skillsTarget $d.Name
        if ((Test-Path -LiteralPath $dest) -and ($prevNames -notcontains $d.Name)) {
            $bak = Join-Path $skillsTarget ($d.Name + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $dest -Destination $bak -Force
            $script:backedUpSkills[$d.Name] = $bak
            Write-Host ("Kept a copy of existing skill " + $d.Name + " -> " + (Split-Path -Leaf $bak)) -ForegroundColor Yellow
        }
        if (Test-SkillCurrent $d.FullName $dest) {
            $installed += $d.Name
            continue
        }
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        robocopy $d.FullName $dest /E /MT:16 /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $($d.FullName)" }
        $installed += $d.Name
    }
    return $installed
}

function Get-ShippedSkillNames {
    return @(Get-SkillDirs | Select-Object -ExpandProperty Name)
}

function Prune-StaleSkills([string[]]$Previous, [string[]]$Current) {
    $removedSkills = @()
    if (-not $Previous) { return $removedSkills }
    $shipped = Get-ShippedSkillNames
    foreach ($skillName in $Previous) {
        if ([string]::IsNullOrWhiteSpace($skillName)) { continue }
        if ($shipped -notcontains $skillName) { continue }
        if ($Current -contains $skillName) { continue }
        $dest = Join-Path $skillsTarget $skillName
        if (-not (Test-Path -LiteralPath $dest)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md'))) { continue }
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $removedSkills += $skillName
    }
    return $removedSkills
}

function Remove-Skills([string[]]$SkillNames) {
    $removedSkills = @()
    if (-not $SkillNames) { return $removedSkills }
    $shipped = Get-ShippedSkillNames
    foreach ($skillName in $SkillNames) {
        if ([string]::IsNullOrWhiteSpace($skillName)) { continue }
        if ($shipped -notcontains $skillName) { continue }
        $dest = Join-Path $skillsTarget $skillName
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
            $removedSkills += $skillName
        }
    }
    return $removedSkills
}

# Auto-detect prompt file if not specified
if ([string]::IsNullOrWhiteSpace($SourcePrompt) -and -not ($Uninstall -or $RestoreMemory)) {
    $mdFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\prompt') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($mdFiles.Count -eq 0) {
        $mdFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    if ($mdFiles.Count -eq 0) {
        throw "No .md prompt file found. Provide one via -SourcePrompt or place it in the prompt/ directory."
    }
    $SourcePrompt = $mdFiles[0].FullName
}

# ---- UNINSTALL / RESTORE ----
if ($Uninstall -or $RestoreMemory) {
    if (Test-Path -LiteralPath $agentsMd) {
        $cur = Read-Utf8 $agentsMd
        $blk = Find-InjectBlock $cur
        if ($blk) {
            $left = ($cur.Substring(0, $blk.Start) + $cur.Substring($blk.End)).Trim()
            $managedBak = Join-Path $managedDir 'AGENTS.md.bak'
            $normFn = { param($s) (($s -replace "`r`n", "`n").Trim()) }
            if ((Test-Path -LiteralPath $managedBak -PathType Leaf) -and
                ((& $normFn $left) -eq (& $normFn (Read-Utf8 $managedBak)))) {
                Copy-Item -LiteralPath $managedBak -Destination $agentsMd -Force
                Remove-Item -LiteralPath $managedBak -Force -ErrorAction SilentlyContinue
                Write-Host "AGENTS.md restored from pre-install backup (exact bytes)"
            } elseif ($left.Length -eq 0) {
                $clean = Get-CleanAgentsBackup
                if ($clean) {
                    Copy-Item -LiteralPath $clean -Destination $agentsMd -Force
                    Write-Host ("Restored original AGENTS.md from " + (Split-Path -Leaf $clean))
                } else {
                    Remove-Item -LiteralPath $agentsMd -Force
                    Write-Host "Removed injected AGENTS.md"
                }
            } else {
                Write-Utf8NoBom $agentsMd ($left + [Environment]::NewLine)
                Write-Host "Stripped injected section from AGENTS.md (user content kept)"
            }
        } elseif (Test-InjectionArtifact $agentsMd) {
            $aside = Join-Path $ConfigDir ('AGENTS.md.inject-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $agentsMd -Destination $aside -Force
            $clean = Get-CleanAgentsBackup
            if ($clean) {
                Copy-Item -LiteralPath $clean -Destination $agentsMd -Force
                Write-Host ("Restored original AGENTS.md from " + (Split-Path -Leaf $clean))
            } else {
                Write-Host ("Removed stale injection (copy at " + (Split-Path -Leaf $aside) + ")")
            }
        } else {
            Write-Host "No injection found, nothing to do"
        }
    } else {
        Write-Host "No AGENTS.md found, nothing to do"
    }
    if ($RestoreMemory) {
        Write-Host "Restore-memory mode: skills and install-state.json kept"
        exit 0
    }
    $statePath = Join-Path $managedDir 'install-state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.$skillsManifestKey) {
                $removedSkills = Remove-Skills @($state.$skillsManifestKey)
                if ($removedSkills.Count -gt 0) {
                    Write-Host ("Cleared skills: " + ($removedSkills -join ", "))
                }
            }
            if ($state.backedUpSkills) {
                foreach ($prop in $state.backedUpSkills.PSObject.Properties) {
                    $bak = [string]$prop.Value
                    if (-not (Test-Path -LiteralPath $bak)) { continue }
                    $dest = Join-Path $skillsTarget $prop.Name
                    if (Test-Path -LiteralPath $dest) {
                        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $bak -Destination $dest -Force
                    Write-Host ("Restored original skill: " + $prop.Name)
                }
            }
        } catch {
            Write-Host "Failed to read install-state.json, skipping skill removal"
        }
        Remove-Item -LiteralPath $statePath -Force
    }
    exit 0
}

# ---- INSTALL ----
if (-not (Test-Path -LiteralPath $SourcePrompt)) {
    throw "Prompt file not found: $SourcePrompt"
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $managedDir | Out-Null

$promptText = (Read-Utf8 $SourcePrompt).TrimEnd()
$markerBegin = '<!-- ARMOR-INJECT:BEGIN prompt=' + (Split-Path -Leaf $SourcePrompt) + ' -->'
$block = $markerBegin + [Environment]::NewLine + $promptText + [Environment]::NewLine + $markerEnd
$norm = { param($s) ($s -replace "`r`n", "`n").Trim() }
$normBody = & $norm $promptText

$existing = ''
if (Test-Path -LiteralPath $agentsMd) { $existing = Read-Utf8 $agentsMd }
$normExisting = & $norm $existing

$isPromptOnly = $false
if ($normExisting.Length -gt 0) {
    if ($normExisting -eq $normBody) {
        $isPromptOnly = $true
    } else {
        $blk0 = Find-InjectBlock $existing
        if ($blk0) {
            $outside = & $norm ($existing.Substring(0, $blk0.Start) + $existing.Substring($blk0.End))
            if ($outside.Length -eq 0) { $isPromptOnly = $true }
        }
        if (-not $isPromptOnly -and -not [string]::IsNullOrWhiteSpace($KnownPrompts)) {
            foreach ($k in ($KnownPrompts -split ';')) {
                if ([string]::IsNullOrWhiteSpace($k)) { continue }
                if (-not (Test-Path -LiteralPath $k)) { continue }
                if ($normExisting -eq (& $norm (Read-Utf8 $k))) { $isPromptOnly = $true; break }
            }
        }
    }
}

$blk = Find-InjectBlock $existing
if ($blk) {
    $existing = $existing.Substring(0, $blk.Start) + $block + $existing.Substring($blk.End)
    Write-Utf8NoBom $agentsMd ($existing.TrimEnd() + [Environment]::NewLine)
    Write-Host "Updated injected block in AGENTS.md (user content kept)"
} elseif ($normExisting.Length -eq 0 -or $isPromptOnly) {
    Write-Utf8NoBom $agentsMd ($block + [Environment]::NewLine)
    Write-Host "Injected prompt -> $agentsMd"
} elseif (Test-InjectionArtifact $agentsMd) {
    $aside = Join-Path $ConfigDir ('AGENTS.md.inject-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $agentsMd -Destination $aside -Force
    Write-Utf8NoBom $agentsMd ($block + [Environment]::NewLine)
    Write-Host ("Replaced stale injection -> $agentsMd (copy at " + (Split-Path -Leaf $aside) + ")")
} else {
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $agentsMd -Destination $backupPath -Force
        Write-Host "Backed up original AGENTS.md"
    }
    Write-Utf8NoBom $agentsMd ($existing.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $block + [Environment]::NewLine)
    Write-Host "Block appended -> $agentsMd (original content kept)"
}

# Skills
$prevSkills = @()
$prevStatePath = Join-Path $managedDir 'install-state.json'
if (Test-Path -LiteralPath $prevStatePath) {
    try {
        $prevState = Read-Utf8 $prevStatePath | ConvertFrom-Json
        if ($prevState.installedSkills) { $prevSkills = @($prevState.installedSkills) }
    } catch {}
}

$installedSkills = Install-Skills
if ($installedSkills.Count -gt 0) {
    Write-Host ("Skills: " + ($installedSkills -join ", "))
} else {
    Write-Host ("No skills installed (source: $skillsSource)")
}

$staleSkills = Prune-StaleSkills $prevSkills $installedSkills
if ($staleSkills.Count -gt 0) {
    Write-Host ("Dropped stale skills: " + ($staleSkills -join ", "))
}

$state = @{ $skillsManifestKey = $installedSkills }
if ($script:backedUpSkills -and $script:backedUpSkills.Count -gt 0) {
    $state['backedUpSkills'] = $script:backedUpSkills
}
$statePath = Join-Path $managedDir 'install-state.json'
$stateJson = $state | ConvertTo-Json
Write-Utf8NoBom $statePath $stateJson

Write-Host "Restart opencode to load the configured instructions."
