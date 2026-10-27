[CmdletBinding()]
param([string]$CandidatePath)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($CandidatePath)){$CandidatePath=$workspace}
$candidate=Get-Item -LiteralPath $CandidatePath -Force
if(-not$candidate.PSIsContainer){throw 'CandidatePath must be a directory.'}

$required=@('README.md','LICENSE','INSTALL.md','SECURITY.md','.gitignore','RUNBOOK.md','CAPABILITIES.md','requirements.txt','THIRD_PARTY.md','docs\DISPATCH-BRIDGE.md','docs\TEST-MATRIX.md','scripts\initialize-workspace.ps1','scripts\preflight.ps1','scripts\release-audit.ps1','scripts\run-workflow-regression.ps1')
$missing=@($required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $candidate.FullName $_) -PathType Leaf)})
if($missing.Count-gt0){throw "Release files are missing: $($missing -join ', ')"}

$auditRaw=& (Join-Path $candidate.FullName 'scripts\release-audit.ps1') -CandidatePath $candidate.FullName
$auditOk=$?
if(-not$auditOk){$auditRaw;exit 1}
$audit=$auditRaw|ConvertFrom-Json
$oldBytecode=$env:PYTHONDONTWRITEBYTECODE
$env:PYTHONDONTWRITEBYTECODE='1'
try{$regressionRaw=& (Join-Path $candidate.FullName 'scripts\run-workflow-regression.ps1')}
finally{$env:PYTHONDONTWRITEBYTECODE=$oldBytecode}
$regressionOk=$?
if(-not$regressionOk){$regressionRaw;exit 1}
$regression=$regressionRaw|ConvertFrom-Json
$finalAuditRaw=& (Join-Path $candidate.FullName 'scripts\release-audit.ps1') -CandidatePath $candidate.FullName
$finalAuditOk=$?
if(-not$finalAuditOk){$finalAuditRaw;exit 1}
$finalAudit=$finalAuditRaw|ConvertFrom-Json

$installRoot=Join-Path ([IO.Path]::GetTempPath()) ('wechat-codex-install-'+[guid]::NewGuid().ToString('N'))
$installWorkspace=Join-Path $installRoot 'workspace'
try{
    $initialize=Join-Path $candidate.FullName 'scripts\initialize-workspace.ps1'
    $firstRaw=& $initialize -WorkspacePath $installWorkspace
    if(-not $?){$firstRaw;exit 1}
    $first=$firstRaw|ConvertFrom-Json
    $secondRaw=& $initialize -WorkspacePath $installWorkspace
    if(-not $?){$secondRaw;exit 1}
    $second=$secondRaw|ConvertFrom-Json

    $expected=@('AGENTS.md','inbox','outbox','receipts','tasks')
    $actual=@(Get-ChildItem -LiteralPath $installWorkspace -Force|ForEach-Object{$_.Name}|Sort-Object)
    $unexpected=@($actual|Where-Object{$_-notin$expected})
    $missingInstall=@($expected|Where-Object{$_-notin$actual})
    if($first.status-ne'ok'-or-not[bool]$first.agentsCreated-or[bool]$first.credentialsWritten){throw 'First initialization did not create the expected credential-free workspace.'}
    if($second.status-ne'ok'-or[bool]$second.agentsCreated-or@($second.directoriesCreated).Count-ne0-or[bool]$second.credentialsWritten){throw 'Repeated initialization was not idempotent.'}
    if($missingInstall.Count-or$unexpected.Count){throw "Clean workspace contents differed: missing=$($missingInstall-join','); unexpected=$($unexpected-join',')"}
    $cleanInstallPassed=$true
}finally{
    if(Test-Path -LiteralPath $installRoot){Remove-Item -LiteralPath $installRoot -Recurse -Force}
}

[ordered]@{
    status='passed'
    releaseFiles=$finalAudit.files
    releaseBytes=$finalAudit.bytes
    workflowPassed=$regression.passed
    workflowTotal=$regression.total
    cleanInstallPassed=$cleanInstallPassed
    initializeIdempotent=$true
    credentialsWritten=$false
    livePhoneTest=$false
    note='Release package and local synthetic workflows passed; live WeChat acceptance remains separate.'
}|ConvertTo-Json
