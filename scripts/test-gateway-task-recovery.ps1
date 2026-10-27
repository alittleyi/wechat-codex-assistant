[CmdletBinding()]
param(
    [int]$DelaySeconds = 8,
    [int]$NaturalRecoveryWaitSeconds = 90,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\gateway-task-recovery.json'
}
$evidenceDir = Split-Path -Parent $EvidencePath
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

$taskName = 'OpenClaw Gateway'
$gatewayVbs = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.openclaw\gateway.vbs'))
$result = [ordered]@{
    startedAt = (Get-Date).ToString('o')
    taskName = $taskName
    expectedGatewayVbs = $gatewayVbs
    oldRootPid = $null
    naturalRecovery = $false
    fallbackStarted = $false
    newRootPid = $null
    portReachable = $false
    error = $null
}

try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -ne 'Running') { throw "Scheduled task is not running: $($task.State)" }

    $roots = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'wscript.exe' -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($gatewayVbs, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($roots.Count -ne 1) { throw "Expected exactly one Gateway task root; found $($roots.Count)." }

    $result.oldRootPid = [int]$roots[0].ProcessId
    Start-Sleep -Seconds $DelaySeconds
    & taskkill.exe /PID $result.oldRootPid /T /F | Out-Null
    Start-Sleep -Seconds $NaturalRecoveryWaitSeconds

    $newRoots = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'wscript.exe' -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($gatewayVbs, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $result.portReachable = [bool](Test-NetConnection -ComputerName 127.0.0.1 -Port 18789 -InformationLevel Quiet -WarningAction SilentlyContinue)
    if ($newRoots.Count -eq 1 -and [int]$newRoots[0].ProcessId -ne $result.oldRootPid -and $result.portReachable) {
        $result.naturalRecovery = $true
        $result.newRootPid = [int]$newRoots[0].ProcessId
    } else {
        Start-ScheduledTask -TaskName $taskName
        $result.fallbackStarted = $true
        Start-Sleep -Seconds 20
        $newRoots = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'wscript.exe' -and
            $_.CommandLine -and
            $_.CommandLine.IndexOf($gatewayVbs, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        $result.portReachable = [bool](Test-NetConnection -ComputerName 127.0.0.1 -Port 18789 -InformationLevel Quiet -WarningAction SilentlyContinue)
        if ($newRoots.Count -eq 1) { $result.newRootPid = [int]$newRoots[0].ProcessId }
    }
} catch {
    $result.error = $_.Exception.Message
    try {
        Start-ScheduledTask -TaskName $taskName
        $result.fallbackStarted = $true
    } catch {}
}

$result.finishedAt = (Get-Date).ToString('o')
[IO.File]::WriteAllText(
    $EvidencePath,
    ($result | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false)
)
