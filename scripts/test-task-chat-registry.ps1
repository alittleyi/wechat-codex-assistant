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
    if($handoff.packet.protocol-ne'whole-intent-first-v2'-or$handoff.packet.qualityBars.Count-ne2-or$handoff.packet.latestChange-ne'User requires cross-platform sourcing'){throw 'handoff failed'}
    if($handoff.packet.requestedSubtask-ne'Research session reconnection only'-or$handoff.packet.returnContract.Count-ne4){throw 'bounded subtask failed'}
    if($handoff.packet.routingPolicy.mode-ne'canonical-only'-or$handoff.packet.routingPolicy.canonicalBindingHash-notmatch'^[a-f0-9]{64}$'-or$handoff.packet.routingPolicy.allowVisibleChatCreation-or$handoff.packet.routingPolicy.allowCoordinatorExecution){throw 'canonical-only routing policy missing'}
    if(($handoff|ConvertTo-Json -Depth 12)-match'local-session-ref'){throw 'handoff leaked raw canonical session reference'}
    $sameBind=& $script -Action bind -TaskKey 'xiaohongshu-content' -CanonicalChatTitle 'Xiaohongshu' -CanonicalSessionRef 'local-session-ref' -RegistryPath $registry|ConvertFrom-Json
    if(-not$sameBind.hasCanonicalBinding){throw 'idempotent bind failed'}
    $rebindBlocked=$false;try{& $script -Action bind -TaskKey 'xiaohongshu-content' -CanonicalChatTitle 'Temporary WeChat' -CanonicalSessionRef 'temporary-session-ref' -RegistryPath $registry|Out-Null}catch{$rebindBlocked=$true}
    if(-not$rebindBlocked){throw 'canonical binding replacement was allowed'}
    $safe=& $script -Action status -TaskKey 'xiaohongshu-content' -RegistryPath $registry|ConvertFrom-Json
    if($safe.PSObject.Properties.Name-contains'canonicalSessionRef'){throw 'status leaked internal session reference'}
    $archived=& $script -Action archive -TaskKey 'xiaohongshu-content' -RegistryPath $registry|ConvertFrom-Json
    if($archived.state-ne'archived'){throw 'archive failed'}
    [pscustomobject]@{ok=$true;tests=10}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
