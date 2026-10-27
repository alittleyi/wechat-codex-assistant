[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 18789,

    [ValidateRange(120, 900)]
    [int]$MaxWaitSeconds = 420,

    [ValidateRange(1, 60)]
    [int]$KillDelaySeconds = 10,

    [string]$EvidencePath = '',

    [string]$WatchdogStatePath = (Join-Path $env:LOCALAPPDATA 'OpenClaw\gateway-watchdog\state.json'),

    [string]$RunToken = '',

    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $workspace = Split-Path -Parent $PSScriptRoot
    $EvidencePath = Join-Path $workspace 'runtime\gateway-watchdog-recovery.json'
}

if (-not $ProbeOnly -and [string]::IsNullOrWhiteSpace($RunToken)) {
    throw 'RunToken is required for a destructive recovery test.'
}

if (-not $ProbeOnly -and (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    try {
        $existingEvidence = Get-Content -LiteralPath $EvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$existingEvidence.runToken -eq $RunToken) {
            return
        }
    }
    catch {
        throw 'Existing recovery evidence is unreadable; refusing to repeat the destructive test.'
    }
}

function Test-LocalPort {
    param([int]$TargetPort)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $TargetPort)
        if (-not $connect.Wait(2000)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Find-GatewayTaskRoots {
    @(Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" | Where-Object {
        ([string]$_.CommandLine) -like '*\.openclaw\gateway.vbs*'
    })
}

function Write-Evidence {
    param([hashtable]$Record)
    $directory = Split-Path -Parent $EvidencePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tempPath = "$EvidencePath.tmp-$PID"
    [pscustomobject]$Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $EvidencePath -Force
}

$startedAt = [datetimeoffset]::Now
$roots = @(Find-GatewayTaskRoots)
$initial = [ordered]@{
    schemaVersion = 1
    runToken = $RunToken
    startedAt = $startedAt.ToString('o')
    stage = 'preflight'
    initialPortListening = (Test-LocalPort -TargetPort $Port)
    matchedRootCount = $roots.Count
    matchedRootPid = if ($roots.Count -eq 1) { [int]$roots[0].ProcessId } else { $null }
    recovered = $false
    portRecoveredAt = $null
    secondsToPortRecovery = $null
    watchdogTriggered = $false
    watchdogLastStartAttemptAt = $null
    failure = $null
}
Write-Evidence -Record $initial

if (-not $initial.initialPortListening) {
    $initial.stage = 'aborted'
    $initial.failure = 'Gateway port was not listening before the test.'
    Write-Evidence -Record $initial
    exit 2
}
if ($roots.Count -ne 1) {
    $initial.stage = 'aborted'
    $initial.failure = "Expected exactly one gateway.vbs root process, found $($roots.Count)."
    Write-Evidence -Record $initial
    exit 3
}
if ($ProbeOnly) {
    $initial.stage = 'probe-only'
    Write-Evidence -Record $initial
    return
}

$initial.stage = 'armed'
Write-Evidence -Record $initial
Start-Sleep -Seconds $KillDelaySeconds

$killOutput = & taskkill.exe /PID ([string]$roots[0].ProcessId) /T /F 2>&1
$initial.stage = 'waiting-for-recovery'
$initial.killAt = [datetimeoffset]::Now.ToString('o')
$initial.killExitCode = $LASTEXITCODE
$initial.killSummary = (($killOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
Write-Evidence -Record $initial
if ($LASTEXITCODE -ne 0) {
    $initial.stage = 'failed'
    $initial.failure = 'taskkill failed.'
    Write-Evidence -Record $initial
    exit 4
}

$deadline = [datetimeoffset]::Now.AddSeconds($MaxWaitSeconds)
do {
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath $WatchdogStatePath -PathType Leaf) {
        try {
            $watchdogState = Get-Content -LiteralPath $WatchdogStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($watchdogState.lastStartAttemptAt) {
                $attempt = [datetimeoffset]::Parse([string]$watchdogState.lastStartAttemptAt)
                if ($attempt -ge $startedAt) {
                    $initial.watchdogTriggered = $true
                    $initial.watchdogLastStartAttemptAt = $attempt.ToString('o')
                }
            }
        }
        catch {
            # Evidence collection must not interfere with recovery observation.
        }
    }
    if (Test-LocalPort -TargetPort $Port) {
        $recoveredAt = [datetimeoffset]::Now
        $initial.stage = 'recovered'
        $initial.recovered = $true
        $initial.portRecoveredAt = $recoveredAt.ToString('o')
        $initial.secondsToPortRecovery = [math]::Round(($recoveredAt - $startedAt).TotalSeconds, 1)
        Write-Evidence -Record $initial
        exit 0
    }
} while ([datetimeoffset]::Now -lt $deadline)

$initial.stage = 'timed-out'
$initial.failure = "Gateway port did not recover within $MaxWaitSeconds seconds."
Write-Evidence -Record $initial
exit 5
