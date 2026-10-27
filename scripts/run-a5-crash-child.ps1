[CmdletBinding()]
param(
    [int]$DelaySeconds = 8,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\a5-crash-child.json'
}
$evidenceDir = Split-Path -Parent $EvidencePath
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
Start-Sleep -Seconds $DelaySeconds

$startedAt = (Get-Date).ToString('o')
try {
    $matches = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'node.exe' -and
        $_.CommandLine -like '*openclaw*gateway*--task-supervisor-child=*'
    })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one supervised Gateway child; found $($matches.Count)."
    }
    $oldPid = [int]$matches[0].ProcessId
    Stop-Process -Id $oldPid -Force
    Start-Sleep -Seconds 15
    $replacement = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'node.exe' -and
        $_.CommandLine -like '*openclaw*gateway*--task-supervisor-child=*'
    })
    $result = [ordered]@{
        startedAt = $startedAt
        finishedAt = (Get-Date).ToString('o')
        oldPid = $oldPid
        replacementCount = $replacement.Count
        replacementPid = if ($replacement.Count -eq 1) { [int]$replacement[0].ProcessId } else { $null }
    }
} catch {
    $result = [ordered]@{
        startedAt = $startedAt
        finishedAt = (Get-Date).ToString('o')
        error = $_.Exception.Message
    }
}

[IO.File]::WriteAllText(
    $EvidencePath,
    ($result | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false)
)
