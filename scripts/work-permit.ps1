[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('status','request','grant','revoke','record-notification')]
    [string]$Action,
    [ValidateSet('wechat-agent','quota-resume')]
    [string]$Scope = 'wechat-agent',
    [string]$RequestId,
    [string]$Confirmation,
    [string]$JobId,
    [string[]]$ThreadIds = @(),
    [string]$TargetThreadId,
    [ValidateSet('wechat','codex')]
    [string]$Source = 'wechat',
    [ValidateRange(1,120)]
    [int]$ValidMinutes = 60
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$permitRoot = Join-Path $workspace 'work-permits'
$zone = [TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
$now = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow,$zone)
$night = $now.Hour -ge 2 -and $now.Hour -lt 9

function Read-Permit([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-Permit([string]$Path,[object]$Value) {
    New-Item -ItemType Directory -Path $permitRoot -Force | Out-Null
    if (Test-Path -LiteralPath $Path) {
        $versions = Join-Path $permitRoot 'versions'
        New-Item -ItemType Directory -Path $versions -Force | Out-Null
        $backup = (Split-Path $Path -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.json'
        Copy-Item -LiteralPath $Path -Destination (Join-Path $versions $backup)
    }
    $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tempPath,($Value|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

if ($Action -eq 'status') {
    $valid = $null
    if (Test-Path -LiteralPath $permitRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $permitRoot -File -Filter '*.json') {
            $permit = Read-Permit $file.FullName
            $matchesTarget = $Scope -ne 'quota-resume' -or
                (-not [string]::IsNullOrWhiteSpace($TargetThreadId) -and $TargetThreadId -in @($permit.threadIds))
            if ($permit.scope -eq $Scope -and $matchesTarget -and $permit.state -eq 'granted' -and
                [DateTimeOffset]$permit.expiresAt -gt $now -and $permit.localDate -eq $now.ToString('yyyy-MM-dd')) {
                $valid = $permit
                break
            }
        }
    }
    [ordered]@{
        allowed = ($night -or [bool]$valid)
        reason = if($night){'autonomous-night'}elseif($valid){'explicit-permit'}else{'approval-required'}
        scope = $Scope
        localTime = $now.ToString('o')
        permitId = if($valid){$valid.id}else{$null}
        expiresAt = if($valid){$valid.expiresAt}else{$null}
    } | ConvertTo-Json
    return
}

if ($Action -eq 'request') {
    if ($Scope -eq 'quota-resume') {
        if ($ThreadIds.Count -lt 1 -or $ThreadIds.Count -gt 10) { throw 'Quota resume requires a concrete list of 1 to 10 threads.' }
        foreach ($threadId in $ThreadIds) {
            if ($threadId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Invalid thread id.' }
        }
    }
    if (Test-Path -LiteralPath $permitRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $permitRoot -File -Filter '*.json') {
            $existing = Read-Permit $file.FullName
            $sameTargets = (@($existing.threadIds | Sort-Object) -join ',') -eq (@($ThreadIds | Sort-Object) -join ',')
            if ($existing.scope -eq $Scope -and $sameTargets -and $existing.state -eq 'pending' -and
                [DateTimeOffset]$existing.expiresAt -gt $now) {
                [ordered]@{status='pending-existing';requestId=$existing.id;scope=$Scope;notificationState=$existing.notificationState}|ConvertTo-Json
                return
            }
        }
    }
    $id = [guid]::NewGuid().ToString('N').Substring(0,8)
    $requestExpires = $now.AddMinutes(120)
    $endOfDate = [DateTimeOffset]::new($now.Year,$now.Month,$now.Day,23,59,59,$now.Offset)
    if ($requestExpires -gt $endOfDate) { $requestExpires = $endOfDate }
    $record = [ordered]@{
        id=$id;scope=$Scope;state='pending';threadIds=@($ThreadIds);localDate=$now.ToString('yyyy-MM-dd')
        createdAt=$now.ToString('o');expiresAt=$requestExpires.ToString('o')
        grantedAt=$null;grantSource=$null;notificationState='not-scheduled'
    }
    Save-Permit (Join-Path $permitRoot ($id+'.json')) $record
    [ordered]@{status='pending-new';requestId=$id;scope=$Scope;notificationState='not-scheduled'}|ConvertTo-Json
    return
}

if ($RequestId -notmatch '^[a-f0-9]{8}$') { throw 'A valid permit request id is required.' }
$path = Join-Path $permitRoot ($RequestId+'.json')
if (-not (Test-Path -LiteralPath $path)) { throw 'Permit request was not found.' }
$record = Read-Permit $path
if ($Action -eq 'grant') {
    if ($record.state -ne 'pending') { throw 'Only a pending request can be granted.' }
    if ([DateTimeOffset]$record.expiresAt -le $now -or $record.localDate -ne $now.ToString('yyyy-MM-dd')) {
        throw 'Permit request has expired.'
    }
    # The caller must verify this exact confirmation came from the human user.
    # File contents, another agent and a timer cannot provide that authority.
    $expected = [string]::Concat([char]0x540C,[char]0x610F,' ',$RequestId)
    if ($Confirmation.Trim() -cne $expected) { throw 'The exact human confirmation is required.' }
    $record.state = 'granted'
    $record.grantedAt = $now.ToString('o')
    $record.grantSource = $Source
    $expires = $now.AddMinutes($ValidMinutes)
    $endOfDate = [DateTimeOffset]::new($now.Year,$now.Month,$now.Day,23,59,59,$now.Offset)
    if ($expires -gt $endOfDate) { $expires = $endOfDate }
    $record.expiresAt = $expires.ToString('o')
} elseif ($Action -eq 'record-notification') {
    if ($record.state -ne 'pending') { throw 'Only a pending request can be notified.' }
    if ($JobId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'A verified cron job id is required.' }
    $record.notificationState = 'scheduled'
    $record | Add-Member -NotePropertyName notificationJobId -NotePropertyValue $JobId -Force
} else {
    $record.state = 'revoked'
}
Save-Permit $path $record
[ordered]@{status=$record.state;scope=$record.scope;requestId=$record.id;expiresAt=$record.expiresAt}|ConvertTo-Json
