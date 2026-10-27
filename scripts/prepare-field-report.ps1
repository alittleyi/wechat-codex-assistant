[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaselinePath,
    [Parameter(Mandatory=$true)][string]$ObservationsPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedBaselineSha256,
    [string]$PreviousObservationsPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedPreviousObservationsSha256,
    [string]$PreviousEvidenceManifestPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedPreviousEvidenceManifestSha256,
    [string[]]$ReplaceEvidenceIds=@(),
    [string[]]$EvidencePaths=@(),
    [switch]$PrivacyReviewed
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
if(-not $PrivacyReviewed){throw 'Human contextual privacy review is required for all text and photos.'}
function Assert-FieldInput([string]$Path,[string[]]$Extensions,[long]$MaxBytes){
    $file=Assert-UnlinkedFilePath -LiteralPath $Path -Purpose 'field report input'
    if($file.Extension.ToLowerInvariant() -notin $Extensions -or $file.Length -gt $MaxBytes){throw 'Field input type or size rejected.'}
    if($file.FullName -match '(?i)\\(\.openclaw|\.codex|AppData|Windows|Program Files|ProgramData)(\\|$)' -or
       $file.Name -match '(?i)(auth|token|cookie|credential|secret|password|passwd|\.env)'){throw 'Sensitive source path rejected.'}
    return $file
}
$baseline=Assert-FieldInput $BaselinePath @('.json') 100KB
$observations=Assert-FieldInput $ObservationsPath @('.json') 100KB
$evidence=@($EvidencePaths|ForEach-Object {Assert-FieldInput $_ @('.png','.jpg','.jpeg') 5MB})
if($evidence.Count -gt 6){throw 'At most six evidence photos are accepted.'}
$baselineHash=(Get-FileHash -LiteralPath $baseline.FullName).Hash
if($baselineHash -ne $ExpectedBaselineSha256){throw 'Baseline revision changed; clarify project version first.'}
$observationsHash=(Get-FileHash -LiteralPath $observations.FullName).Hash
$previous=$null
if([bool]$PreviousObservationsPath -ne [bool]$ExpectedPreviousObservationsSha256){throw 'Previous path and expected revision hash must be supplied together.'}
if($PreviousObservationsPath){
    $previous=Assert-FieldInput $PreviousObservationsPath @('.json') 100KB
    if((Get-FileHash -LiteralPath $previous.FullName).Hash -ne $ExpectedPreviousObservationsSha256){throw 'Previous displayed observation revision changed.'}
}
$previousManifest=$null
if([bool]$PreviousEvidenceManifestPath -ne [bool]$ExpectedPreviousEvidenceManifestSha256){throw 'Previous evidence manifest and hash must be supplied together.'}
if($PreviousEvidenceManifestPath){
    if(-not $previous){throw 'Previous evidence manifest requires previous observations.'}
    $previousManifest=Assert-FieldInput $PreviousEvidenceManifestPath @('.json') 100KB
    if((Get-FileHash -LiteralPath $previousManifest.FullName).Hash -ne $ExpectedPreviousEvidenceManifestSha256){throw 'Previous evidence manifest revision changed.'}
    $previousReportPath=[IO.Path]::ChangeExtension($previousManifest.FullName,'.pdf')
    $null=Assert-FieldInput $previousReportPath @('.pdf') 25MB
}
if(@($ReplaceEvidenceIds|Where-Object {$_ -notmatch '^E[1-6]$'}).Count -gt 0){throw 'Invalid evidence replacement ID.'}
if($ReplaceEvidenceIds.Count -gt 0 -and -not $previousManifest){throw 'Photo replacement requires the previous evidence manifest.'}
$outputRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'outputs'
New-Item -ItemType Directory -Path $outputRoot -Force|Out-Null
$outputPath=Join-Path $outputRoot ('field-review-'+[guid]::NewGuid().ToString('N')+'.pdf')
. (Join-Path $PSScriptRoot 'runtime-resolver.ps1')
$python=Resolve-AgentRuntime python
$arguments=@((Join-Path $PSScriptRoot 'field_report.py'),'--baseline',$baseline.FullName,'--observations',$observations.FullName,
    '--baseline-sha256',$baselineHash,'--observations-sha256',$observationsHash,'--font','C:\Windows\Fonts\simhei.ttf','--output',$outputPath)
if($evidence.Count -gt 0){$arguments+=@('--evidence');$arguments+=@($evidence|ForEach-Object {$_.FullName})}
if($previous){$arguments+=@('--previous-observations',$previous.FullName,'--previous-observations-sha256',$ExpectedPreviousObservationsSha256)}
if($previousManifest){$arguments+=@('--previous-evidence-manifest',$previousManifest.FullName,'--previous-evidence-manifest-sha256',$ExpectedPreviousEvidenceManifestSha256)}
if($ReplaceEvidenceIds.Count -gt 0){$arguments+=@('--replace-evidence-ids');$arguments+=$ReplaceEvidenceIds}
$raw=(& $python @arguments)-join "`n"
if($LASTEXITCODE -ne 0){throw 'Field report rejected; original files were not edited.'}
$result=$raw|ConvertFrom-Json
$inspection=(& (Join-Path $PSScriptRoot 'inspect-document.ps1') -Path $result.outputPath)|ConvertFrom-Json
if(@($inspection.sensitive_patterns_detected).Count -gt 0){throw 'Report has sensitive patterns; do not deliver.'}
$prepared=(& (Join-Path $PSScriptRoot 'prepare-outbound.ps1') -SourcePath $result.outputPath)|ConvertFrom-Json
[ordered]@{
    status=$result.status;requirementCount=$result.requirementCount;reportedCounts=$result.reportedCounts
    evidenceCount=$result.evidenceCount;originalsUnchanged=$result.originalsUnchanged
    acceptance=$result.acceptance;imageRecognition=$result.imageRecognition
    textChangeDigest=$result.textChangeDigest;comparisonScope=$result.comparisonScope
    evidenceChangeDigest=$result.evidenceChangeDigest
    evidenceManifestPath=$result.evidenceManifestPath;evidenceManifestSha256=$result.evidenceManifestSha256
    outputPath=$result.outputPath;outboundPath=$prepared.outboundPath;sha256=$result.sha256
    integrityVerified=$prepared.integrityVerified;visualQa='requires-page-review'
}|ConvertTo-Json -Depth 5
