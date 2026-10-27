[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 18789,

    [ValidateRange(60, 1800)]
    [int]$StartupGraceSeconds = 300,

    [string]$GatewayTaskName = 'OpenClaw Gateway',

    [string]$LauncherPath = (Join-Path $env:USERPROFILE '.openclaw\gateway.vbs'),

    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'OpenClaw\gateway-watchdog\state.json'),

    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Stop'

function Test-LocalPort {
    param([int]$TargetPort)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $TargetPort)
        if (-not $connect.Wait(2000)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-GatewayProcesses {
    param([int]$TargetPort)

    $portToken = "--port $TargetPort"
    @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
        $commandLine = [string]$_.CommandLine
        $commandLine -like '*openclaw*' -and
        $commandLine -like '* gateway *' -and
        $commandLine -like "*$portToken*"
    })
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try {
        Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $null
    }
}

function Write-State {
    param(
        [string]$Status,
        [hashtable]$Details = @{}
    )

    $directory = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $previous = Read-State
    $record = [ordered]@{
        schemaVersion = 1
        checkedAt = (Get-Date).ToString('o')
        status = $Status
        port = $Port
        gatewayTaskName = $GatewayTaskName
        startupGraceSeconds = $StartupGraceSeconds
        lastStartAttemptAt = $previous.lastStartAttemptAt
        details = $Details
    }
    if ($Status -eq 'start-triggered') {
        $record.lastStartAttemptAt = $record.checkedAt
    }
    $tempPath = "$StatePath.tmp-$PID"
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
    [pscustomobject]$record
}

if (Test-LocalPort -TargetPort $Port) {
    Write-State -Status 'healthy' -Details @{ listening = $true; action = 'none' }
    return
}

$processes = Get-GatewayProcesses -TargetPort $Port
if ($processes.Count -gt 0) {
    $oldest = $processes | Sort-Object CreationDate | Select-Object -First 1
    $ageSeconds = [math]::Max(0, ((Get-Date) - $oldest.CreationDate).TotalSeconds)
    $status = if ($ageSeconds -lt $StartupGraceSeconds) { 'startup-grace' } else { 'startup-stalled' }
    Write-State -Status $status -Details @{
        listening = $false
        action = 'none'
        processCount = $processes.Count
        oldestProcessAgeSeconds = [math]::Round($ageSeconds, 1)
    }
    return
}

$previous = Read-State
if ($previous.lastStartAttemptAt) {
    try {
        $lastAttempt = [datetimeoffset]::Parse([string]$previous.lastStartAttemptAt)
        $cooldownAge = ([datetimeoffset]::Now - $lastAttempt).TotalSeconds
        if ($cooldownAge -lt $StartupGraceSeconds) {
            Write-State -Status 'start-cooldown' -Details @{
                listening = $false
                action = 'none'
                secondsSinceLastStartAttempt = [math]::Round($cooldownAge, 1)
            }
            return
        }
    }
    catch {
        # Ignore an invalid historical timestamp and continue with a fresh decision.
    }
}

if ($ProbeOnly) {
    Write-State -Status 'would-start' -Details @{ listening = $false; action = 'probe-only' }
    return
}

if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Gateway launcher was not found: $LauncherPath"
}
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
Start-Process -FilePath $wscriptPath -ArgumentList @("`"$LauncherPath`"") -WindowStyle Hidden
Write-State -Status 'start-triggered' -Details @{
    listening = $false
    action = 'start-gateway-launcher'
}
