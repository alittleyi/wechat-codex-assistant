[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('register','bind','update','handoff','status','list','archive')]
    [string]$Action,
    [string]$TaskKey,
    [string]$Title,
    [string]$Goal,
    [string]$IntentSummary,
    [string[]]$QualityBars,
    [string[]]$RejectedDirections,
    [string[]]$AcceptanceCriteria,
    [string]$CanonicalChatTitle,
    [string]$CanonicalSessionRef,
    [string]$ChangeSummary,
    [string]$Subtask,
    [ValidateSet('active','awaiting-user','paused','awaiting-acceptance','completed','archived')]
    [string]$State,
    [string]$CurrentStep,
    [string]$NextAction,
    [string]$RegistryPath
)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($RegistryPath)){$RegistryPath=Join-Path $workspace 'task-chat-registry.json'}
$utf8=[Text.UTF8Encoding]::new($false)

function Save-Atomic([string]$Path,[object]$Value){
    $dir=Split-Path -Parent $Path
    if($dir){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 12),$utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function New-Registry(){[ordered]@{schemaVersion=1;updatedAt=(Get-Date).ToString('o');tasks=@()}}
function Read-Registry(){
    if(-not(Test-Path -LiteralPath $RegistryPath -PathType Leaf)){return New-Registry}
    $value=Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$value.schemaVersion-ne1){throw 'Unsupported registry schema.'}
    if($null-eq$value.tasks){$value|Add-Member -NotePropertyName tasks -NotePropertyValue @()}
    return $value
}
function Require-Key(){if([string]::IsNullOrWhiteSpace($TaskKey)-or$TaskKey-notmatch '^[a-z0-9][a-z0-9-]{1,62}$'){throw 'TaskKey must be a 2-63 character lowercase slug.'}}
function Find-Task([object]$Registry){Require-Key;$matches=@($Registry.tasks|Where-Object{$_.taskKey-eq$TaskKey});if($matches.Count-ne1){throw 'Task was not found or is ambiguous.'};return $matches[0]}
function Hash-Text([string]$Value){
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.Trim())))-replace'-','').ToLowerInvariant()}
    finally{$hasher.Dispose()}
}
function Text([string]$Value,[int]$Max){if([string]::IsNullOrWhiteSpace($Value)){return $null};$clean=($Value-replace '\s+',' ').Trim();if($clean.Length-gt$Max){throw "Text exceeds $Max characters."};return $clean}
function Texts([string[]]$Values,[int]$MaxItems=20,[int]$MaxLength=500){$items=@($Values|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|ForEach-Object{Text $_ $MaxLength});if($items.Count-gt$MaxItems){throw "Too many list items; maximum is $MaxItems."};return $items}
function Safe-Status([object]$Task){
    [ordered]@{status='ok';taskKey=$Task.taskKey;title=$Task.title;state=$Task.state;canonicalChatTitle=$Task.canonicalChatTitle;hasCanonicalBinding=(-not[string]::IsNullOrWhiteSpace([string]$Task.canonicalSessionRef));goal=$Task.goal;currentStep=$Task.currentStep;nextAction=$Task.nextAction;updatedAt=$Task.updatedAt}
}
function Save-Registry([object]$Registry){$Registry.updatedAt=(Get-Date).ToString('o');Save-Atomic $RegistryPath $Registry}

$registry=Read-Registry
if($Action-eq'register'){
    Require-Key
    if(@($registry.tasks|Where-Object{$_.taskKey-eq$TaskKey}).Count-ne0){throw 'TaskKey already exists.'}
    if([string]::IsNullOrWhiteSpace($Title)-or[string]::IsNullOrWhiteSpace($Goal)-or[string]::IsNullOrWhiteSpace($IntentSummary)){throw 'Title, Goal and IntentSummary are required.'}
    if([string]::IsNullOrWhiteSpace($CanonicalChatTitle)-xor[string]::IsNullOrWhiteSpace($CanonicalSessionRef)){throw 'CanonicalChatTitle and CanonicalSessionRef must be supplied together.'}
    $now=(Get-Date).ToString('o')
    $task=[ordered]@{taskKey=$TaskKey;title=(Text $Title 120);goal=(Text $Goal 2000);intentSummary=(Text $IntentSummary 4000);qualityBars=(Texts $QualityBars);rejectedDirections=(Texts $RejectedDirections);acceptanceCriteria=(Texts $AcceptanceCriteria);canonicalChatTitle=(Text $CanonicalChatTitle 160);canonicalSessionRef=(Text $CanonicalSessionRef 500);state=if($State){$State}else{'active'};currentStep=(Text $CurrentStep 500);nextAction=(Text $NextAction 500);createdAt=$now;updatedAt=$now;changes=@()}
    $registry.tasks=@($registry.tasks)+@($task);Save-Registry $registry
    Safe-Status $task|ConvertTo-Json -Depth 6;return
}
if($Action-eq'list'){$rows=@($registry.tasks|Where-Object{$_.state-ne'archived'}|Sort-Object updatedAt -Descending|ForEach-Object{Safe-Status $_});[ordered]@{status='ok';count=$rows.Count;tasks=$rows}|ConvertTo-Json -Depth 6;return}

$task=Find-Task $registry
if($Action-eq'status'){Safe-Status $task|ConvertTo-Json -Depth 6;return}
if($Action-eq'bind'){
    if([string]::IsNullOrWhiteSpace($CanonicalChatTitle)-or[string]::IsNullOrWhiteSpace($CanonicalSessionRef)){throw 'CanonicalChatTitle and CanonicalSessionRef are required.'}
    if(-not[string]::IsNullOrWhiteSpace([string]$task.canonicalSessionRef)-and[string]$task.canonicalSessionRef-ne$CanonicalSessionRef){throw 'Canonical chat is already bound; refusing to replace it with another session.'}
    $task.canonicalChatTitle=Text $CanonicalChatTitle 160;$task.canonicalSessionRef=Text $CanonicalSessionRef 500
}elseif($Action-eq'update'){
    if(-not$ChangeSummary){throw 'ChangeSummary is required so later handoffs preserve why the task changed.'}
    $before=[ordered]@{at=(Get-Date).ToString('o');summary=(Text $ChangeSummary 1000);previousIntent=$task.intentSummary}
    $task.changes=@($task.changes)+@($before)
    if($Goal){$task.goal=Text $Goal 2000};if($IntentSummary){$task.intentSummary=Text $IntentSummary 4000}
    if($null-ne$QualityBars){$task.qualityBars=Texts $QualityBars};if($null-ne$RejectedDirections){$task.rejectedDirections=Texts $RejectedDirections}
    if($null-ne$AcceptanceCriteria){$task.acceptanceCriteria=Texts $AcceptanceCriteria};if($State){$task.state=$State}
    if($CurrentStep){$task.currentStep=Text $CurrentStep 500};if($NextAction){$task.nextAction=Text $NextAction 500}
}elseif($Action-eq'archive'){$task.state='archived';$task.nextAction=$null
}elseif($Action-eq'handoff'){
    $packet=[ordered]@{protocol='whole-intent-first-v2';taskKey=$task.taskKey;canonicalChatTitle=$task.canonicalChatTitle;routingPolicy=[ordered]@{mode='canonical-only';canonicalBindingHash=(Hash-Text ([string]$task.canonicalSessionRef));allowVisibleChatCreation=$false;allowCoordinatorExecution=$false;failureDisposition='wait-and-report'};instruction='Preserve the complete intent before applying the latest change or bounded subtask. A local request must not replace established quality bars.';goal=$task.goal;intentSummary=$task.intentSummary;qualityBars=@($task.qualityBars);rejectedDirections=@($task.rejectedDirections);acceptanceCriteria=@($task.acceptanceCriteria);latestChange=if(@($task.changes).Count){$task.changes[-1].summary}else{$null};currentStep=$task.currentStep;nextAction=$task.nextAction;requestedSubtask=(Text $Subtask 2000);returnContract=@('Report completed work','List evidence or artifacts','Report unfinished work and risks','Merge results into the canonical chat; do not create a visible chat')}
    [ordered]@{status='ok';packet=$packet}|ConvertTo-Json -Depth 10;return
}
$task.updatedAt=(Get-Date).ToString('o');Save-Registry $registry
Safe-Status $task|ConvertTo-Json -Depth 6
