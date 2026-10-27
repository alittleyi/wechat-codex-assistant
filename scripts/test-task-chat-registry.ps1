$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('task-chat-registry-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$registry=Join-Path $root 'registry.json'
try{
    $script=Join-Path $PSScriptRoot 'task-chat-registry.ps1'
    $created=& $script -Action register -TaskKey 'xiaohongshu-content' -Title 'XHS content' -Goal 'Rebuild practical series' -IntentSummary 'Synthesize real cross-platform experience to solve concrete problems.' -QualityBars @('curated','one concrete problem per article') -RejectedDirections @('filler','empty prose') -AcceptanceCriteria @('actionable steps','complete content') -CanonicalChatTitle 'Xiaohongshu' -CanonicalSessionRef 'local-session-ref' -RegistryPath $registry|ConvertFrom-Json
    if(-not$created.hasCanonicalBinding-or$created.state-ne'active'){throw 'register failed'}
    $updated=& $script -Action update -TaskKey 'xiaohongshu-content' -ChangeSummary 'User requires cross-platform sourcing' -IntentSummary 'Curate a small set of practical cross-platform material.' -CurrentStep 'Rebuild series two' -NextAction 'Complete article one' -RegistryPath $registry|ConvertFrom-Json
    if($updated.currentStep-ne'Rebuild series two'){throw 'update failed'}
    $handoff=& $script -Action handoff -TaskKey 'xiaohongshu-content' -Subtask 'Research session reconnection only' -RegistryPath $registry|ConvertFrom-Json
    if($handoff.packet.protocol-ne'whole-intent-first-v1'-or$handoff.packet.qualityBars.Count-ne2-or$handoff.packet.latestChange-ne'User requires cross-platform sourcing'){throw 'handoff failed'}
    if($handoff.packet.requestedSubtask-ne'Research session reconnection only'-or$handoff.packet.returnContract.Count-ne4){throw 'bounded subtask failed'}
    $safe=& $script -Action status -TaskKey 'xiaohongshu-content' -RegistryPath $registry|ConvertFrom-Json
    if($safe.PSObject.Properties.Name-contains'canonicalSessionRef'){throw 'status leaked internal session reference'}
    $archived=& $script -Action archive -TaskKey 'xiaohongshu-content' -RegistryPath $registry|ConvertFrom-Json
    if($archived.state-ne'archived'){throw 'archive failed'}
    [pscustomobject]@{ok=$true;tests=6}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
