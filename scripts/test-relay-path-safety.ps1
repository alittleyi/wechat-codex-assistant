$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
$relay=Join-Path $PSScriptRoot 'work-relay-card.ps1'

$allowed=& $relay -Goal 'validate explicit project path' -ProjectPath $workspace -MaxRecentFiles 3 -MaxChats 1 -DryRun|ConvertFrom-Json
if($allowed.status-ne'dry-run'-or$allowed.recentFileCount-lt1){throw 'Explicit workspace project was not accepted.'}

$driveRootRejected=$false
try{& $relay -Goal 'must reject drive root' -ProjectPath ([IO.Path]::GetPathRoot($workspace)) -DryRun|Out-Null}catch{$driveRootRejected=$true}
if(-not$driveRootRejected){throw 'Drive root was accepted.'}

$authRejected=$false
try{& $relay -Goal 'must reject auth directory' -ProjectPath (Join-Path $env:USERPROFILE '.codex') -DryRun|Out-Null}catch{$authRejected=$true}
if(-not$authRejected){throw 'Authentication directory was accepted.'}

[pscustomobject]@{ok=$true;tests=3}|ConvertTo-Json -Compress
