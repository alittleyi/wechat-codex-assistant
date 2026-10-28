[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('dispatch-bridge-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
try{
    $registry=Join-Path $root 'registry.json';$store=Join-Path $root 'dispatch.json'
    & (Join-Path $PSScriptRoot 'task-chat-registry.ps1') -Action register -TaskKey 'bridge-test' -Title 'Bridge test' -Goal 'Deliver safely' -IntentSummary 'Keep whole intent' -CanonicalChatTitle 'Canonical' -CanonicalSessionRef 'test-session' -RegistryPath $registry|Out-Null
    foreach($failure in @('busy','write-lock','network-failure','resume-failure')){
        $blocked=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState $failure -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
        if($blocked.status-ne'blocked'-or$blocked.allowCreateVisibleChat-or$blocked.allowCurrentSessionExecution-or$blocked.allowDownstream){throw "route failure was not fail-closed: $failure"}
    }
    $temporary=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState ready -RuntimeContext temporary-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($temporary.status-ne'blocked'-or$temporary.reason-ne'execution-context-is-not-canonical-chat'){throw 'temporary chat was allowed to execute'}
    $mismatch=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef wrong-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($mismatch.status-ne'blocked'-or$mismatch.reason-ne'canonical-session-mismatch'){throw 'wrong canonical session was allowed'}
    if(Test-Path -LiteralPath $store){throw 'blocked route created a downstream dispatch store'}
    $created=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($created.state-ne'pending'){throw 'prepare failed'}
    $duplicate=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if(-not$duplicate.reused-or$duplicate.dispatchId-ne$created.dispatchId){throw 'idempotent prepare failed'}
    $blockedClaim=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action claim -DispatchId $created.dispatchId -Worker worker-a -LeaseSeconds 30 -CanonicalRouteState write-lock -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($blockedClaim.status-ne'blocked'-or$blockedClaim.allowDownstream){throw 'locked canonical route allowed claim'}
    $claimed=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action claim -DispatchId $created.dispatchId -Worker worker-a -LeaseSeconds 30 -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($claimed.state-ne'claimed'-or$claimed.attempt-ne1-or$claimed.packet.protocol-ne'whole-intent-first-v2'-or$claimed.claimToken-notmatch'^[a-f0-9]{64}$'){throw 'claim failed'}
    $wrongWorkerBlocked=$false;try{& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action complete -DispatchId $created.dispatchId -Worker worker-b -ClaimToken $claimed.claimToken -ResultSummary done -RegistryPath $registry -StorePath $store|Out-Null}catch{$wrongWorkerBlocked=$true}
    if(-not$wrongWorkerBlocked){throw 'ownership guard failed'}

    # Expire the lease, let the same worker reclaim, then prove the previous
    # fencing token cannot finish the newer claim.
    $value=Get-Content -LiteralPath $store -Raw -Encoding UTF8|ConvertFrom-Json
    $value.dispatches[0].leaseExpiresAt=(Get-Date).ToUniversalTime().AddSeconds(-1).ToString('o')
    [IO.File]::WriteAllText($store,($value|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
    $reclaimed=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action claim -DispatchId $created.dispatchId -Worker worker-a -LeaseSeconds 30 -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($reclaimed.attempt-ne2-or$reclaimed.claimToken-eq$claimed.claimToken){throw 'reclaim fencing failed'}
    $staleTokenBlocked=$false;try{& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action complete -DispatchId $created.dispatchId -Worker worker-a -ClaimToken $claimed.claimToken -ResultSummary stale -RegistryPath $registry -StorePath $store|Out-Null}catch{$staleTokenBlocked=$true}
    if(-not$staleTokenBlocked){throw 'stale claim token accepted'}
    $completed=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action complete -DispatchId $created.dispatchId -Worker worker-a -ClaimToken $reclaimed.claimToken -ResultSummary 'verified result' -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($completed.state-ne'completed'){throw 'complete failed'}

    $terminalRetry=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if(-not$terminalRetry.reused-or$terminalRetry.dispatchId-ne$created.dispatchId-or$terminalRetry.state-ne'completed'){throw 'terminal idempotency failed'}
    $rerun=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action prepare -TaskKey bridge-test -RerunKey retry-1 -CanonicalRouteState ready -RuntimeContext canonical-chat -ResolvedSessionRef test-session -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($rerun.dispatchId-eq$created.dispatchId-or$rerun.state-ne'pending'){throw 'explicit rerun failed'}

    $health=& (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action health -RegistryPath $registry -StorePath $store|ConvertFrom-Json
    if($health.status-ne'passed'-or$health.checks.store.records-ne2-or$health.checks.runtimes.node.PSObject.Properties.Name-contains'path'){throw 'health validation or redaction failed'}
    $corrupt=Join-Path $root 'corrupt.json';$bad=Get-Content -LiteralPath $store -Raw -Encoding UTF8|ConvertFrom-Json
    $bad.dispatches[1].state='claimed';$bad.dispatches[1].worker='worker-z';$bad.dispatches[1].attempt=1;$bad.dispatches[1].claimTokenHash=('a'*64);$bad.dispatches[1].leaseExpiresAt=$null
    [IO.File]::WriteAllText($corrupt,($bad|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
    $powershell=(Get-Command powershell.exe).Source
    $badOutput=& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action health -RegistryPath $registry -StorePath $corrupt
    $badExit=$LASTEXITCODE;$badHealth=$badOutput|ConvertFrom-Json
    if($badExit-ne1-or$badHealth.status-ne'failed'-or$badHealth.checks.store.ok){throw 'corrupt store health path failed'}
    $tampered=Join-Path $root 'tampered.json';$changed=Get-Content -LiteralPath $store -Raw -Encoding UTF8|ConvertFrom-Json
    $changed.dispatches[0].packet.goal='Tampered goal while retaining the old hash'
    [IO.File]::WriteAllText($tampered,($changed|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
    $tamperedOutput=& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'dispatch-bridge.ps1') -Action health -RegistryPath $registry -StorePath $tampered
    $tamperedExit=$LASTEXITCODE;$tamperedHealth=$tamperedOutput|ConvertFrom-Json
    if($tamperedExit-ne1-or$tamperedHealth.status-ne'failed'-or$tamperedHealth.checks.store.ok){throw 'packet hash tampering was not detected'}
    $raw=Get-Content -LiteralPath $store -Raw -Encoding UTF8
    if($raw-notmatch 'whole-intent-first-v2'-or$raw-notmatch 'canonical-only'-or$raw-notmatch 'Keep whole intent'){throw 'handoff packet missing'}
    if(Get-ChildItem -LiteralPath $root -Filter '*.lock' -Recurse){throw 'persistent lock created'}
    [ordered]@{ok=$true;tests=24;dispatchIdPattern=($created.dispatchId-match'^d-[a-f0-9]{16}$');persistentLocks=0;blockedRoutes=6;blockedClaims=1}|ConvertTo-Json
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
