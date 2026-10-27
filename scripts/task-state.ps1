[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start','status','list','checkpoint','await-user','pause','resume','link','artifact','sync','complete','accept')]
    [string]$Action,
    [string]$TaskId,
    [string]$Title,
    [string]$Goal,
    [ValidateSet('relay','review','field')]
    [string]$Mode='relay',
    [string]$ProjectPath,
    [string]$Note,
    [string]$NextAction,
    [ValidateSet('mission','review','field')]
    [string]$LinkType,
    [string]$LinkId,
    [string]$ArtifactPath,
    [string]$ArtifactKind='file',
    [ValidateSet('active','awaiting-user','paused','awaiting-acceptance')]
    [string]$State,
    [ValidateSet('verified','rejected')]
    [string]$AcceptanceState,
    [string]$RequestId,
    [string]$TaskRoot
)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($TaskRoot)){$TaskRoot=Join-Path $workspace 'tasks'}
$utf8=[Text.UTF8Encoding]::new($false)

function Hash-Text([string]$Value){
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}
function Save-Atomic([string]$Path,[object]$Value){
    $dir=Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $dir -Force|Out-Null
    $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 12),$utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Append-Event([string]$Dir,[string]$EventAction,[string]$State,[string]$EventNote){
    $event=[ordered]@{at=(Get-Date).ToString('o');action=$EventAction;state=$State;note=$EventNote}
    [IO.File]::AppendAllText((Join-Path $Dir 'timeline.jsonl'),(($event|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
}
function Resolve-Task([string]$Id){
    if($Id -notmatch '^t-[a-f0-9]{10}$'){throw 'A valid task id is required.'}
    $dir=Join-Path $TaskRoot $Id
    if(-not(Test-Path -LiteralPath $dir -PathType Container)){throw 'Task was not found.'}
    return $dir
}
function Read-Task([string]$Dir){Get-Content -LiteralPath (Join-Path $Dir 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json}
function Save-Versioned([string]$Dir,[object]$Task){
    $path=Join-Path $Dir 'task.json'
    if(Test-Path -LiteralPath $path){
        $history=Join-Path $Dir 'versions';New-Item -ItemType Directory -Path $history -Force|Out-Null
        Copy-Item -LiteralPath $path -Destination (Join-Path $history ('task-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json'))
    }
    Save-Atomic $path $Task
}
function Write-Summary([object]$Task){
    [ordered]@{
        status='ok';taskId=$Task.id;title=$Task.title;mode=$Task.mode;state=$Task.state
        goal=$Task.goal;projectPath=$Task.projectPath;currentStep=$Task.currentStep
        nextAction=$Task.nextAction;updatedAt=$Task.updatedAt
        acceptance=$Task.acceptance;links=$Task.links;artifactCount=@($Task.artifacts).Count
    }|ConvertTo-Json -Depth 8
}

if($Action -eq 'start'){
    if([string]::IsNullOrWhiteSpace($Title)-or[string]::IsNullOrWhiteSpace($Goal)){throw 'Title and Goal are required.'}
    if($Title.Length -gt 120 -or $Goal.Length -gt 4000){throw 'Title or Goal is too long.'}
    $requestHash=Hash-Text $RequestId
    if($requestHash -and (Test-Path -LiteralPath $TaskRoot)){
        foreach($file in Get-ChildItem -LiteralPath $TaskRoot -Filter task.json -File -Recurse -ErrorAction SilentlyContinue){
            try{$old=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;if($old.requestHash -eq $requestHash){Write-Summary $old;return}}catch{}
        }
    }
    $resolvedProject=$null
    if(-not[string]::IsNullOrWhiteSpace($ProjectPath)){
        $project=Get-Item -LiteralPath $ProjectPath -Force
        if(-not $project.PSIsContainer -or $project.LinkType -or (($project.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0)){throw 'ProjectPath must be a real directory.'}
        $resolvedProject=$project.FullName
    }
    $id='t-'+[guid]::NewGuid().ToString('N').Substring(0,10)
    $now=(Get-Date).ToString('o')
    $links=[ordered]@{}
    $links['mission']=$null
    $links['review']=$null
    $links['field']=$null
    $acceptance=[ordered]@{}
    $acceptance['state']='unverified'
    $acceptance['note']=$null
    $acceptance['at']=$null
    $task=[ordered]@{}
    $task['schemaVersion']=1
    $task['id']=$id
    $task['title']=$Title.Trim()
    $task['goal']=$Goal.Trim()
    $task['mode']=$Mode
    $task['state']='active'
    $task['projectPath']=$resolvedProject
    $task['createdAt']=$now
    $task['updatedAt']=$now
    $task['requestHash']=$requestHash
    $task['currentStep']='Task created'
    $task['nextAction']=$NextAction
    $task['links']=$links
    $task['artifacts']=@()
    $task['acceptance']=$acceptance
    $dir=Join-Path $TaskRoot $id;New-Item -ItemType Directory -Path $dir -Force|Out-Null
    Save-Versioned $dir $task;Append-Event $dir 'start' 'active' 'Task created.'
    Write-Summary $task;return
}

if($Action -eq 'list'){
    $rows=@()
    if(Test-Path -LiteralPath $TaskRoot){
        foreach($file in Get-ChildItem -LiteralPath $TaskRoot -Filter task.json -File -Recurse|Sort-Object LastWriteTimeUtc -Descending){
            try{$t=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;$rows+=[pscustomobject]@{taskId=$t.id;title=$t.title;mode=$t.mode;state=$t.state;updatedAt=$t.updatedAt;nextAction=$t.nextAction}}catch{}
        }
    }
    [ordered]@{status='ok';tasks=$rows}|ConvertTo-Json -Depth 6;return
}

$dir=Resolve-Task $TaskId;$task=Read-Task $dir
if($Action -eq 'status'){Write-Summary $task;return}

$allowed=@{
    checkpoint=@('active','awaiting-user');'await-user'=@('active');pause=@('active','awaiting-user')
    resume=@('paused');link=@('active','awaiting-user','paused');artifact=@('active','awaiting-user')
    sync=@('active','awaiting-user','paused','awaiting-acceptance')
    complete=@('active','awaiting-user');accept=@('awaiting-acceptance')
}
if($task.state -notin $allowed[$Action]){throw "Action '$Action' is not allowed while state is '$($task.state)'."}
$eventNote=$Note
switch($Action){
    'checkpoint'{if([string]::IsNullOrWhiteSpace($Note)){throw 'Note is required.'};$task.state='active';$task.currentStep=$Note.Trim();$task.nextAction=$NextAction;$task.acceptance.state='unverified'}
    'await-user'{if([string]::IsNullOrWhiteSpace($NextAction)){throw 'NextAction is required.'};$task.state='awaiting-user';$task.currentStep=$Note;$task.nextAction=$NextAction}
    'pause'{$task.state='paused';if($Note){$task.currentStep=$Note};$task.nextAction=$NextAction}
    'resume'{$task.state='active';if($Note){$task.currentStep=$Note};$task.nextAction=$NextAction}
    'link'{if([string]::IsNullOrWhiteSpace($LinkType)-or[string]::IsNullOrWhiteSpace($LinkId)){throw 'LinkType and LinkId are required.'};$task.links.$LinkType=$LinkId;$eventNote="$LinkType=$LinkId"}
    'artifact'{
        $file=Get-Item -LiteralPath $ArtifactPath -Force
        if($file.PSIsContainer -or $file.LinkType -or (($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0)){throw 'Artifact must be a regular file.'}
        $record=[pscustomobject]@{kind=$ArtifactKind;path=$file.FullName;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;sizeBytes=$file.Length;addedAt=(Get-Date).ToString('o')}
        $task.artifacts=@($task.artifacts)+@($record);$eventNote="$ArtifactKind artifact added"
    }
    'sync'{
        if([string]::IsNullOrWhiteSpace($State)-or[string]::IsNullOrWhiteSpace($Note)){throw 'State and Note are required.'}
        if([bool]$LinkType -ne [bool]$LinkId){throw 'LinkType and LinkId must be supplied together.'}
        if($LinkType){$task.links.$LinkType=$LinkId}
        $task.state=$State
        $task.currentStep=$Note.Trim()
        $task.nextAction=$NextAction
        if($State -eq 'awaiting-acceptance'){$task.acceptance.state='unverified'}
        $eventNote=if($LinkType){"$Note; $LinkType=$LinkId"}else{$Note}
    }
    'complete'{if([string]::IsNullOrWhiteSpace($Note)){throw 'Completion summary is required.'};$task.state='awaiting-acceptance';$task.currentStep=$Note.Trim();$task.nextAction='Await user acceptance';$task.acceptance.state='unverified'}
    'accept'{
        if([string]::IsNullOrWhiteSpace($AcceptanceState)-or[string]::IsNullOrWhiteSpace($Note)){throw 'AcceptanceState and Note are required.'}
        $task.acceptance.state=$AcceptanceState;$task.acceptance.note=$Note.Trim();$task.acceptance.at=(Get-Date).ToString('o')
        if($AcceptanceState -eq 'verified'){$task.state='completed';$task.nextAction=$null}else{$task.state='active';$task.nextAction='Revise from acceptance feedback'}
    }
}
$task.updatedAt=(Get-Date).ToString('o');Save-Versioned $dir $task;Append-Event $dir $Action $task.state $eventNote
Write-Summary $task
