[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][ValidateRange(1,1000)][int]$SlideNumber,
    [Parameter(Mandatory=$true)][string]$OldText,
    [Parameter(Mandatory=$true)][string]$NewText,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
$source=Assert-UnlinkedFilePath -LiteralPath $SourcePath -Purpose 'PPT review edit'
if($source.Extension.ToLowerInvariant() -ne '.pptx' -or $source.Length -gt 25MB){throw 'Only PPTX files up to 25 MiB are accepted.'}
if($source.FullName -match '(?i)\\(\.openclaw|\.codex|AppData|Windows|Program Files|ProgramData)(\\|$)' -or
   $source.Name -match '(?i)(auth|token|cookie|credential|secret|password|passwd|\.env)'){throw 'Sensitive paths are not accepted.'}
$inspection=(& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $source.FullName)|ConvertFrom-Json
if(@($inspection.sensitive_patterns_detected).Count -gt 0){throw 'Presentation has sensitive patterns; manual handling is required.'}
$outputRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'outputs'
New-Item -ItemType Directory -Path $outputRoot -Force|Out-Null
$name='ppt-review-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.pptx'
$outputPath=Join-Path $outputRoot $name
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$python=Resolve-AgentRuntime python
$raw=(& $python (Join-Path $PSScriptRoot 'ppt_review_patch.py') $source.FullName --slide $SlideNumber --old $OldText --new $NewText --expected-sha256 $ExpectedSha256 --output $outputPath)-join "`n"
if($LASTEXITCODE -ne 0){throw 'PPT text patch rejected; original was not edited.'}
$result=$raw|ConvertFrom-Json
$prepared=(& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $result.outputPath)|ConvertFrom-Json
[ordered]@{
    status=$result.status;slideNumber=$result.slideNumber;slideCount=$result.slideCount
    originalUnchanged=$result.originalUnchanged;geometryUnchanged=$result.geometryUnchanged
    unchangedPackageParts=$result.unchangedPackageParts;visualQa=$result.visualQa
    sourceSha256=$result.sourceSha256;outputSha256=$result.outputSha256
    outputPath=$result.outputPath;outboundPath=$prepared.outboundPath;integrityVerified=$prepared.integrityVerified
}|ConvertTo-Json
