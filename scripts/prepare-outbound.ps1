[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxMiB = 25
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
$source = Assert-UnlinkedFilePath -LiteralPath $SourcePath -Purpose 'outbound preparation'
if ($source.Length -gt ($MaxMiB * 1MB)) { throw "Outbound file exceeds the $MaxMiB MiB WeChat limit." }

$sensitivePath = '\\(\.openclaw|\.codex|AppData|Windows|Program Files(?: \(x86\))?|ProgramData)(\\|$)'
$sensitiveName = '(?i)(auth|token|cookie|credential|secret|password|passwd|openclaw\.json|\.env$)'
$blockedExtensions = @('.exe','.msi','.msp','.bat','.cmd','.ps1','.psm1','.reg','.lnk','.scr','.com','.dll','.js','.jse','.vbs','.vbe','.wsf','.wsh','.jar','.key','.pem','.pfx','.p12','.sqlite','.db')

if ($source.FullName -match $sensitivePath) { throw 'Files from authentication or system directories cannot be sent.' }
if ($source.Name -match $sensitiveName) { throw 'The filename looks credential-related and cannot be sent.' }
if ($source.Extension.ToLowerInvariant() -in $blockedExtensions) { throw "This file type cannot be sent: $($source.Extension)" }
$sourceHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash

$workspace = Split-Path -Parent $PSScriptRoot
$dateFolder = Join-Path (Join-Path $workspace 'outbox') (Get-Date -Format 'yyyy-MM-dd')
New-Item -ItemType Directory -Path $dateFolder -Force | Out-Null

$safeName = [regex]::Replace($source.Name, '[<>:"/\\|?*\x00-\x1F]', '_').Trim()
$destination = Join-Path $dateFolder $safeName
if (Test-Path -LiteralPath $destination) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
    $ext = [System.IO.Path]::GetExtension($safeName)
    $destination = Join-Path $dateFolder ("{0}-{1}{2}" -f $base,(Get-Date -Format 'HHmmss'),$ext)
}

Copy-Item -LiteralPath $source.FullName -Destination $destination
$prepared = Get-Item -LiteralPath $destination
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $prepared.FullName
$sourceHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash
if ($sourceHashBefore -ne $sourceHashAfter -or $hash.Hash -ne $sourceHashAfter) {
    [System.IO.File]::Delete($prepared.FullName)
    throw 'Source changed during outbound preparation; no copy was kept.'
}

[ordered]@{
    status       = 'prepared'
    fileName     = $prepared.Name
    outboundPath = $prepared.FullName
    sizeBytes    = $prepared.Length
    sha256       = $hash.Hash
    sourceIntact = (Test-Path -LiteralPath $source.FullName)
    integrityVerified = $true
} | ConvertTo-Json
