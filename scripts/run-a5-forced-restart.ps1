[CmdletBinding()]
param(
    [int]$DelaySeconds = 8,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\a5-forced-restart.json'
}
$evidenceDir = Split-Path -Parent $EvidencePath
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
Start-Sleep -Seconds $DelaySeconds

$startedAt = (Get-Date).ToString('o')
$openclaw = Join-Path $env:APPDATA 'npm\openclaw.cmd'
try {
    $output = & $openclaw gateway restart --force --json 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $result = [ordered]@{
        startedAt = $startedAt
        finishedAt = (Get-Date).ToString('o')
        exitCode = $exitCode
        output = $output.Trim()
    }
} catch {
    $result = [ordered]@{
        startedAt = $startedAt
        finishedAt = (Get-Date).ToString('o')
        exitCode = -1
        error = $_.Exception.Message
    }
}

$json = $result | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
