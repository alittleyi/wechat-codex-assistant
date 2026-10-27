[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$OutputRoot
)

$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($ManifestPath)){$ManifestPath=Join-Path $workspace 'release\v0.1\manifest.json'}
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $workspace 'release\build'}

$manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
if($manifest.schemaVersion-ne1){throw 'Unsupported release manifest schema.'}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$target=Join-Path $OutputRoot ("$($manifest.name)-$($manifest.version)-$stamp")
New-Item -ItemType Directory -Path $target -Force|Out-Null

function Resolve-Under([string]$Root,[string]$Relative){
    if([string]::IsNullOrWhiteSpace($Relative)-or[IO.Path]::IsPathRooted($Relative)-or($Relative-split'[\\/]'|Where-Object{$_-eq'..'})){throw "Unsafe relative path: $Relative"}
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw "Path escaped root: $Relative"}
    return $full
}

foreach($entry in @($manifest.entries)){
    $source=Resolve-Under $workspace ([string]$entry.source)
    $destination=Resolve-Under $target ([string]$entry.destination)
    $item=Get-Item -LiteralPath $source -Force
    if($item.LinkType-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw "Linked source rejected: $($entry.source)"}
    if(-not$item.PSIsContainer){
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
        continue
    }
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    $patterns=@($entry.include);if($patterns.Count-eq0){$patterns=@('*')}
    $excluded=@($entry.exclude)
    foreach($file in Get-ChildItem -LiteralPath $source -File -Recurse){
        $relative=$file.FullName.Substring($source.TrimEnd('\').Length+1)
        if($file.LinkType-or(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw "Linked source rejected: $relative"}
        if($excluded|Where-Object{$relative-like"*$_*"}){continue}
        if(-not($patterns|Where-Object{$file.Name-like$_})){continue}
        $copyTo=Resolve-Under $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $copyTo) -Force|Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $copyTo
    }
}

$auditRaw = (& (Join-Path $PSScriptRoot 'release-audit.ps1') -CandidatePath $target | Out-String).Trim()
$audit = $auditRaw | ConvertFrom-Json
if ($audit.status -ne 'passed') {
    throw "Release audit did not pass for candidate '$target': $auditRaw"
}
$files=@(Get-ChildItem -LiteralPath $target -File -Recurse)
[ordered]@{status='passed';path=$target;files=$files.Count;bytes=($files|Measure-Object Length -Sum).Sum}|ConvertTo-Json
