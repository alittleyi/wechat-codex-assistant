[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start','status','checkpoint','pause','resume','complete')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$MissionId,

    [Parameter(Mandatory = $false)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Goal,

    [Parameter(Mandatory = $false)]
    [ValidateSet('relay','field','review','watch','deliver','decision')]
    [string]$Mode = 'relay',

    [Parameter(Mandatory = $false)]
    [string[]]$SuccessCriteria = @(),

    [Parameter(Mandatory = $false)]
    [string]$Note,

    [Parameter(Mandatory = $false)]
    [string]$RequestId,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$missionsRoot = Join-Path $workspace 'missions'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-JsonAtomic {
    param([string]$Path,[object]$Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $json = $Value | ConvertTo-Json -Depth 8
    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($tempPath,$json,$utf8)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Append-Event {
    param([string]$Directory,[object]$Event)
    $line = ($Event | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine
    [System.IO.File]::AppendAllText((Join-Path $Directory 'timeline.jsonl'),$line,$utf8)
}

function Get-RequestHash {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SafeSlug {
    param([string]$Value)
    $slug = ($Value -replace '[^\p{L}\p{Nd}._-]+','-').Trim('-','.','_')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'mission' }
    if ($slug.Length -gt 36) { $slug = $slug.Substring(0,36).TrimEnd('-','.','_') }
    return $slug
}

function Resolve-MissionDirectory {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[\p{L}\p{Nd}._-]+$') {
        throw 'A valid MissionId is required.'
    }
    $directory = Join-Path $missionsRoot $Id
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'Mission was not found.'
    }
    return $directory
}

function Read-Manifest {
    param([string]$Directory)
    return (Get-Content -LiteralPath (Join-Path $Directory 'mission.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-ManifestVersioned {
    param([string]$Directory,[object]$Manifest)
    $manifestPath = Join-Path $Directory 'mission.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $versions = Join-Path $Directory 'versions'
        New-Item -ItemType Directory -Path $versions -Force | Out-Null
        $versionName = 'mission-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json'
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $versions $versionName)
    }
    Write-JsonAtomic -Path $manifestPath -Value $Manifest
}

if ($Action -eq 'start') {
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Goal)) {
        throw 'Name and Goal are required when starting a mission.'
    }
    if ($Goal.Length -gt 4000) { throw 'Goal is too long.' }
    if ($SuccessCriteria.Count -gt 12) { throw 'At most 12 success criteria are allowed.' }

    $requestHash = Get-RequestHash -Value $RequestId
    if ($requestHash -and (Test-Path -LiteralPath $missionsRoot)) {
        foreach ($manifestFile in Get-ChildItem -LiteralPath $missionsRoot -File -Recurse -Filter 'mission.json' -ErrorAction SilentlyContinue) {
            try {
                $existing = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($existing.requestHash -eq $requestHash) {
                    [ordered]@{
                        status = 'duplicate'
                        missionId = $existing.id
                        state = $existing.state
                        name = $existing.name
                    } | ConvertTo-Json -Depth 4
                    return
                }
            } catch { continue }
        }
    }

    $now = Get-Date
    $id = $now.ToString('yyyyMMdd-HHmmss') + '-' + (Get-SafeSlug -Value $Name) + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $manifest = [ordered]@{
        schemaVersion = 1
        id = $id
        name = $Name.Trim()
        goal = $Goal.Trim()
        mode = $Mode
        state = 'active'
        createdAt = $now.ToString('o')
        updatedAt = $now.ToString('o')
        requestHash = $requestHash
        successCriteria = @($SuccessCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        checkpointCount = 0
        lastCheckpoint = $null
        resultSummary = $null
        safetyGates = @(
            'external-message-confirmation',
            'destructive-action-confirmation',
            'account-and-payment-confirmation',
            'sensitive-data-transmission-confirmation'
        )
    }

    if ($DryRun) {
        [ordered]@{ status='dry-run'; mission=$manifest } | ConvertTo-Json -Depth 8
        return
    }

    $directory = Join-Path $missionsRoot $id
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Save-ManifestVersioned -Directory $directory -Manifest $manifest
    Append-Event -Directory $directory -Event ([ordered]@{
        at = $now.ToString('o'); action = 'start'; state = 'active'; note = 'Mission created.'
    })
    [ordered]@{
        status = 'started'
        missionId = $id
        state = 'active'
        mode = $Mode
        missionPath = $directory
    } | ConvertTo-Json -Depth 5
    return
}

$missionDirectory = Resolve-MissionDirectory -Id $MissionId
$manifest = Read-Manifest -Directory $missionDirectory

if ($Action -eq 'status') {
    [ordered]@{
        status = 'ok'
        missionId = $manifest.id
        name = $manifest.name
        goal = $manifest.goal
        mode = $manifest.mode
        state = $manifest.state
        updatedAt = $manifest.updatedAt
        checkpointCount = $manifest.checkpointCount
        lastCheckpoint = $manifest.lastCheckpoint
        resultSummary = $manifest.resultSummary
        successCriteria = @($manifest.successCriteria)
    } | ConvertTo-Json -Depth 6
    return
}

$allowedTransitions = @{
    checkpoint = @('active')
    pause      = @('active')
    resume     = @('paused')
    complete   = @('active','paused')
}
if ($manifest.state -notin $allowedTransitions[$Action]) {
    throw "Action '$Action' is not allowed while mission state is '$($manifest.state)'."
}

$now = Get-Date
switch ($Action) {
    'checkpoint' {
        if ([string]::IsNullOrWhiteSpace($Note)) { throw 'Note is required for a checkpoint.' }
        $manifest.checkpointCount = [int]$manifest.checkpointCount + 1
        $manifest.lastCheckpoint = $Note.Trim()
    }
    'pause' {
        $manifest.state = 'paused'
        if (-not [string]::IsNullOrWhiteSpace($Note)) { $manifest.lastCheckpoint = $Note.Trim() }
    }
    'resume' {
        $manifest.state = 'active'
        if (-not [string]::IsNullOrWhiteSpace($Note)) { $manifest.lastCheckpoint = $Note.Trim() }
    }
    'complete' {
        if ([string]::IsNullOrWhiteSpace($Note)) { throw 'Note is required when completing a mission.' }
        $manifest.state = 'completed'
        $manifest.resultSummary = $Note.Trim()
    }
}
$manifest.updatedAt = $now.ToString('o')

if ($DryRun) {
    [ordered]@{ status='dry-run'; action=$Action; mission=$manifest } | ConvertTo-Json -Depth 8
    return
}

Save-ManifestVersioned -Directory $missionDirectory -Manifest $manifest
Append-Event -Directory $missionDirectory -Event ([ordered]@{
    at = $now.ToString('o')
    action = $Action
    state = $manifest.state
    note = if ([string]::IsNullOrWhiteSpace($Note)) { $null } else { $Note.Trim() }
})

[ordered]@{
    status = 'updated'
    action = $Action
    missionId = $manifest.id
    state = $manifest.state
    checkpointCount = $manifest.checkpointCount
} | ConvertTo-Json -Depth 5
