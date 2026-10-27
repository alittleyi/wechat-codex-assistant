[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$paths = @(
    (Join-Path $workspace 'media-fixtures\duplicate-a\sample.txt'),
    (Join-Path $workspace 'media-fixtures\duplicate-b\sample.txt')
)

$raw = & (Join-Path $PSScriptRoot 'prepare-bundle.ps1') -SourcePaths $paths -BundleName 'duplicate-name-boundary-test.zip'
$result = $raw | ConvertFrom-Json

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($result.bundlePath)
try {
    $entries = @($zip.Entries | Select-Object -ExpandProperty FullName)
} finally {
    $zip.Dispose()
}

[pscustomobject]@{
    status = if (@($entries | Sort-Object -Unique).Count -eq $entries.Count) { 'passed' } else { 'failed' }
    bundlePath = $result.bundlePath
    entries = $entries
    uniqueNames = (@($entries | Sort-Object -Unique).Count -eq $entries.Count)
    sourceCount = $paths.Count
} | ConvertTo-Json -Depth 4
