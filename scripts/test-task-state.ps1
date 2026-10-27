$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('task-state-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$artifact=Join-Path $root 'result.txt';[IO.File]::WriteAllText($artifact,'verified result',[Text.UTF8Encoding]::new($false))
try{
    $script=Join-Path $PSScriptRoot 'task-state.ps1'
    $started=& $script -Action start -Title 'Test' -Goal 'Exercise lifecycle' -Mode relay -RequestId 'same-request' -TaskRoot $root|ConvertFrom-Json
    if($started.state -ne 'active'){throw 'start failed'}
    $duplicate=& $script -Action start -Title 'Other' -Goal 'Must dedupe' -Mode field -RequestId 'same-request' -TaskRoot $root|ConvertFrom-Json
    if($duplicate.taskId -ne $started.taskId){throw 'dedupe failed'}
    $synced=& $script -Action sync -TaskId $started.taskId -State awaiting-user -Note 'Review sent' -NextAction 'Wait for reply' -LinkType review -LinkId r-test0001 -TaskRoot $root|ConvertFrom-Json
    if($synced.state -ne 'awaiting-user' -or $synced.links.review -ne 'r-test0001' -or $synced.nextAction -ne 'Wait for reply'){throw 'atomic flow sync failed'}
    $reactivated=& $script -Action sync -TaskId $started.taskId -State active -Note 'Reply received' -NextAction 'Continue work' -TaskRoot $root|ConvertFrom-Json
    if($reactivated.state -ne 'active' -or $reactivated.currentStep -ne 'Reply received'){throw 'atomic resume sync failed'}
    & $script -Action link -TaskId $started.taskId -LinkType mission -LinkId m-1 -TaskRoot $root|Out-Null
    & $script -Action artifact -TaskId $started.taskId -ArtifactPath $artifact -ArtifactKind report -TaskRoot $root|Out-Null
    $waiting=& $script -Action await-user -TaskId $started.taskId -Note 'Draft sent' -NextAction 'Reply with feedback' -TaskRoot $root|ConvertFrom-Json
    if($waiting.state -ne 'awaiting-user'){throw 'await-user failed'}
    & $script -Action checkpoint -TaskId $started.taskId -Note 'Feedback received' -NextAction 'Revise' -TaskRoot $root|Out-Null
    $ready=& $script -Action complete -TaskId $started.taskId -Note 'Revision delivered' -TaskRoot $root|ConvertFrom-Json
    if($ready.state -ne 'awaiting-acceptance'){throw 'completion truth failed'}
    $done=& $script -Action accept -TaskId $started.taskId -AcceptanceState verified -Note 'User accepted' -TaskRoot $root|ConvertFrom-Json
    if($done.state -ne 'completed' -or $done.acceptance.state -ne 'verified'){throw 'acceptance failed'}
    $saved=Get-Content -LiteralPath (Join-Path (Join-Path $root $started.taskId) 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if(@($saved.artifacts).Count -ne 1 -or -not $saved.artifacts[0].sha256){throw 'artifact failed'}
    [pscustomobject]@{ok=$true;tests=10;taskId=$started.taskId}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
