[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxMiB = 50
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
$source = Assert-UnlinkedFilePath -LiteralPath $SourcePath -Purpose 'inbound ingestion'
if ($source.Length -gt ($MaxMiB * 1MB)) { throw "Inbound file exceeds the $MaxMiB MiB safety limit." }

$blockedExtensions = @('.exe','.msi','.msp','.bat','.cmd','.ps1','.psm1','.reg','.lnk','.scr','.com','.dll','.js','.jse','.vbs','.vbe','.wsf','.wsh','.jar','.chm')
if ($source.Extension.ToLowerInvariant() -in $blockedExtensions) {
    throw "Executable or script attachment is not accepted: $($source.Extension)"
}
$sourceHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash

$workspace = Split-Path -Parent $PSScriptRoot
$dateFolder = Join-Path (Join-Path $workspace 'inbox') (Get-Date -Format 'yyyy-MM-dd')
New-Item -ItemType Directory -Path $dateFolder -Force | Out-Null

$safeName = [regex]::Replace($source.Name, '[<>:"/\\|?*\x00-\x1F]', '_').Trim()
if (-not $safeName) { $safeName = 'attachment.bin' }
$destination = Join-Path $dateFolder $safeName
if (Test-Path -LiteralPath $destination) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
    $ext = [System.IO.Path]::GetExtension($safeName)
    $destination = Join-Path $dateFolder ("{0}-{1}{2}" -f $base,(Get-Date -Format 'HHmmss'),$ext)
}

Copy-Item -LiteralPath $source.FullName -Destination $destination
$saved = Get-Item -LiteralPath $destination
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $saved.FullName
$sourceHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash
if ($sourceHashBefore -ne $sourceHashAfter -or $hash.Hash -ne $sourceHashAfter) {
    [System.IO.File]::Delete($saved.FullName)
    throw 'Source changed during inbound ingestion; no copy was kept.'
}

[ordered]@{
    status       = 'saved'
    fileName     = $saved.Name
    savedPath    = $saved.FullName
    sizeBytes    = $saved.Length
    sha256       = $hash.Hash
    sourceIntact = (Test-Path -LiteralPath $source.FullName)
    integrityVerified = $true
} | ConvertTo-Json
