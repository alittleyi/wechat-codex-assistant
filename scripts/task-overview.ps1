[CmdletBinding()]
param(
    [ValidateRange(1,20)][int]$Limit=8,
    [switch]$IncludeCompleted,
    [string]$TaskRoot
)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($TaskRoot)){$TaskRoot=Join-Path $workspace 'tasks'}

function Protect-Text([string]$Value,[int]$Max=180){
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $safe=($Value-replace '\s+',' ').Trim()
    $safe=$safe-replace '(?i)(password|passwd|secret|token|cookie|api[_-]?key)\s*[:=]\s*\S+','$1=[redacted]'
    $safe=$safe-replace '(?<!\d)1[3-9]\d{9}(?!\d)','[phone-redacted]'
    $safe=$safe-replace '(?<!\d)\d{17}[\dXx](?!\d)','[identity-redacted]'
    $safe=$safe-replace '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}','[email-redacted]'
    if($safe.Length-gt$Max){$safe=$safe.Substring(0,$Max)+'...'}
    return $safe
}

$labels=@{
    active='working';'awaiting-user'='waiting-for-user';paused='paused'
    'awaiting-acceptance'='waiting-for-acceptance';completed='completed'
}
$rows=@()
$unreadable=0
if(Test-Path -LiteralPath $TaskRoot -PathType Container){
    foreach($file in Get-ChildItem -LiteralPath $TaskRoot -Filter task.json -File -Recurse -ErrorAction SilentlyContinue){
        try{
            $task=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
            if(-not$IncludeCompleted -and $task.state-eq'completed'){continue}
            $rows+=[pscustomobject]@{
                title=Protect-Text ([string]$task.title) 100
                state=if($labels.ContainsKey([string]$task.state)){$labels[[string]$task.state]}else{'unknown'}
                currentStep=Protect-Text ([string]$task.currentStep)
                nextAction=Protect-Text ([string]$task.nextAction)
                updatedAt=[string]$task.updatedAt
                artifactCount=@($task.artifacts).Count
                acceptanceState=[string]$task.acceptance.state
            }
        }catch{$unreadable++}
    }
}
$rows=@($rows|Sort-Object {[datetimeoffset]$_.updatedAt} -Descending|Select-Object -First $Limit)
[ordered]@{
    status='ok';taskCount=$rows.Count;unreadableCount=$unreadable;tasks=$rows
}|ConvertTo-Json -Depth 6
