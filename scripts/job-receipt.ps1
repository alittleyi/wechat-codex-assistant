[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start','complete','fail','status')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$RequestId,

    [Parameter(Mandatory = $false)]
    [ValidateLength(0,200)]
    [string]$Description = ''
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$receiptsDir = Join-Path $workspace 'receipts'
New-Item -ItemType Directory -Path $receiptsDir -Force | Out-Null

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $requestHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($RequestId)))).Replace('-','').ToLowerInvariant()
} finally {
    $sha.Dispose()
}
$path = Join-Path $receiptsDir ($requestHash.Substring(0,24) + '.json')
$existing = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

if ($Action -eq 'status') {
    if ($existing) { $existing | ConvertTo-Json -Depth 5 } else { [pscustomobject]@{ status='not_found'; requestHash=$requestHash.Substring(0,12) } | ConvertTo-Json }
    exit 0
}

if ($Action -eq 'start' -and $existing -and $existing.status -eq 'completed') {
    [pscustomobject]@{ status='duplicate_completed'; requestHash=$requestHash.Substring(0,12); completedAt=$existing.completedAt } | ConvertTo-Json
    exit 0
}

$now = (Get-Date).ToString('o')
$record = [ordered]@{
    schemaVersion = 1
    requestHash = $requestHash
    status = switch ($Action) { 'start' {'running'} 'complete' {'completed'} 'fail' {'failed'} }
    description = $Description
    startedAt = if ($existing.startedAt) { $existing.startedAt } else { $now }
    updatedAt = $now
}
if ($Action -eq 'complete') { $record.completedAt = $now }
if ($Action -eq 'fail') { $record.failedAt = $now }

$json = [pscustomobject]$record | ConvertTo-Json -Depth 5
$temp = "$path.tmp-$PID"
[System.IO.File]::WriteAllText($temp,$json,[System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination $path -Force
[pscustomobject]@{ status=$record.status; requestHash=$requestHash.Substring(0,12); receiptPath=$path } | ConvertTo-Json
