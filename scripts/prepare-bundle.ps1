[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SourcePaths,

    [Parameter(Mandatory = $false)]
    [string]$BundleName = '微信资料包.zip',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxMiB = 25
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'path-safety.ps1')
if ($SourcePaths.Count -gt 20) { throw 'A bundle can contain at most 20 files.' }

$sensitivePath = '\\(\.openclaw|\.codex|AppData|Windows|Program Files(?: \(x86\))?|ProgramData)(\\|$)'
$sensitiveName = '(?i)(auth|token|cookie|credential|secret|password|passwd|openclaw\.json|\.env$)'
$blockedExtensions = @('.exe','.msi','.msp','.bat','.cmd','.ps1','.psm1','.reg','.lnk','.scr','.com','.dll','.js','.jse','.vbs','.vbe','.wsf','.wsh','.jar','.key','.pem','.pfx','.p12','.sqlite','.db')

$sources = foreach ($item in $SourcePaths) {
    $source = Assert-UnlinkedFilePath -LiteralPath $item -Purpose 'bundle preparation'
    if ($source.FullName -match $sensitivePath) { throw "Authentication or system path rejected: $($source.Name)" }
    if ($source.Name -match $sensitiveName) { throw "Credential-looking filename rejected: $($source.Name)" }
    if ($source.Extension.ToLowerInvariant() -in $blockedExtensions) { throw "Blocked file type: $($source.Extension)" }
    $source
}

$sourceHashes = @{}
foreach ($source in $sources) {
    $sourceHashes[$source.FullName] = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
}

if (($sources | Measure-Object Length -Sum).Sum -gt 100MB) {
    throw 'Bundle source files exceed the 100 MiB processing limit.'
}

$workspace = Split-Path -Parent $PSScriptRoot
$dateFolder = Join-Path (Join-Path $workspace 'outbox') (Get-Date -Format 'yyyy-MM-dd')
New-Item -ItemType Directory -Path $dateFolder -Force | Out-Null

$safeBundleName = [regex]::Replace($BundleName, '[<>:"/\\|?*\x00-\x1F]', '_').Trim()
if (-not $safeBundleName.EndsWith('.zip',[System.StringComparison]::OrdinalIgnoreCase)) { $safeBundleName += '.zip' }
$destination = Join-Path $dateFolder $safeBundleName
if (Test-Path -LiteralPath $destination) {
    $destination = Join-Path $dateFolder ("{0}-{1}.zip" -f [System.IO.Path]::GetFileNameWithoutExtension($safeBundleName),(Get-Date -Format 'HHmmss'))
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($destination,[System.IO.FileMode]::CreateNew)
$archive = [System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
try {
    $usedNames = @{}
    foreach ($source in $sources) {
        $entryName = [regex]::Replace($source.Name, '[<>:"/\\|?*\x00-\x1F]', '_').Trim()
        if ($usedNames.ContainsKey($entryName)) {
            $entryName = "{0}-{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($entryName),$usedNames[$entryName],[System.IO.Path]::GetExtension($entryName)
        }
        $usedNames[$source.Name] = 1 + [int]($usedNames[$source.Name])
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$source.FullName,$entryName,[System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}

$changed = @($sources | Where-Object {
    -not (Test-Path -LiteralPath $_.FullName -PathType Leaf) -or
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ne $sourceHashes[$_.FullName]
})
if ($changed.Count -gt 0) {
    [System.IO.File]::Delete($destination)
    throw 'A source changed during bundle creation; no bundle was kept.'
}

$result = Get-Item -LiteralPath $destination
if ($result.Length -gt ($MaxMiB * 1MB)) {
    [System.IO.File]::Delete($result.FullName)
    throw "Compressed bundle exceeds the $MaxMiB MiB WeChat limit; no bundle was kept."
}

[pscustomobject]@{
    status = 'prepared'
    fileCount = $sources.Count
    bundlePath = $result.FullName
    sizeBytes = $result.Length
    sha256 = (Get-FileHash -LiteralPath $result.FullName -Algorithm SHA256).Hash
    sourcesIntact = $true
    integrityVerified = $true
} | ConvertTo-Json -Depth 4
