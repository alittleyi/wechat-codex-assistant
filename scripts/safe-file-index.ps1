[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Query,

    [Parameter(Mandatory = $false)]
    [string[]]$Roots = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    ),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxResults = 20
)

$ErrorActionPreference = 'SilentlyContinue'
$needle = if ($Query.IndexOfAny([char[]]'*?') -ge 0) { $Query } else { "*$Query*" }
$excluded = '\\(\.openclaw|\.codex|AppData|Windows|Program Files(?: \(x86\))?|ProgramData|System Volume Information)(\\|$)'
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.FullName -notmatch $excluded -and $_.Name -like $needle } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            if ($rows.Count -lt $MaxResults) {
                $rows.Add([ordered]@{
                    name         = $_.Name
                    directory    = $_.DirectoryName
                    extension    = $_.Extension
                    sizeBytes    = $_.Length
                    modifiedTime = $_.LastWriteTime.ToString('o')
                })
            }
        }
    if ($rows.Count -ge $MaxResults) { break }
}

[ordered]@{
    query       = $Query
    resultCount = $rows.Count
    truncated   = ($rows.Count -ge $MaxResults)
    results     = $rows
} | ConvertTo-Json -Depth 5
