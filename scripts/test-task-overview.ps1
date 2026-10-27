$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('task-overview-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
try{
    $stateScript=Join-Path $PSScriptRoot 'task-state.ps1'
    $overviewScript=Join-Path $PSScriptRoot 'task-overview.ps1'
    $first=& $stateScript -Action start -Title 'Visible task' -Goal 'Test overview' -Mode relay -NextAction 'Wait' -TaskRoot $root|ConvertFrom-Json
    & $stateScript -Action sync -TaskId $first.taskId -State awaiting-user -Note 'Draft ready' -NextAction 'Reply with feedback' -TaskRoot $root|Out-Null
    $second=& $stateScript -Action start -Title 'Completed task' -Goal 'Test filtering' -Mode field -TaskRoot $root|ConvertFrom-Json
    & $stateScript -Action complete -TaskId $second.taskId -Note 'Delivered' -TaskRoot $root|Out-Null
    & $stateScript -Action accept -TaskId $second.taskId -AcceptanceState verified -Note 'Accepted' -TaskRoot $root|Out-Null
    $broken=Join-Path $root 't-broken0000';New-Item -ItemType Directory -Path $broken|Out-Null
    [IO.File]::WriteAllText((Join-Path $broken 'task.json'),'{broken',[Text.UTF8Encoding]::new($false))
    $overview=& $overviewScript -TaskRoot $root|ConvertFrom-Json
    if($overview.taskCount-ne1-or$overview.unreadableCount-ne1){throw 'filter or corruption accounting failed'}
    if($overview.tasks[0].state-ne'waiting-for-user'-or$overview.tasks[0].nextAction-ne'Reply with feedback'){throw 'mobile summary failed'}
    $raw=& $overviewScript -TaskRoot $root
    if($raw-match't-[a-f0-9]{10}'-or$raw-match[regex]::Escape($root)){throw 'internal identifier or path leaked'}
    [pscustomobject]@{ok=$true;tests=3}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
