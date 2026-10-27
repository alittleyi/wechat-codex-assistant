[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 25)]
    [int]$MaxMiB = 25
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
$source = Assert-UnlinkedFilePath -LiteralPath $SourcePath -Purpose 'browser export ingestion'

$browserRoot = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.openclaw\media\browser'))
$sourceFull = [System.IO.Path]::GetFullPath($source.FullName)
if (-not $sourceFull.StartsWith($browserRoot + [System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Only files created in the OpenClaw browser export directory are accepted.'
}

$allowed = @('.pdf','.png','.jpg','.jpeg','.webp')
if ($source.Extension.ToLowerInvariant() -notin $allowed) { throw 'Unsupported browser export type.' }
if ($source.Length -gt ($MaxMiB * 1MB)) { throw "Browser export exceeds the $MaxMiB MiB limit." }
$sourceHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash

$workspace = Split-Path -Parent $PSScriptRoot
$staging = Join-Path $workspace 'browser-exports'
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$safeName = 'browser-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $source.Extension.ToLowerInvariant()
$destination = Join-Path $staging $safeName
Copy-Item -LiteralPath $sourceFull -Destination $destination
$copy = Get-Item -LiteralPath $destination
$copyHash = (Get-FileHash -LiteralPath $copy.FullName -Algorithm SHA256).Hash
$sourceHashAfter = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
if ($sourceHashBefore -ne $sourceHashAfter -or $copyHash -ne $sourceHashAfter) {
    [System.IO.File]::Delete($copy.FullName)
    throw 'Browser export changed during staging; no copy was kept.'
}

[ordered]@{
    status = 'staged'
    fileName = $copy.Name
    stagedPath = $copy.FullName
    sizeBytes = $copy.Length
    sha256 = $copyHash
    integrityVerified = $true
} | ConvertTo-Json
