$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('review-acceptance-test-'+[guid]::NewGuid().ToString('N'))
$id='r-1234abcd'
$dir=Join-Path $root $id
New-Item -ItemType Directory -Path $dir -Force|Out-Null
$state=[ordered]@{
    schemaVersion=1;id=$id;title='Acceptance test';revision=1;state='awaiting-feedback'
    createdAt=(Get-Date).ToString('o');updatedAt=(Get-Date).ToString('o')
    draftPath=(Join-Path $dir 'v001.md');draftHash='test';feedback=@();changes=@()
}
[IO.File]::WriteAllText((Join-Path $dir 'review.json'),($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
try{
    $script=Join-Path $PSScriptRoot 'review-round.ps1'
    $accepted=& $script -Action accept -ReviewId $id -BaseRevision 1 -AcceptanceNote 'User approved revision 1.' -ReviewRoot $root|ConvertFrom-Json
    if($accepted.state -ne 'accepted'){throw 'accept transition failed'}
    $saved=& $script -Action status -ReviewId $id -ReviewRoot $root|ConvertFrom-Json
    if($saved.state -ne 'accepted' -or [string]::IsNullOrWhiteSpace($saved.acceptedAt)){throw 'acceptance persistence failed'}
    $rejected=$false
    try{& $script -Action feedback -ReviewId $id -BaseRevision 1 -Feedback 'late feedback' -ReviewRoot $root|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'accepted review allowed new feedback'}
    [pscustomobject]@{ok=$true;tests=3;reviewId=$id}|ConvertTo-Json -Compress
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
