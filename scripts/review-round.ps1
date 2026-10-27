[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start','feedback','revise','accept','status')]
    [string]$Action,
    [string]$ReviewId,
    [string]$SourcePath,
    [string]$Title,
    [string]$Feedback,
    [string]$ChangeSummary,
    [string]$AcceptanceNote,
    [int]$BaseRevision = 0,
    [string]$FeedbackId,
    [string]$ReviewRoot
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($ReviewRoot)){$ReviewRoot=Join-Path $workspace 'reviews'}
$reviewRoot = $ReviewRoot
$utf8 = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'path-safety.ps1')

function Get-ReviewSource([string]$Path) {
    $file = Assert-UnlinkedFilePath -LiteralPath $Path -Purpose 'review source'
    if ($file.Extension.ToLowerInvariant() -notin @('.md','.txt')) { throw 'This prototype accepts only Markdown and TXT drafts.' }
    if ($file.Length -gt 100KB) { throw 'Review draft exceeds 100 KiB.' }
    if ($file.FullName -match '(?i)\\(\.openclaw|\.codex|AppData|Windows|Program Files|ProgramData)(\\|$)' -or
        $file.Name -match '(?i)(auth|token|cookie|credential|secret|password|passwd|\.env)') {
        throw 'Sensitive source paths are not allowed.'
    }
    # Inspection is only a first gate; the assistant must still review addresses,
    # account details and contextual privacy before actually sending any draft.
    $inspection = (& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $file.FullName)|ConvertFrom-Json
    if (@($inspection.sensitive_patterns_detected).Count -gt 0) { throw 'Sensitive draft requires explicit handling; no review packet prepared.' }
    return $file
}

function Save-State([string]$Directory,[object]$State) {
    $path = Join-Path $Directory 'review.json'
    if(Test-Path -LiteralPath $path) {
        $history=Join-Path $Directory 'state-history'
        New-Item -ItemType Directory -Path $history -Force|Out-Null
        Copy-Item -LiteralPath $path -Destination (Join-Path $history ([guid]::NewGuid().ToString('N')+'.json'))
    }
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($State|ConvertTo-Json -Depth 8),$utf8)
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Copy-Revision([IO.FileInfo]$File,[string]$Directory,[int]$Revision) {
    $destination=Join-Path $Directory ('v'+$Revision.ToString('D3')+$File.Extension.ToLowerInvariant())
    if(Test-Path -LiteralPath $destination){throw 'Revision already exists; refusing overwrite.'}
    $before=(Get-FileHash -LiteralPath $File.FullName).Hash
    Copy-Item -LiteralPath $File.FullName -Destination $destination
    $after=(Get-FileHash -LiteralPath $File.FullName).Hash
    $copied=(Get-FileHash -LiteralPath $destination).Hash
    if($before -ne $after -or $before -ne $copied){throw 'Source changed during review copy; revision not committed.'}
    return [pscustomobject]@{path=$destination;hash=$copied}
}

function Prepare-ReviewPacket([string]$Directory,[object]$State,[string]$DraftPath,[string]$Summary) {
    $text=Get-Content -LiteralPath $DraftPath -Raw -Encoding UTF8
    $blocks=@([regex]::Split($text.Trim(),'\r?\n\s*\r?\n')|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('# '+$State.title+' · 第'+$State.revision+'版')
    $lines.Add('')
    $lines.Add('你可以直接回复：“第2段更口语一点”“缩短到一分钟能读完”“保留上一版”。助手会记录你看到的版本再修改。')
    $lines.Add('')
    $lines.Add('## 稿件')
    for($i=0;$i -lt $blocks.Count;$i++){
        $lines.Add('')
        $lines.Add('### 第'+($i+1)+'段')
        $lines.Add('')
        $lines.Add($blocks[$i])
    }
    if(-not [string]::IsNullOrWhiteSpace($Summary)){
        $lines.Add('')
        $lines.Add('## 这次修改了什么')
        $lines.Add('')
        $lines.Add($Summary)
    }
    $packet=Join-Path $Directory ('评审卡-v'+$State.revision.ToString('D3')+'.md')
    if(Test-Path -LiteralPath $packet){throw 'Review packet already exists.'}
    [IO.File]::WriteAllText($packet,($lines -join [Environment]::NewLine),$utf8)
    $inspection=(& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $packet)|ConvertFrom-Json
    if(@($inspection.sensitive_patterns_detected).Count -gt 0){throw 'Review packet contains sensitive patterns; no outbound copy prepared.'}
    return ((& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $packet)|ConvertFrom-Json)
}

if($Action -eq 'start'){
    if([string]::IsNullOrWhiteSpace($Title)){throw 'Review title is required.'}
    $file=Get-ReviewSource $SourcePath
    $id='r-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $directory=Join-Path $reviewRoot $id
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $copy=Copy-Revision $file $directory 1
    $state=[ordered]@{
        schemaVersion=1;id=$id;title=$Title;revision=1;state='awaiting-feedback'
        createdAt=(Get-Date).ToString('o');updatedAt=(Get-Date).ToString('o')
        draftPath=$copy.path;draftHash=$copy.hash;feedback=@();changes=@()
    }
    $packet=Prepare-ReviewPacket $directory $state $copy.path ''
    Save-State $directory $state
    [ordered]@{status='prepared';reviewId=$id;revision=1;state=$state.state;outboundPath=$packet.outboundPath;integrityVerified=$packet.integrityVerified}|ConvertTo-Json
    return
}

if($ReviewId -notmatch '^r-[a-f0-9]{8}$'){throw 'A valid review id is required.'}
$directory=Join-Path $reviewRoot $ReviewId
$state=Get-Content -LiteralPath (Join-Path $directory 'review.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($Action -eq 'status'){
    [ordered]@{
        status='ok';reviewId=$state.id;title=$state.title;revision=$state.revision;state=$state.state
        pendingFeedbackCount=@($state.feedback|Where-Object {$_.state -eq 'pending'}).Count
        feedback=@($state.feedback|Select-Object id,baseRevision,state)
        lastChange=if(@($state.changes).Count -gt 0){$state.changes[-1].summary}else{$null}
        acceptedAt=$state.acceptedAt
        acceptanceNote=$state.acceptanceNote
    }|ConvertTo-Json -Depth 6
    return
}

if($BaseRevision -ne $state.revision){throw 'The displayed revision is stale; ask which version the user wants changed before editing.'}
if($Action -eq 'accept'){
    if($state.state -ne 'awaiting-feedback'){throw 'Only the currently displayed revision can be accepted.'}
    if([string]::IsNullOrWhiteSpace($AcceptanceNote) -or $AcceptanceNote.Length -gt 1000){throw 'AcceptanceNote must contain 1 to 1000 characters.'}
    $state.state='accepted'
    $acceptedAt=(Get-Date).ToString('o')
    $state|Add-Member -NotePropertyName acceptedAt -NotePropertyValue $acceptedAt -Force
    $state|Add-Member -NotePropertyName acceptanceNote -NotePropertyValue $AcceptanceNote.Trim() -Force
    $state.updatedAt=$state.acceptedAt
    Save-State $directory $state
    [ordered]@{status='accepted';reviewId=$ReviewId;revision=$state.revision;state=$state.state;acceptedAt=$state.acceptedAt}|ConvertTo-Json
    return
}
if($Action -eq 'feedback'){
    if($state.state -ne 'awaiting-feedback'){throw 'This review is not awaiting feedback.'}
    if([string]::IsNullOrWhiteSpace($Feedback) -or $Feedback.Length -gt 4000){throw 'Feedback must contain 1 to 4000 characters.'}
    if($state.state -eq 'awaiting-revision'){throw 'A feedback item is already pending; finish or clarify that revision before starting another.'}
    $feedbackRecord=[pscustomobject]@{
        id='f-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        baseRevision=$BaseRevision;text=$Feedback;state='pending';createdAt=(Get-Date).ToString('o')
    }
    $state.feedback=@($state.feedback)+@($feedbackRecord)
    $state.state='awaiting-revision'
    $state.updatedAt=(Get-Date).ToString('o')
    Save-State $directory $state
    [ordered]@{status='recorded';reviewId=$ReviewId;baseRevision=$BaseRevision;feedbackId=$feedbackRecord.id;state=$state.state}|ConvertTo-Json
    return
}

if([string]::IsNullOrWhiteSpace($ChangeSummary) -or $ChangeSummary.Length -gt 4000){throw 'A concrete change summary is required.'}
$pending=@($state.feedback|Where-Object {$_.id -eq $FeedbackId -and $_.state -eq 'pending' -and $_.baseRevision -eq $BaseRevision})
if($pending.Count -ne 1){throw 'Exactly one pending feedback item must be matched.'}
if((Get-FileHash -LiteralPath $state.draftPath).Hash -ne $state.draftHash){throw 'The reviewed draft changed externally; revision requires manual reconciliation.'}
$file=Get-ReviewSource $SourcePath
if((Get-FileHash -LiteralPath $file.FullName).Hash -eq $state.draftHash){throw 'New draft is unchanged; refusing to report the feedback as implemented.'}
$newRevision=[int]$state.revision+1
$copy=Copy-Revision $file $directory $newRevision
$state.revision=$newRevision
$state.draftPath=$copy.path
$state.draftHash=$copy.hash
$state.state='awaiting-feedback'
$state.updatedAt=(Get-Date).ToString('o')
$pending[0].state='implemented'
$state.changes=@($state.changes)+@([pscustomobject]@{revision=$newRevision;feedbackId=$FeedbackId;summary=$ChangeSummary;at=(Get-Date).ToString('o')})
$packet=Prepare-ReviewPacket $directory $state $copy.path $ChangeSummary
Save-State $directory $state
[ordered]@{status='revised';reviewId=$ReviewId;revision=$newRevision;state=$state.state;outboundPath=$packet.outboundPath;previousVersionPreserved=$true;integrityVerified=$packet.integrityVerified}|ConvertTo-Json
