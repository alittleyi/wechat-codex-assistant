[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('prepare','claim','complete','fail','status','health')]
    [string]$Action,
    [string]$TaskKey,
    [string]$DispatchId,
    [string]$Worker,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$ClaimToken,
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,79}$')][string]$RerunKey,
    [ValidateSet('ready','busy','write-lock','network-failure','resume-failure','unknown')]
    [string]$CanonicalRouteState='unknown',
    [ValidateSet('canonical-chat','wechat-coordinator','temporary-chat','unknown')]
    [string]$RuntimeContext='unknown',
    [string]$ResolvedSessionRef,
    [string]$ResultSummary,
    [ValidateRange(30,3600)][int]$LeaseSeconds=300,
    [ValidateRange(1,30000)][int]$LockTimeoutMs=5000,
    [string]$RegistryPath,
    [string]$StorePath
)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($RegistryPath)){$RegistryPath=Join-Path $workspace 'task-chat-registry.json'}
if([string]::IsNullOrWhiteSpace($StorePath)){$StorePath=Join-Path $workspace '.runtime\dispatch-bridge.json'}
$utf8=[Text.UTF8Encoding]::new($false)

function Clean([string]$Value,[int]$Max){
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $text=($Value-replace '\s+',' ').Trim()
    if($text.Length-gt$Max){throw "Text exceeds $Max characters."}
    if($text-match '(?i)(token|cookie|api[_-]?key|password|secret)\s*[:=]'){throw 'Potential credential material rejected.'}
    return $text
}
function Read-JsonBounded([string]$Path,[int64]$Limit){
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($item.Length-gt$Limit){throw 'JSON record exceeds size bound.'}
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
}
function New-Store(){[ordered]@{schemaVersion=1;updatedAt=(Get-Date).ToUniversalTime().ToString('o');dispatches=@()}}
function Read-Store(){
    if(-not(Test-Path -LiteralPath $StorePath -PathType Leaf)){return New-Store}
    $store=Read-JsonBounded $StorePath 1048576
    if([int]$store.schemaVersion-ne1-or$null-eq$store.dispatches){throw 'Unsupported dispatch store.'}
    return $store
}
function Test-IsoTime([object]$Value){
    if($Value-isnot[string]-or[string]::IsNullOrWhiteSpace($Value)){return $false}
    $parsed=[datetimeoffset]::MinValue
    return [datetimeoffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
function Assert-StoreSemantics([object]$Store){
    if([int]$Store.schemaVersion-ne1-or$null-eq$Store.dispatches-or-not(Test-IsoTime $Store.updatedAt)){throw 'invalid-store-envelope'}
    $ids=@{}
    foreach($item in @($Store.dispatches)){
        if($item.dispatchId-notmatch'^d-[a-f0-9]{16}$'-or$ids.ContainsKey($item.dispatchId)){throw 'invalid-dispatch-id'};$ids[$item.dispatchId]=$true
        if($item.taskKey-notmatch'^[a-z0-9][a-z0-9-]{1,62}$'-or$item.state-notin@('pending','claimed','completed','failed')){throw 'invalid-dispatch-state'}
        if($item.packetHash-notmatch'^[a-f0-9]{64}$'-or$null-eq$item.packet-or$item.packet.protocol-notin@('whole-intent-first-v1','whole-intent-first-v2')){throw 'invalid-dispatch-packet'}
        if($item.packet.taskKey-ne$item.taskKey){throw 'invalid-dispatch-packet-task'}
        if($item.packet.protocol-eq'whole-intent-first-v2'){
            if($item.packet.routingPolicy.mode-ne'canonical-only'-or$item.packet.routingPolicy.canonicalBindingHash-notmatch'^[a-f0-9]{64}$'-or[bool]$item.packet.routingPolicy.allowVisibleChatCreation-or[bool]$item.packet.routingPolicy.allowCoordinatorExecution-or$item.packet.routingPolicy.failureDisposition-ne'wait-and-report'){throw 'invalid-dispatch-routing-policy'}
        }
        $actualPacketHash=Hash-Text ($item.packet|ConvertTo-Json -Depth 12 -Compress)
        if($actualPacketHash-ne$item.packetHash){throw 'invalid-dispatch-packet-hash'}
        if(-not(Test-IsoTime $item.createdAt)-or-not(Test-IsoTime $item.updatedAt)-or[datetimeoffset]::Parse($item.updatedAt)-lt[datetimeoffset]::Parse($item.createdAt)){throw 'invalid-dispatch-time'}
        if($item.attempt-isnot[int]-and$item.attempt-isnot[long]){throw 'invalid-dispatch-attempt'}
        if([int]$item.attempt-lt0){throw 'invalid-dispatch-attempt'}
        if($null-ne$item.rerunKeyHash-and$item.rerunKeyHash-notmatch'^[a-f0-9]{64}$'){throw 'invalid-rerun-key-hash'}
        if($item.state-eq'pending'){
            if([int]$item.attempt-ne0-or$null-ne$item.worker-or$null-ne$item.leaseExpiresAt-or$null-ne$item.claimTokenHash-or$null-ne$item.resultSummary){throw 'invalid-pending-dispatch'}
        }elseif($item.state-eq'claimed'){
            if([int]$item.attempt-lt1-or[string]::IsNullOrWhiteSpace([string]$item.worker)-or-not(Test-IsoTime $item.leaseExpiresAt)-or$item.claimTokenHash-notmatch'^[a-f0-9]{64}$'-or$null-ne$item.resultSummary){throw 'invalid-claimed-dispatch'}
        }else{
            if([int]$item.attempt-lt1-or$null-ne$item.leaseExpiresAt-or$null-ne$item.claimTokenHash-or[string]::IsNullOrWhiteSpace([string]$item.resultSummary)){throw 'invalid-terminal-dispatch'}
        }
    }
}
function Save-Store([object]$Store){
    $directory=Split-Path -Parent $StorePath
    if($directory){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $Store.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
    $temp="$StorePath.$([guid]::NewGuid().ToString('N')).tmp"
    try{
        [IO.File]::WriteAllText($temp,($Store|ConvertTo-Json -Depth 14),$utf8)
        Move-Item -LiteralPath $temp -Destination $StorePath -Force
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Hash-Text([string]$Text){$hasher=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))-replace'-','').ToLowerInvariant()}finally{$hasher.Dispose()}}
function Test-RouteAdmission([object]$Packet){
    $reason=$null
    if($Packet.protocol-ne'whole-intent-first-v2'-or$null-eq$Packet.routingPolicy){$reason='legacy-or-missing-routing-policy'}
    elseif($CanonicalRouteState-ne'ready'){$reason=('canonical-route-'+$CanonicalRouteState)}
    elseif($RuntimeContext-ne'canonical-chat'){$reason='execution-context-is-not-canonical-chat'}
    elseif([string]::IsNullOrWhiteSpace($ResolvedSessionRef)-or(Hash-Text ($ResolvedSessionRef.Trim()))-ne[string]$Packet.routingPolicy.canonicalBindingHash){$reason='canonical-session-mismatch'}
    if($reason){
        return [ordered]@{status='blocked';taskKey=$Packet.taskKey;state='blocked';reason=$reason;retryable=$true;allowCreateVisibleChat=$false;allowCurrentSessionExecution=$false;allowDownstream=$false}
    }
    return [ordered]@{status='ok';allowed=$true}
}
function Safe-View([object]$Item,[bool]$IncludePacket=$false,[bool]$Reused=$false,[string]$PlainClaimToken=$null){
    $view=[ordered]@{status='ok';dispatchId=$Item.dispatchId;taskKey=$Item.taskKey;state=$Item.state;worker=$Item.worker;attempt=[int]$Item.attempt;leaseExpiresAt=$Item.leaseExpiresAt;createdAt=$Item.createdAt;updatedAt=$Item.updatedAt;resultSummary=$Item.resultSummary;reused=$Reused}
    if($IncludePacket){$view.packet=$Item.packet}
    if($PlainClaimToken){$view.claimToken=$PlainClaimToken}
    return $view
}
function Find-Dispatch([object]$Store){
    if($DispatchId-notmatch '^d-[a-f0-9]{16}$'){throw 'Invalid DispatchId.'}
    $matches=@($Store.dispatches|Where-Object{$_.dispatchId-eq$DispatchId})
    if($matches.Count-ne1){throw 'Dispatch was not found or is ambiguous.'}
    return $matches[0]
}

# A named OS mutex is released by the kernel on process exit.  It cannot leave a
# lock file that an operator must inspect or delete after a crash.
$sha=[Security.Cryptography.SHA256]::Create()
try{$identity=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($StorePath)))).Substring(0,24).Replace('/','_').Replace('+','-')}finally{$sha.Dispose()}
$mutexScope='global'
try{$mutex=[Threading.Mutex]::new($false,"Global\WechatAgentDispatchBridge-$identity")}catch{$mutexScope='local-session';$mutex=[Threading.Mutex]::new($false,"Local\WechatAgentDispatchBridge-$identity")}
$owned=$false
try{
    try{$owned=$mutex.WaitOne($LockTimeoutMs)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not$owned){throw 'Dispatch bridge is busy; retry later.'}
    if($Action-eq'health'){
        $runtime=@{}
        . (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
        foreach($name in @('node','python')){try{$resolved=Resolve-AgentRuntime $name -Detailed;$runtime[$name]=[ordered]@{ok=$true;source=$resolved.source}}catch{$runtime[$name]=[ordered]@{ok=$false;diagnostic='runtime-unavailable'}}}
        $registryOk=$false;$registryDiagnostic=$null
        try{$registry=Read-JsonBounded $RegistryPath 1048576;$registryOk=([int]$registry.schemaVersion-eq1-and$null-ne$registry.tasks);if(-not$registryOk){$registryDiagnostic='invalid-registry'}}catch{$registryDiagnostic='registry-unreadable'}
        $storeOk=$true;$storeDiagnostic=$null
        try{$healthStore=Read-Store;Assert-StoreSemantics $healthStore}catch{$storeOk=$false;$storeDiagnostic=[string]$_.Exception.Message;if($storeDiagnostic-notmatch'^invalid-'){$storeDiagnostic='store-unreadable'}}
        $passed=$registryOk-and$storeOk-and$runtime.node.ok-and$runtime.python.ok
        [ordered]@{status=if($passed){'passed'}else{'failed'};checks=[ordered]@{registry=[ordered]@{ok=$registryOk;diagnostic=$registryDiagnostic};store=[ordered]@{ok=$storeOk;diagnostic=$storeDiagnostic;records=if($storeOk){@($healthStore.dispatches).Count}else{$null}};runtimes=$runtime;mutex=[ordered]@{ok=$true;scope=$mutexScope}}}|ConvertTo-Json -Depth 8
        if(-not$passed){exit 1};return
    }
    $store=Read-Store
    if($Action-eq'prepare'){
        if($TaskKey-notmatch '^[a-z0-9][a-z0-9-]{1,62}$'){throw 'Invalid TaskKey.'}
        $handoffRaw=& (Join-Path $PSScriptRoot 'task-chat-registry.ps1') -Action handoff -TaskKey $TaskKey -RegistryPath $RegistryPath
        $handoff=$handoffRaw|ConvertFrom-Json
        $route=Test-RouteAdmission $handoff.packet
        if(-not$route.allowed){$route|ConvertTo-Json -Depth 5;return}
        $packetHash=Hash-Text ($handoff.packet|ConvertTo-Json -Depth 12 -Compress);$rerunHash=if($RerunKey){Hash-Text $RerunKey}else{$null}
        $existing=@($store.dispatches|Where-Object{$_.taskKey-eq$TaskKey-and$_.packetHash-eq$packetHash-and$_.rerunKeyHash-eq$rerunHash}|Sort-Object createdAt -Descending|Select-Object -First 1)
        if($existing.Count-eq1){Safe-View $existing[0] $false $true|ConvertTo-Json -Depth 5;return}
        $now=(Get-Date).ToUniversalTime().ToString('o')
        $item=[ordered]@{dispatchId=('d-'+[guid]::NewGuid().ToString('N').Substring(0,16));taskKey=$TaskKey;state='pending';worker=$null;attempt=0;leaseExpiresAt=$null;createdAt=$now;updatedAt=$now;resultSummary=$null;claimTokenHash=$null;rerunKeyHash=$rerunHash;packetHash=$packetHash;packet=$handoff.packet}
        $store.dispatches=@($store.dispatches)+@($item);Save-Store $store;Safe-View $item|ConvertTo-Json -Depth 5;return
    }
    $item=Find-Dispatch $store;$now=Get-Date
    if($Action-eq'claim'){
        $route=Test-RouteAdmission $item.packet
        if(-not$route.allowed){$route|ConvertTo-Json -Depth 5;return}
        $workerClean=Clean $Worker 120;if(-not$workerClean){throw 'Worker is required.'}
        $expired=$item.state-eq'claimed'-and$null-ne$item.leaseExpiresAt-and$now.ToUniversalTime()-gt[datetime]::Parse($item.leaseExpiresAt).ToUniversalTime()
        if($item.state-ne'pending' -and -not $expired){throw 'Dispatch is not claimable.'}
        $plainToken=([guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N'))
        $item.state='claimed';$item.worker=$workerClean;$item.attempt=[int]$item.attempt+1;$item.leaseExpiresAt=$now.ToUniversalTime().AddSeconds($LeaseSeconds).ToString('o');$item.claimTokenHash=Hash-Text $plainToken
    }elseif($Action -in @('complete','fail')){
        if($item.state-ne'claimed'){throw 'Only a claimed dispatch can finish.'}
        if($now.ToUniversalTime()-gt[datetime]::Parse($item.leaseExpiresAt).ToUniversalTime()){throw 'Dispatch lease expired; reclaim before finishing.'}
        if((Clean $Worker 120)-ne$item.worker){throw 'Worker does not own this dispatch.'}
        if([string]::IsNullOrWhiteSpace($ClaimToken)-or(Hash-Text $ClaimToken)-ne$item.claimTokenHash){throw 'Claim token is invalid or stale.'}
        $item.state=if($Action-eq'complete'){'completed'}else{'failed'};$item.resultSummary=Clean $ResultSummary 1000;if(-not$item.resultSummary){throw 'ResultSummary is required.'};$item.leaseExpiresAt=$null;$item.claimTokenHash=$null
    }elseif($Action-eq'status'){Safe-View $item|ConvertTo-Json -Depth 5;return}
    $item.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Save-Store $store;Safe-View $item ($Action-eq'claim') $false $plainToken|ConvertTo-Json -Depth 12
}finally{
    if($owned){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
